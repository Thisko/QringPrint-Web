/**
 * Qring / BeePrt 热敏打印机私有协议
 *
 * 来源：qring-spp.py（对 com.zxxk.xiaoyin.App 逆向整理）
 * 实机验证：Qring X1 / 固件 V1.05 / BLE 名 Qring_D6E9_BLE
 *
 * 这不是标准 ESC/POS。只有走纸(ESC J)和光栅位图(GS v 0)沿用了 ESC/POS，
 * 状态、电量、型号全走自己的 10 FF 系列。
 */

export const WIDTH_DOTS  = 384;   // 58mm 热敏头
export const WIDTH_BYTES = 48;    // 384 / 8，无补位

// ── 打印控制 ──────────────────────────────────────────────
export const CMD_ENABLE  = Uint8Array.of(0x10, 0xFF, 0xF1, 0x02);
export const CMD_ENABLE2 = Uint8Array.of(0x1F, 0xB2, 0x10);
export const CMD_STOP    = Uint8Array.of(0x10, 0xFF, 0xF1, 0x45);
export const CMD_WAKEUP  = new Uint8Array(12);                    // 12 × 0x00

// ── 查询 ─────────────────────────────────────────────────
export const CMD_STATUS  = Uint8Array.of(0x10, 0xFF, 0x40);       // → 1 字节
export const CMD_BATTERY = Uint8Array.of(0x10, 0xFF, 0x50, 0xF1); // → 2 字节，第 2 字节是百分比
export const CMD_MODEL   = Uint8Array.of(0x10, 0xFF, 0x20, 0xF0);
export const CMD_FW      = Uint8Array.of(0x10, 0xFF, 0x20, 0xF1);
export const CMD_SN      = Uint8Array.of(0x10, 0xFF, 0x20, 0xF2);
export const CMD_BT_NAME = Uint8Array.of(0x10, 0xFF, 0x30, 0x11);
export const CMD_BT_VER  = Uint8Array.of(0x10, 0xFF, 0x30, 0x10);
export const CMD_BT_MAC  = Uint8Array.of(0x10, 0xFF, 0x30, 0x12);

/* ⚠️ 不要发 10 FF 70。
 *
 * Python 里叫 CMD_INFO，但 info() 从头到尾没调用过它 —— 原因实测出来了：
 * 这条命令不回包，而且会把机器打进哑状态，之后所有查询一起失效，
 * 必须断电重启才恢复。这里刻意不定义常量，避免手滑发出去。
 */

// ── 参数设置 ──────────────────────────────────────────────
/** 打印浓度 / 加热强度。APP 打文字用 1 */
export const cmdThickness = level => Uint8Array.of(0x10, 0xFF, 0x10, 0x00, level & 0xFF);
/** 自动关机时间，大端 16 位 */
export const cmdShutdown  = sec => Uint8Array.of(0x10, 0xFF, 0x12, (sec >> 8) & 0xFF, sec & 0xFF);

// ── 打印原语 ──────────────────────────────────────────────
/** ESC J n —— 走纸 n 点行。n 是单字节，>255 由 printer.js 拆条 */
export const cmdFeed = n => Uint8Array.of(0x1B, 0x4A, n & 0xFF);

/** GS v 0 —— 光栅位图头 */
export const cmdRasterHeader = (widthBytes, height, mode = 0) => Uint8Array.of(
  0x1D, 0x76, 0x30, mode & 0x03,
  widthBytes & 0xFF, (widthBytes >> 8) & 0xFF,
  height     & 0xFF, (height     >> 8) & 0xFF,
);

// ── 响应解析 ──────────────────────────────────────────────
export const ACK_PRINT_DONE = 0xAA;

const STATUS_BITS = [
  [0x01, '正在打印'],
  [0x02, '机身异常 / 开盖'],
  [0x04, '缺纸'],
  [0x08, '电池电压低'],
  [0x10, '过热'],
];

/** FF xx 主动上报帧 */
export const UNSOLICITED = {
  0x01: '缺纸',
  0x02: '开盖',
  0x03: '过热',
  0x04: '低电量',
};

/**
 * 解析状态字节。
 * 注意顺序：开盖必须排在缺纸前面 —— 上盖打开时纸传感器看不到纸，
 * 会把缺纸位一起置起来，此时提示「缺纸」是误导。
 */
export function parseStatus(byte) {
  if (byte === 0) return { ok: true, problems: [], text: '正常' };
  const problems = STATUS_BITS.filter(([m]) => byte & m).map(([, s]) => s);
  const primary =
    byte & 0x02 ? '上盖未合' :
    byte & 0x04 ? '缺纸'     :
    byte & 0x10 ? '过热'     :
    byte & 0x08 ? '电量过低' :
    byte & 0x01 ? '正在打印' : '未知状态';
  return { ok: false, problems, text: primary };
}

/** 在缓冲里找故障帧 FF xx，找到返回文案 */
export function findFault(bytes) {
  for (let i = 0; i < bytes.length - 1; i++) {
    if (bytes[i] === 0xFF && UNSOLICITED[bytes[i + 1]]) return UNSOLICITED[bytes[i + 1]];
  }
  return null;
}

/**
 * 剥掉混进响应里的 FF xx 主动上报帧。
 * 用户随时可能开合上盖，故障帧会插在任意位置，不剥掉字符串就解码成乱码。
 */
export function stripFaultFrames(bytes) {
  const out = [];
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 0xFF && UNSOLICITED[bytes[i + 1]]) { i++; continue; }
    out.push(bytes[i]);
  }
  return Uint8Array.from(out);
}

/** 固件字符串是 GB2312；gb18030 是其超集，Chrome / Bluefy 都认 */
export function decodeText(u8) {
  try {
    return new TextDecoder('gb18030').decode(u8).replace(/\0+$/, '').trim();
  } catch {
    return new TextDecoder().decode(u8).replace(/\0+$/, '').trim();
  }
}

export const toHex = u8 =>
  [...u8].map(b => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
