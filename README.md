# QringPrint · H5

**错题小印系列 58mm 蓝牙热敏打印机的纯网页客户端**

打开网页就能打印，不用装 App。

![Platform](https://img.shields.io/badge/platform-Web-black) ![API](https://img.shields.io/badge/Web%20Bluetooth%20%2F%20Web%20Serial-2f6df6) ![Deps](https://img.shields.io/badge/dependencies-0-green) ![Device](https://img.shields.io/badge/device-58mm%20%E7%83%AD%E6%95%8F%E6%89%93%E5%8D%B0%E6%9C%BA-7C5CE6) ![License](https://img.shields.io/badge/license-MIT-green)

**在线使用 → <https://qp.thisko.cc.cd/>**

---

## 这是什么

错题小印（Qring / BeePrt BY 系列）是一款 58mm 蓝牙热敏打印机，多用于错题、便签、标签打印。官方 APP 的服务器已经扑街，于是有了 QringPrint。

这是它的**网页版**：直接用浏览器的 Web Bluetooth 连打印机，把文字、图片、条码、Markdown 排版成 384 点宽的光栅位图下发。手机电脑都能用，不用安装任何东西，也不经过任何服务器 —— 打开的是一个纯静态页面，数据只在你的浏览器和打印机之间走。


## 功能

- **图片打印** —— 9 种抖动算法（Floyd–Steinberg / Atkinson / Jarvis / Stucki / Burkes / Sierra / Bayer 4×4 / Bayer 8×8 / 纯阈值），阈值、对比度、锐度（USM）可调，支持旋转翻转，实时预览
- **文字打印** —— 字体、字号、字重、粗斜体下划线、字间距、行间距、对齐，可**导入本地或在线字体**
- **条码打印** —— Code 128 / Code 39 / EAN-13 / EAN-8 / UPC-A / ITF / QR Code，输入即校验，二维码可选纠错等级
- **Markdown 打印** —— 标题、列表、任务清单、引用、代码块、表格、分隔线、粗斜体删除线、链接，可直接导入 `.md` 文件
- **打印可靠性** —— 缺纸 / 开盖 / 过热 / 低电量实时监测，打印前自动体检，等待打印完成 ACK，掉线自动重连

所有编码器都是**零依赖**的：QR（含 GF(256) 上的 Reed–Solomon、版本 1–40、四级纠错、八种掩码择优）、各一维码码表、Markdown 解析与排版，全在 `public/src/` 里，没有构建步骤，没有 node_modules。

## 怎么用

浏览器直接打开 <https://qp.thisko.cc.cd/>，点「连接」选中你的打印机即可。

本地跑：

```bash
node serve.js          # 默认 3000 端口，零依赖
# 打开 http://localhost:3000/
```

Web Bluetooth 要求**安全上下文**，所以只能用 `https://` 或 `http://localhost` 打开，`file://` 直接双击是不行的。手机连电脑起的局域网地址（`http://192.168.x.x`）也会被拦，安卓可以在 `chrome://flags/#unsafely-treat-insecure-origin-as-secure` 里把该地址加白名单。

## 浏览器支持

| 平台 | 浏览器 | BLE | 蓝牙串口 |
| --- | --- | :-: | :-: |
| Windows / macOS / Linux | Chrome、Edge | ✅ | ✅ 更快 |
| 安卓 | Chrome | ✅ | ✅ 更快 |
| iOS / iPadOS | Edge、[Bluefy](https://apps.apple.com/app/bluefy-web-ble-browser/id1492822055) | ✅ | ❌ |
| 任意平台 | Safari、Firefox | ❌ | ❌ |
手机端如遇到BLE打印卡死，请到设置中调低分包大小。
Safari 和 Firefox 至今不实现 Web Bluetooth，iOS 上只能用 Bluefy 这类内置 WebBLE 的浏览器。

## 技术要点

**Qring 私有协议（不是标准 ESC/POS）**

状态、电量、浓度、型号全走自己的 `10 FF` 系列命令，**只有走纸（`ESC J`）和光栅位图（`GS v 0`）沿用了 ESC/POS**。协议是对官方 APP 分析整理出来的，细节都写在 `public/src/protocol.js` 的注释里。

- 光栅编码：每行 48 字节（384 点 ÷ 8），MSB first，**置 1 = 黑**
- 状态字节单字节承载五个位：打印中 / 开盖 / 缺纸 / 低电压 / 过热


```
Service 0000ff00-…
  ff02  [write]   ← 写，比 ISSC 那条快一倍
  ff01  [notify]  ← 收：响应 / 打印完成 AA / 故障帧 FF xx
  ff03  [notify]  ← 旁路，连接瞬间会推两帧，必须和 ff01 分开存
```

两个反直觉的点：用 ISSC 通道写时**收发跨 service**；`ff03` 混进 `ff01` 会污染第一次查询（型号 `X1` 被解码成 `dX1`）。

**分包大小按端给**：桌面 133 字节（实测 MTU 136，134 起就卡死），手机 100（超过就卡住）。认错方向的代价不对称 —— 把桌面当手机只是慢一点，把手机当桌面会直接卡死打印机，所以判断逻辑偏保守。

## 项目结构

```
public/
  index.html          界面 + 交互（单文件，内联 module）
  ble-probe.html      通道探针：扫描所有 GATT 特征、逐条试，排查用
  src/
    protocol.js       私有协议：拼字节 / 解析状态位
    printer.js        驱动：分包收发、查询时序、ACK 等待、打印编排
    transport-ble.js  Web Bluetooth 通道（三端通用）
    transport-serial.js  Web Serial 通道（仅桌面，更快）
    raster.js         图像/文本 → 光栅，抖动、对比度、锐化
    qrcode.js         QR 编码器（ISO/IEC 18004）
    barcode.js        一维码编码 + 统一绘制
    markdown.js       Markdown 解析与排版
    rxbuffer.js       接收缓冲：滚动缓冲 + 静默期收口
serve.js              零依赖静态服务器（本地开发用）
```

## 部署

纯静态站，把 `public/` 丢到任何静态托管都能跑（GitHub Pages、Vercel、Cloudflare…），没有构建步骤。

作者用的是 Cloudflare Workers 的静态资源托管，直接项目目录 `npx wrangler deploy` 即可。

> 注意：必须是 **https**。Web Bluetooth 在非安全上下文里整个 API 都不存在。

## 已知限制

- **USB 直连做不了**。BY-288 这类机器在 Windows 上被 `usbprint.sys` 接管，而 WebUSB 底层要求设备绑 WinUSB 驱动，抢不到接口 —— 这是驱动模型决定的，任何网页都绕不过去。要走 USB 只能用原生程序（`CreateFile` 打开 `usbprint` 注册的设备接口，借道而不是抢驱动）。
- Data Matrix / PDF417 / Aztec 没做 —— 各自是一整套带独立纠错体系的编码器，二维场景 QR 够用了。
- 自定义在线字体需要对方服务器允许跨域（`Access-Control-Allow-Origin`），字体文件受 CORS 管，不像图片那样能随便引。
- 本地导入的字体只在当次会话有效：中文字体动辄十几兆，存不进浏览器本地存储。

## 关于

本项目仅在WINDOWS11/卓易通中的Edge浏览器以及Iphone11的Bluefy浏览器中简单测试，编码器部分由Claude写了 180 余条自动化测试（含一个独立实现的 QR 解码器做往返校验），但不保证在所有机型上都可用。遇到问题欢迎提 issue。

觉得有用的话点个 Star，谢谢～

## License

[MIT](LICENSE) © 2026 Thisko
