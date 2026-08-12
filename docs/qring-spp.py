#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
小印 (Qring / BeePrt BY) 热敏打印机驱动

协议来自对 com.zxxk.xiaoyin.App 分析，详见 QRING_PROTOCOL.md
不依赖任何云端服务。

依赖:
    pip install pyserial pillow

用法:
    # Windows: 先在系统蓝牙里配对打印机，会生成一个"传出"的 COM 口
    python qring.py --port COM5 --info
    python qring.py --port COM5 --image photo.jpg
    python qring.py --port COM5 --text "你好，世界"

    # Linux
    sudo rfcomm bind 0 AA:BB:CC:DD:EE:FF 1
    python qring.py --port /dev/rfcomm0 --image photo.jpg
    # 或直接用 MAC（免 rfcomm bind）
    python qring.py --mac AA:BB:CC:DD:EE:FF --image photo.jpg
"""

import argparse
import socket
import sys
import time

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except ImportError:
    Image = None


# --------------------------------------------------------------------------
# 协议常量
# --------------------------------------------------------------------------

WIDTH_DOTS = 384                      # 58mm 热敏头
WIDTH_BYTES = WIDTH_DOTS // 8         # 48
CHUNK = 1024                          # SDK 单次 write 上限
SPP_UUID = "00001101-0000-1000-8000-00805F9B34FB"

# 打印控制
CMD_ENABLE      = bytes([0x10, 0xFF, 0xF1, 0x02])
CMD_ENABLE2     = bytes([0x1F, 0xB2, 0x10])
CMD_STOP        = bytes([0x10, 0xFF, 0xF1, 0x45])
CMD_WAKEUP      = bytes(12)                        # 00 x12
CMD_LABEL_POS   = bytes([0x1D, 0x0C])
CMD_LEARN_GAP   = bytes([0x10, 0xFF, 0x03])

# 查询
CMD_STATUS      = bytes([0x10, 0xFF, 0x40])
CMD_BATTERY     = bytes([0x10, 0xFF, 0x50, 0xF1])
CMD_BT_NAME     = bytes([0x10, 0xFF, 0x30, 0x11])
CMD_BT_MAC      = bytes([0x10, 0xFF, 0x30, 0x12])
CMD_BT_VERSION  = bytes([0x10, 0xFF, 0x30, 0x10])
CMD_FW_VERSION  = bytes([0x10, 0xFF, 0x20, 0xF1])
CMD_SN          = bytes([0x10, 0xFF, 0x20, 0xF2])
CMD_MODEL       = bytes([0x10, 0xFF, 0x20, 0xF0])
CMD_INFO        = bytes([0x10, 0xFF, 0x70])

ACK_PRINT_DONE  = 0xAA

# 状态位
STATUS_BITS = [
    (0x01, "正在打印"),
    (0x02, "机身异常 / 开盖"),
    (0x04, "缺纸"),
    (0x08, "电池电压低"),
    (0x10, "过热"),
]

# 主动上报帧 FF xx
UNSOLICITED = {
    0x01: "缺纸",
    0x02: "开盖",
    0x03: "过热",
    0x04: "低电量",
}


# --------------------------------------------------------------------------
# 传输层
# --------------------------------------------------------------------------

class SerialTransport:
    """Windows / Linux 虚拟串口 (SPP)"""

    def __init__(self, port, baudrate=115200, timeout=1.0):
        import serial
        self.ser = serial.Serial(port, baudrate, timeout=timeout)

    def write(self, data):
        self.ser.write(data)
        self.ser.flush()

    def read(self, n, timeout=1.0):
        old = self.ser.timeout
        self.ser.timeout = timeout
        try:
            return self.ser.read(n)
        finally:
            self.ser.timeout = old

    def flush_input(self):
        self.ser.reset_input_buffer()

    def close(self):
        self.ser.close()


class RfcommTransport:
    """Linux 原生 RFCOMM socket，免 rfcomm bind"""

    def __init__(self, mac, channel=1, timeout=10.0):
        self.sock = socket.socket(
            socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM
        )
        self.sock.settimeout(timeout)
        self.sock.connect((mac, channel))

    def write(self, data):
        self.sock.sendall(data)

    def read(self, n, timeout=1.0):
        self.sock.settimeout(timeout)
        try:
            return self.sock.recv(n)
        except socket.timeout:
            return b""

    def flush_input(self):
        self.sock.settimeout(0.05)
        try:
            while self.sock.recv(4096):
                pass
        except (socket.timeout, OSError):
            pass

    def close(self):
        self.sock.close()


# --------------------------------------------------------------------------
# 驱动
# --------------------------------------------------------------------------

class QringPrinter:

    def __init__(self, transport, verbose=False):
        self.t = transport
        self.verbose = verbose

    # ---- 底层 ----

    def _send(self, data):
        """按 SDK 的方式分包：每 1024 字节一包，包间 1ms"""
        if self.verbose and len(data) <= 32:
            print(f"  TX {data.hex(' ').upper()}")
        elif self.verbose:
            print(f"  TX {len(data)} bytes ({data[:16].hex(' ').upper()} ...)")

        for off in range(0, len(data), CHUNK):
            self.t.write(data[off:off + CHUNK])
            time.sleep(0.001)

    def _query(self, cmd, nbytes=64, timeout=1.5):
        """清空输入 → 发命令 → 读响应（SDK 的固定套路）"""
        self.t.flush_input()
        self._send(cmd)
        time.sleep(0.15)
        resp = self.t.read(nbytes, timeout=timeout)
        if self.verbose and resp:
            print(f"  RX {resp.hex(' ').upper()}")
        return resp

    # ---- 状态查询 ----

    def status(self):
        """返回 (是否正常, 描述列表, 原始字节)"""
        resp = self._query(CMD_STATUS, 1)
        if not resp:
            return False, ["无响应"], None
        b = resp[0]
        problems = [name for mask, name in STATUS_BITS if b & mask]
        return (b == 0), (problems or ["正常"]), b

    def battery(self):
        resp = self._query(CMD_BATTERY, 2)
        return resp[1] if len(resp) >= 2 else None

    def _query_str(self, cmd):
        resp = self._query(cmd, 64)
        if not resp:
            return None
        return resp.decode("gb2312", errors="replace").strip("\x00").strip()

    def info(self):
        return {
            "型号":       self._query_str(CMD_MODEL),
            "序列号":     self._query_str(CMD_SN),
            "固件版本":   self._query_str(CMD_FW_VERSION),
            "蓝牙名":     self._query_str(CMD_BT_NAME),
            "蓝牙版本":   self._query_str(CMD_BT_VERSION),
            "MAC":        (lambda r: r.hex(':').upper() if r else None)(
                              self._query(CMD_BT_MAC, 16)),
            "电池":       self.battery(),
        }

    # ---- 设置 ----

    def set_thickness(self, level):
        """打印浓度 / 加热强度。APP 打文字用 1"""
        self._send(bytes([0x10, 0xFF, 0x10, 0x00, level & 0xFF]))

    def set_shutdown_time(self, seconds):
        """自动关机时间，大端 16 位"""
        self._send(bytes([0x10, 0xFF, 0x12,
                          (seconds // 256) & 0xFF, seconds % 256]))

    # ---- 打印原语 ----

    def enable(self):
        self._send(CMD_ENABLE)
        self._send(CMD_ENABLE2)

    def stop(self):
        self._send(CMD_STOP)

    def wakeup(self):
        self._send(CMD_WAKEUP)

    def feed(self, dots):
        """ESC J n — 走纸 n 点行。n 是单字节，>255 自动拆分"""
        while dots > 0:
            n = min(dots, 255)
            self._send(bytes([0x1B, 0x4A, n]))
            dots -= n

    def print_raster(self, data, width_bytes, height, mode=0):
        """GS v 0 — 发送光栅位图"""
        header = bytes([
            0x1D, 0x76, 0x30, mode & 0x03,
            width_bytes % 256, width_bytes // 256,
            height % 256,      height // 256,
        ])
        self._send(header)
        self._send(data)

    def wait_ack(self, timeout=120.0):
        """等待打印完成 ACK (0xAA)，同时处理主动上报的故障帧"""
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            chunk = self.t.read(16, timeout=1.0)
            if not chunk:
                continue
            buf += chunk
            if self.verbose:
                print(f"  RX {chunk.hex(' ').upper()}")

            if ACK_PRINT_DONE in buf:
                return True, "打印完成"

            # FF xx 故障帧
            for i in range(len(buf) - 1):
                if buf[i] == 0xFF and buf[i + 1] in UNSOLICITED:
                    return False, UNSOLICITED[buf[i + 1]]
        return False, "等待 ACK 超时"

    # ---- 高层 ----

    def print_image(self, img, threshold=128, dither=False,
                    feed_before=10, feed_after=100, thickness=None,
                    wakeup=True, wait=True):
        """
        打印 PIL Image。会自动缩放到 384 宽。
        threshold: 灰度阈值，APP 图片用 128、文字用 212
        dither:    True 用 Floyd-Steinberg 抖动（照片效果更好）
        """
        data, w_bytes, height = image_to_raster(img, threshold, dither)

        self.enable()
        if thickness is not None:
            self.set_thickness(thickness)
        if wakeup:
            self.wakeup()
        self.feed(feed_before)
        self.print_raster(data, w_bytes, height)
        self.feed(feed_after)
        self.stop()

        if wait:
            return self.wait_ack()
        return True, "已发送"

    def close(self):
        self.t.close()


# --------------------------------------------------------------------------
# 图像处理
# --------------------------------------------------------------------------

def image_to_raster(img, threshold=128, dither=False):
    """
    PIL Image → (光栅字节, 每行字节数, 高度)

    编码规则（与 com.beeprt.sdk.d.b(Bitmap,int,int) 一致）:
      - 每行 ceil(width/8) 字节
      - MSB first: bit7 = 最左像素
      - 置 1 = 黑
    """
    if img.mode in ("RGBA", "LA", "P"):
        # 透明区域按白色处理（SDK: alpha==0 视为不打印）
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        img = Image.alpha_composite(bg, img)

    img = img.convert("L")

    # 等比缩放到 384 宽
    if img.width != WIDTH_DOTS:
        h = max(1, round(img.height * WIDTH_DOTS / img.width))
        img = img.resize((WIDTH_DOTS, h), Image.LANCZOS)

    # PIL "1" 模式 tobytes(): 像素非 0 → bit 1。
    # 打印机要求 bit 1 = 黑，所以让"源像素偏暗"映射到 255。
    if dither:
        # 先反相再抖动，等价于对原图抖动后取反，但避开 "1" 模式不能 invert 的问题
        bw = ImageOps.invert(img).convert("1")      # Floyd-Steinberg
    else:
        bw = img.point(lambda p: 255 if p < threshold else 0, mode="1")

    height = bw.height
    packed = bw.tobytes()                # PIL 已是 MSB-first、每行对齐到字节
    row_bytes = (WIDTH_DOTS + 7) // 8    # 384/8 = 48，无补位

    if len(packed) != row_bytes * height:
        raise RuntimeError(
            f"光栅长度异常: {len(packed)} != {row_bytes} * {height}")
    return packed, row_bytes, height


def text_to_image(text, font_path=None, font_size=24, margin=8, line_spacing=6):
    """把文字渲染成 384 宽的图片（自动换行）"""
    if font_path:
        font = ImageFont.truetype(font_path, font_size)
    else:
        for p in (r"C:\Windows\Fonts\msyh.ttc",
                  r"C:\Windows\Fonts\simhei.ttf",
                  "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
                  "/System/Library/Fonts/PingFang.ttc"):
            try:
                font = ImageFont.truetype(p, font_size)
                break
            except OSError:
                continue
        else:
            font = ImageFont.load_default()

    usable = WIDTH_DOTS - 2 * margin
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))

    lines = []
    for para in text.split("\n"):
        if not para:
            lines.append("")
            continue
        cur = ""
        for ch in para:
            if probe.textlength(cur + ch, font=font) <= usable:
                cur += ch
            else:
                lines.append(cur)
                cur = ch
        lines.append(cur)

    lh = font_size + line_spacing
    img = Image.new("L", (WIDTH_DOTS, margin * 2 + lh * len(lines)), 255)
    d = ImageDraw.Draw(img)
    for i, ln in enumerate(lines):
        d.text((margin, margin + i * lh), ln, font=font, fill=0)
    return img


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="小印 (Qring/BY) 热敏打印机控制")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--port", help="串口 (Windows: COM5 / Linux: /dev/rfcomm0)")
    src.add_argument("--mac",  help="蓝牙 MAC，直连 RFCOMM (仅 Linux)")
    ap.add_argument("--channel", type=int, default=1, help="RFCOMM 通道，默认 1")

    act = ap.add_mutually_exclusive_group(required=True)
    act.add_argument("--info",   action="store_true", help="读取打印机信息")
    act.add_argument("--status", action="store_true", help="读取状态")
    act.add_argument("--image",  help="打印图片文件")
    act.add_argument("--text",   help="打印文字")
    act.add_argument("--feed",   type=int, help="走纸 N 点行")

    ap.add_argument("--threshold", type=int, default=128, help="二值化阈值，默认 128（文字建议 212）")
    ap.add_argument("--dither",    action="store_true",   help="用抖动代替阈值（照片效果更好）")
    ap.add_argument("--thickness", type=int, help="打印浓度，APP 文字模式用 1")
    ap.add_argument("--font",      help="字体文件路径")
    ap.add_argument("--font-size", type=int, default=24)
    ap.add_argument("--no-wait",   action="store_true", help="不等打印完成 ACK")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印收发字节")
    args = ap.parse_args()

    if args.mac:
        if not hasattr(socket, "AF_BLUETOOTH"):
            sys.exit("当前平台不支持 AF_BLUETOOTH，请用 --port")
        transport = RfcommTransport(args.mac, args.channel)
    else:
        transport = SerialTransport(args.port)

    p = QringPrinter(transport, verbose=args.verbose)
    try:
        if args.info:
            for k, v in p.info().items():
                print(f"{k:10s}: {v}")

        elif args.status:
            ok, problems, raw = p.status()
            raw_s = f"0x{raw:02X}" if raw is not None else "N/A"
            print(f"状态字节: {raw_s}")
            print(f"结论    : {'正常' if ok else '异常'} — {', '.join(problems)}")

        elif args.feed is not None:
            p.enable()
            p.feed(args.feed)
            p.stop()
            print(f"已走纸 {args.feed} 点行")

        else:
            if Image is None:
                sys.exit("需要 Pillow: pip install pillow")

            if args.image:
                img = Image.open(args.image)
                threshold = args.threshold
            else:
                img = text_to_image(args.text, args.font, args.font_size)
                threshold = args.threshold if args.threshold != 128 else 212

            ok, msg = p.print_image(
                img,
                threshold=threshold,
                dither=args.dither,
                thickness=args.thickness,
                wait=not args.no_wait,
            )
            print(("[OK] " if ok else "[FAIL] ") + msg)
            if not ok:
                sys.exit(1)
    finally:
        p.close()


if __name__ == "__main__":
    main()
