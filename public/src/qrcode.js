/**
 * QR Code 编码器 —— 零依赖，按 ISO/IEC 18004 实现
 *
 * 为什么不挂个库：这个项目是纯静态站，扔到 CF 上就是几个文件，
 * 不想为一个二维码引入构建步骤和 npm 依赖树。
 *
 * 输出是布尔矩阵（true = 黑模块），不含静区 —— 静区留给绘制那一层加，
 * 因为热敏纸上留白多少要看整体排版。
 */

/* ── GF(256) ──────────────────────────────────────────────
 * 本原多项式 0x11D（x⁸+x⁴+x³+x²+1），QR 规定的就是这个。
 * EXP 开到 512 长，是为了让 LOG[a]+LOG[b] 直接查表，省一次取模。
 */
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(function initGf() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11D;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const gfMul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]];

/** 生成多项式 (x-α⁰)(x-α¹)…(x-α^(d-1))，降幂排列，最高次系数恒为 1 */
function rsGenerator(degree) {
  let poly = [1];
  let root = 1;
  for (let i = 0; i < degree; i++) {
    const out = new Array(poly.length + 1).fill(0);
    for (let j = 0; j < poly.length; j++) {
      out[j] ^= poly[j];                       // 乘 x：数组变长一位，下标不动
      out[j + 1] ^= gfMul(poly[j], root);      // 加 α^i · poly
    }
    poly = out;
    root = gfMul(root, 2);
  }
  return poly;
}

/** data 除以生成多项式的余数，就是纠错码字 */
export function rsRemainder(data, degree) {
  const gen = rsGenerator(degree);
  const rem = new Uint8Array(degree);
  for (const b of data) {
    const factor = b ^ rem[0];
    rem.copyWithin(0, 1);
    rem[degree - 1] = 0;
    for (let i = 0; i < degree; i++) rem[i] ^= gfMul(gen[i + 1], factor);
  }
  return rem;
}

/* ── 版本表 ───────────────────────────────────────────────
 * 下标 = 版本号（1–40），0 位占位。这两张表是标准里抄下来的，
 * 别的量（总码字数、数据码字数）都由它们和 rawDataModules 算出来，
 * 不再单独存表 —— 少一张表就少一处抄错的机会。
 */
const ECC_PER_BLOCK = {
  L: [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
      28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  M: [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
      26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  Q: [0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
      28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  H: [0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
      30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
};

const NUM_BLOCKS = {
  L: [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
      8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  M: [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
      17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  Q: [0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
      23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  H: [0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
      25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
};

/** 纠错等级在格式信息里的编码，注意不是 0123 的顺序 */
const ECL_BITS = { L: 1, M: 0, Q: 3, H: 2 };
export const ECC_LEVELS = ['L', 'M', 'Q', 'H'];

/** 除去功能图形后能放数据的模块数（含纠错），标准附录的那个公式 */
function rawDataModules(ver) {
  let n = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const numAlign = Math.floor(ver / 7) + 2;
    n -= (25 * numAlign - 10) * numAlign - 55;
    if (ver >= 7) n -= 36;                     // 两块版本信息
  }
  return n;
}

/** 该版本 + 纠错等级下，留给数据的码字数 */
export function dataCodewords(ver, ecl) {
  return Math.floor(rawDataModules(ver) / 8) - ECC_PER_BLOCK[ecl][ver] * NUM_BLOCKS[ecl][ver];
}

/**
 * 分块布局。短块排在前面，长块比短块多一个数据码字 —— 交织顺序全靠这个。
 * 编码和校验都从这一处取，免得两边各算一遍算岔了。
 */
export function blockLayout(ver, ecl) {
  const numBlocks = NUM_BLOCKS[ecl][ver];
  const eccLen = ECC_PER_BLOCK[ecl][ver];
  const total = Math.floor(rawDataModules(ver) / 8);
  const shortLen = Math.floor(total / numBlocks) - eccLen;
  return { numBlocks, eccLen, total, shortLen, numShort: numBlocks - total % numBlocks };
}

/** 校正图形的中心坐标。版本 1 没有 */
function alignPositions(ver) {
  if (ver === 1) return [];
  const num = Math.floor(ver / 7) + 2;
  // 32 是唯一一个不能用通式算出来的版本，标准里就是特例
  const step = ver === 32 ? 26 : Math.ceil((ver * 4 + 4) / (num * 2 - 2)) * 2;
  const out = [6];
  for (let pos = ver * 4 + 10; out.length < num; pos -= step) out.splice(1, 0, pos);
  return out;
}

/* ── 数据编码 ─────────────────────────────────────────── */

const ALNUM = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/** 字符数指示符的位宽，随版本分三段：1–9 / 10–26 / 27–40 */
const CCI_BITS = {
  numeric: [10, 12, 14],
  alnum:   [9, 11, 13],
  byte:    [8, 16, 16],
};
const MODE_BITS = { numeric: 1, alnum: 2, byte: 4 };
const cciIndex = ver => (ver <= 9 ? 0 : ver <= 26 ? 1 : 2);

/** 选最省位的模式。混合分段能再省一点，但收益有限、复杂度高不少，不做 */
function pickMode(text) {
  if (/^[0-9]*$/.test(text)) return 'numeric';
  for (const ch of text) if (!ALNUM.includes(ch)) return 'byte';
  return 'alnum';
}

class BitBuf {
  constructor() { this.bits = []; }
  push(value, len) {
    for (let i = len - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
  }
  get length() { return this.bits.length; }
}

function encodeSegment(buf, text, mode) {
  if (mode === 'numeric') {
    for (let i = 0; i < text.length; i += 3) {
      const chunk = text.substring(i, i + 3);
      buf.push(parseInt(chunk, 10), chunk.length * 3 + 1);   // 3→10, 2→7, 1→4
    }
  } else if (mode === 'alnum') {
    for (let i = 0; i < text.length; i += 2) {
      if (i + 1 < text.length) {
        buf.push(ALNUM.indexOf(text[i]) * 45 + ALNUM.indexOf(text[i + 1]), 11);
      } else {
        buf.push(ALNUM.indexOf(text[i]), 6);
      }
    }
  } else {
    for (const b of new TextEncoder().encode(text)) buf.push(b, 8);
  }
}

/** byte 模式按 UTF-8 字节数算，别拿 length 当字符数 */
function charCount(text, mode) {
  return mode === 'byte' ? new TextEncoder().encode(text).length : text.length;
}

function segmentBits(text, mode, ver) {
  const n = charCount(text, mode);
  let body;
  if (mode === 'numeric') body = Math.ceil(n / 3) * 10 - (n % 3 === 1 ? 6 : n % 3 === 2 ? 3 : 0);
  else if (mode === 'alnum') body = Math.floor(n / 2) * 11 + (n % 2) * 6;
  else body = n * 8;
  return 4 + CCI_BITS[mode][cciIndex(ver)] + body;
}

/* ── 矩阵 ─────────────────────────────────────────────── */

class Matrix {
  constructor(ver) {
    this.ver = ver;
    this.size = ver * 4 + 17;
    this.m = Array.from({ length: this.size }, () => new Uint8Array(this.size));
    this.fn = Array.from({ length: this.size }, () => new Uint8Array(this.size));
  }
  set(x, y, dark, isFn = false) {
    this.m[y][x] = dark ? 1 : 0;
    if (isFn) this.fn[y][x] = 1;
  }
  get(x, y) { return this.m[y][x]; }
}

function drawFunction(mx) {
  const size = mx.size;

  // 定位图形 + 分隔带。分隔带必须画（画成白），不然会和数据区连起来
  for (const [cx, cy] of [[0, 0], [size - 7, 0], [0, size - 7]]) {
    for (let dy = -1; dy <= 7; dy++) {
      for (let dx = -1; dx <= 7; dx++) {
        const x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        const d = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
        mx.set(x, y, d !== 2 && d <= 3, true);
      }
    }
  }

  // 定时图形
  for (let i = 8; i < size - 8; i++) {
    mx.set(i, 6, i % 2 === 0, true);
    mx.set(6, i, i % 2 === 0, true);
  }

  // 校正图形，跟定位图形重叠的三个角跳过
  const pos = alignPositions(mx.ver);
  for (const cy of pos) {
    for (const cx of pos) {
      const corner = (cx === 6 && cy === 6) ||
                     (cx === 6 && cy === size - 7) ||
                     (cx === size - 7 && cy === 6);
      if (corner) continue;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) {
          mx.set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1, true);
        }
      }
    }
  }

  // 固定的那个黑模块
  mx.set(8, size - 8, true, true);

  // 格式信息的位置先占住（内容等选完掩码再填）。
  // 注意 i === 6 要跳过：那两格 (8,6) 和 (6,8) 是定时图形穿过来的，
  // 不属于格式信息 —— 顺手抹白的话整块定时图形就断了，码直接扫不出来。
  for (let i = 0; i < 9; i++) {
    if (i !== 6) { mx.set(8, i, false, true); mx.set(i, 8, false, true); }
  }
  for (let i = 0; i < 8; i++) {
    mx.set(size - 1 - i, 8, false, true);
    if (i < 7) mx.set(8, size - 1 - i, false, true);
  }

  if (mx.ver >= 7) {
    const bits = bchVersion(mx.ver);
    for (let i = 0; i < 18; i++) {
      const dark = ((bits >> i) & 1) === 1;
      const a = Math.floor(i / 3), b = i % 3;
      mx.set(a, size - 11 + b, dark, true);
      mx.set(size - 11 + b, a, dark, true);
    }
  }
}

/** 格式信息：5 位数据 + BCH(15,5)，再整体异或 0x5412 防止全 0 */
function bchFormat(ecl, mask) {
  const data = (ECL_BITS[ecl] << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

/** 版本信息：6 位版本号 + BCH(18,6) */
function bchVersion(ver) {
  let rem = ver;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25);
  return (ver << 12) | rem;
}

function drawFormat(mx, ecl, mask) {
  const bits = bchFormat(ecl, mask);
  const size = mx.size;
  // 第一份：左上角，绕过第 6 行/列的定时图形
  for (let i = 0; i <= 5; i++) mx.set(8, i, (bits >> i) & 1, true);
  mx.set(8, 7, (bits >> 6) & 1, true);
  mx.set(8, 8, (bits >> 7) & 1, true);
  mx.set(7, 8, (bits >> 8) & 1, true);
  for (let i = 9; i < 15; i++) mx.set(14 - i, 8, (bits >> i) & 1, true);
  // 第二份：右上 + 左下
  for (let i = 0; i < 8; i++) mx.set(size - 1 - i, 8, (bits >> i) & 1, true);
  for (let i = 8; i < 15; i++) mx.set(8, size - 15 + i, (bits >> i) & 1, true);
}

/** 数据按「右起两列一组、蛇形上下」填，跳过第 6 列（那是定时图形） */
function drawCodewords(mx, data) {
  let i = 0;
  const size = mx.size;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vert : vert;
        if (mx.fn[y][x]) continue;
        const bit = i < data.length * 8 && ((data[i >>> 3] >>> (7 - (i & 7))) & 1) === 1;
        mx.m[y][x] = bit ? 1 : 0;
        i++;
      }
    }
  }
}

const MASKS = [
  (x, y) => (x + y) % 2 === 0,
  (x, y) => y % 2 === 0,
  (x, y) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
  (x, y) => (x * y) % 2 + (x * y) % 3 === 0,
  (x, y) => ((x * y) % 2 + (x * y) % 3) % 2 === 0,
  (x, y) => ((x + y) % 2 + (x * y) % 3) % 2 === 0,
];

function applyMask(mx, mask) {
  for (let y = 0; y < mx.size; y++) {
    for (let x = 0; x < mx.size; x++) {
      if (!mx.fn[y][x] && MASKS[mask](x, y)) mx.m[y][x] ^= 1;
    }
  }
}

/** 四条罚分规则，取总分最低的掩码 */
function penalty(mx) {
  const size = mx.size;
  let score = 0;

  // N1：同色连续 ≥5
  for (const horizontal of [true, false]) {
    for (let a = 0; a < size; a++) {
      let run = 1;
      for (let b = 1; b < size; b++) {
        const cur = horizontal ? mx.m[a][b] : mx.m[b][a];
        const prev = horizontal ? mx.m[a][b - 1] : mx.m[b - 1][a];
        if (cur === prev) { run++; if (run === 5) score += 3; else if (run > 5) score += 1; }
        else run = 1;
      }
    }
  }

  // N2：2×2 同色
  for (let y = 0; y < size - 1; y++) {
    for (let x = 0; x < size - 1; x++) {
      const v = mx.m[y][x];
      if (v === mx.m[y][x + 1] && v === mx.m[y + 1][x] && v === mx.m[y + 1][x + 1]) score += 3;
    }
  }

  // N3：出现 1011101 这种类定位图形的序列（两侧留白其一即可）
  const P1 = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
  const P2 = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
  for (const horizontal of [true, false]) {
    for (let a = 0; a < size; a++) {
      for (let b = 0; b + 11 <= size; b++) {
        let m1 = true, m2 = true;
        for (let k = 0; k < 11; k++) {
          const v = horizontal ? mx.m[a][b + k] : mx.m[b + k][a];
          if (v !== P1[k]) m1 = false;
          if (v !== P2[k]) m2 = false;
        }
        if (m1) score += 40;
        if (m2) score += 40;
      }
    }
  }

  // N4：黑模块比例偏离 50%，每偏 5% 加 10
  let dark = 0;
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) dark += mx.m[y][x];
  const k = Math.floor(Math.abs(dark * 20 - size * size * 10) / (size * size));
  score += k * 10;
  return score;
}

/* ── 对外 ─────────────────────────────────────────────── */

/**
 * @param {string} text
 * @param {{ecl?:'L'|'M'|'Q'|'H', minVersion?:number}} opts
 * @returns {{size:number, modules:boolean[][], version:number, ecl:string, mask:number}}
 */
export function encodeQr(text, { ecl = 'M', minVersion = 1 } = {}) {
  if (!text) throw new Error('内容为空');
  const mode = pickMode(text);

  // 选能装下的最小版本
  let ver = 0;
  for (let v = Math.max(1, minVersion); v <= 40; v++) {
    if (segmentBits(text, mode, v) <= dataCodewords(v, ecl) * 8) { ver = v; break; }
  }
  if (!ver) throw new Error(`内容太长，${ecl} 级最大版本也装不下`);

  const capacity = dataCodewords(ver, ecl) * 8;
  const buf = new BitBuf();
  buf.push(MODE_BITS[mode], 4);
  buf.push(charCount(text, mode), CCI_BITS[mode][cciIndex(ver)]);
  encodeSegment(buf, text, mode);

  // 结束符最多 4 位，位数不够就少放几位
  buf.push(0, Math.min(4, capacity - buf.length));
  buf.push(0, (8 - buf.length % 8) % 8);
  // 补足到容量：EC 11 交替，这是标准规定的填充字节
  for (let pad = 0xEC; buf.length < capacity; pad ^= 0xEC ^ 0x11) buf.push(pad, 8);

  const raw = new Uint8Array(capacity / 8);
  for (let i = 0; i < buf.bits.length; i++) {
    if (buf.bits[i]) raw[i >>> 3] |= 0x80 >>> (i & 7);
  }

  // 分块 + 交织
  const { numBlocks, eccLen, total, shortLen, numShort } = blockLayout(ver, ecl);

  const blocks = [];
  for (let i = 0, off = 0; i < numBlocks; i++) {
    const len = shortLen + (i < numShort ? 0 : 1);
    const dat = raw.subarray(off, off + len);
    off += len;
    blocks.push({ dat, ecc: rsRemainder(dat, eccLen) });
  }

  const out = new Uint8Array(total);
  let p = 0;
  for (let i = 0; i < shortLen + 1; i++) {
    for (let b = 0; b < numBlocks; b++) {
      if (i < blocks[b].dat.length) out[p++] = blocks[b].dat[i];
    }
  }
  for (let i = 0; i < eccLen; i++) {
    for (let b = 0; b < numBlocks; b++) out[p++] = blocks[b].ecc[i];
  }

  // 八个掩码全试一遍，取罚分最低的
  let best = null;
  for (let mask = 0; mask < 8; mask++) {
    const mx = new Matrix(ver);
    drawFunction(mx);
    drawCodewords(mx, out);
    applyMask(mx, mask);
    drawFormat(mx, ecl, mask);
    const score = penalty(mx);
    if (!best || score < best.score) best = { score, mx, mask };
  }

  return {
    size: best.mx.size,
    modules: best.mx.m.map(row => Array.from(row, v => v === 1)),
    version: ver,
    ecl,
    mask: best.mask,
  };
}
