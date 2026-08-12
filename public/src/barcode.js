/**
 * 条码编码 —— 零依赖
 *
 * 一维码统一输出「模块位串」：'1' = 黑条，'0' = 空白，一个字符就是一个最窄模块。
 * 二维码输出布尔矩阵。两者最后都由 renderCode() 画成 384 点宽的画布 ——
 * 必须正好 384，因为 rasterize() 会把图源缩放到 384，条码一旦被重采样就废了。
 *
 * 码制的取舍：只做能自己写对、也验得过的那些。
 * Data Matrix / PDF417 / Aztec 各自是一整套独立编码器（还带自己的纠错体系），
 * 与其塞个半对的进去，不如不做 —— 二维场景 QR 已经够用。
 */

import { encodeQr } from './qrcode.js';

/* ══ Code 128 ═══════════════════════════════════════════
 * 107 个字符各 11 模块，按「条空条空条空」六段宽度记。
 * 停止符是唯一的 13 模块（七段）。
 */
const C128 = [
  '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312',
  '132212', '221213', '221312', '231212', '112232', '122132', '122231', '113222',
  '123122', '123221', '223211', '221132', '221231', '213212', '223112', '312131',
  '311222', '321122', '321221', '312212', '322112', '322211', '212123', '212321',
  '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
  '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121',
  '313121', '211331', '231131', '213113', '213311', '213131', '311123', '311321',
  '331121', '312113', '312311', '332111', '314111', '221411', '431111', '111224',
  '111422', '121124', '121421', '141122', '141221', '112214', '112412', '122114',
  '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
  '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112',
  '421211', '212141', '214121', '412121', '111143', '111341', '131141', '114113',
  '114311', '411113', '411311', '113141', '114131', '311141', '411131', '211412',
  '211214', '211232', '2331112',
];

/** 宽度串 → 位串。第一段永远是条 */
function widthsToBits(w) {
  let out = '';
  for (let i = 0; i < w.length; i++) out += (i % 2 === 0 ? '1' : '0').repeat(+w[i]);
  return out;
}

const isDigit = c => c >= '0' && c <= '9';

function code128(text) {
  const runLen = p => { let n = 0; while (p + n < text.length && isDigit(text[p + n])) n++; return n; };
  const vals = [];
  let i = 0;

  // 起始码：开头就是一长串数字的话直接用 C，两位一码字，最省
  const head = runLen(0);
  let start;
  if (head >= 4 && (head % 2 === 0 || head < text.length)) start = 105;
  else start = /[\x00-\x1F]/.test(text[0]) ? 103 : 104;
  let mode = start === 105 ? 'C' : start === 103 ? 'A' : 'B';
  if (mode === 'C' && head % 2 === 1) { start = 104; mode = 'B'; }   // 奇数位先走 B

  while (i < text.length) {
    if (mode === 'C') {
      if (runLen(i) >= 2) { vals.push(+text.substr(i, 2)); i += 2; continue; }
      vals.push(100); mode = 'B'; continue;                          // 切回 B
    }
    const n = runLen(i);
    if (n >= 4) {
      if (n % 2 === 1) { vals.push(charVal(text, i, mode)); i++; }    // 奇数先吃一位
      vals.push(99); mode = 'C'; continue;                            // 切 C
    }
    const c = text.charCodeAt(i);
    if (mode === 'B' && c < 32) { vals.push(101); mode = 'A'; continue; }
    if (mode === 'A' && c >= 96) { vals.push(100); mode = 'B'; continue; }
    vals.push(charVal(text, i, mode));
    i++;
  }

  let sum = start;
  vals.forEach((v, k) => { sum += v * (k + 1); });
  const seq = [start, ...vals, sum % 103, 106];
  return seq.map(v => widthsToBits(C128[v])).join('');
}

function charVal(text, i, mode) {
  const c = text.charCodeAt(i);
  if (mode === 'A') return c < 32 ? c + 64 : c - 32;
  return c - 32;
}

/* ══ Code 39 ════════════════════════════════════════════
 * 每字符 9 段（5 条 4 空）里恰好 3 段是宽的，合计 12 模块；字符间留 1 模块空。
 */
const C39 = {
  '0': '101001101101', '1': '110100101011', '2': '101100101011', '3': '110110010101',
  '4': '101001101011', '5': '110100110101', '6': '101100110101', '7': '101001011011',
  '8': '110100101101', '9': '101100101101', 'A': '110101001011', 'B': '101101001011',
  'C': '110110100101', 'D': '101011001011', 'E': '110101100101', 'F': '101101100101',
  'G': '101010011011', 'H': '110101001101', 'I': '101101001101', 'J': '101011001101',
  'K': '110101010011', 'L': '101101010011', 'M': '110110101001', 'N': '101011010011',
  'O': '110101101001', 'P': '101101101001', 'Q': '101010110011', 'R': '110101011001',
  'S': '101101011001', 'T': '101011011001', 'U': '110010101011', 'V': '100110101011',
  'W': '110011010101', 'X': '100101101011', 'Y': '110010110101', 'Z': '100110110101',
  '-': '100101011011', '.': '110010101101', ' ': '100110101101', '$': '100100100101',
  '/': '100100101001', '+': '100101001001', '%': '101001001001', '*': '100101101101',
};

function code39(text) {
  const chars = ['*', ...text.toUpperCase(), '*'];
  return chars.map(c => {
    const p = C39[c];
    if (!p) throw new Error(`Code 39 不支持字符「${c}」`);
    return p;
  }).join('0');                       // 字符间 1 模块空
}

/* ══ EAN / UPC ══════════════════════════════════════════
 * L 组奇校验、G 组是 R 组反过来读、R 组是 L 组按位取反 —— 这三条关系
 * 在 barcode-test 里会被逐条验，抄错一位就会被抓出来。
 */
const EAN_L = ['0001101', '0011001', '0010011', '0111101', '0100011',
               '0110001', '0101111', '0111011', '0110111', '0001011'];
const EAN_R = EAN_L.map(s => [...s].map(b => b === '0' ? '1' : '0').join(''));
const EAN_G = EAN_R.map(s => [...s].reverse().join(''));
/** 首位数字决定前 6 位用 L 还是 G */
const EAN_PARITY = ['LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG',
                    'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL'];

/** EAN/UPC 通用校验位：从右往左 3、1 交替加权 */
function eanCheck(digits) {
  let sum = 0;
  for (let i = digits.length - 1, w = 3; i >= 0; i--, w = 4 - w) sum += +digits[i] * w;
  return (10 - sum % 10) % 10;
}

function ean13(text) {
  const d = text.length === 12 ? text + eanCheck(text) : text;
  if (+d[12] !== eanCheck(d.slice(0, 12))) throw new Error(`校验位应为 ${eanCheck(d.slice(0, 12))}`);
  const parity = EAN_PARITY[+d[0]];
  let bits = '101';
  for (let i = 1; i <= 6; i++) bits += (parity[i - 1] === 'L' ? EAN_L : EAN_G)[+d[i]];
  bits += '01010';
  for (let i = 7; i <= 12; i++) bits += EAN_R[+d[i]];
  return { bits: bits + '101', text: d };
}

function ean8(text) {
  const d = text.length === 7 ? text + eanCheck(text) : text;
  if (+d[7] !== eanCheck(d.slice(0, 7))) throw new Error(`校验位应为 ${eanCheck(d.slice(0, 7))}`);
  let bits = '101';
  for (let i = 0; i < 4; i++) bits += EAN_L[+d[i]];
  bits += '01010';
  for (let i = 4; i < 8; i++) bits += EAN_R[+d[i]];
  return { bits: bits + '101', text: d };
}

/** UPC-A 就是首位补 0 的 EAN-13，直接借道，省一套表 */
function upcA(text) {
  const d = text.length === 11 ? text + eanCheck(text) : text;
  if (+d[11] !== eanCheck(d.slice(0, 11))) throw new Error(`校验位应为 ${eanCheck(d.slice(0, 11))}`);
  return { bits: ean13('0' + d).bits, text: d };
}

/* ══ ITF（交叉二五码）═══════════════════════════════════
 * 两位一组：前一位的 5 段当条，后一位的 5 段当空，交叉排开 —— 所以位数必须是偶数。
 */
const ITF = ['nnwwn', 'wnnnw', 'nwnnw', 'wwnnn', 'nnwnw',
             'wnwnn', 'nwwnn', 'nnnww', 'wnnwn', 'nwnwn'];

function itf(text) {
  if (text.length % 2) throw new Error('ITF 按两位一组编码，位数必须是偶数');
  let bits = '1010';                                  // 起始
  for (let i = 0; i < text.length; i += 2) {
    const a = ITF[+text[i]], b = ITF[+text[i + 1]];
    for (let k = 0; k < 5; k++) {
      bits += '1'.repeat(a[k] === 'w' ? 3 : 1);
      bits += '0'.repeat(b[k] === 'w' ? 3 : 1);
    }
  }
  return bits + '11101';                              // 终止
}

/* ══ 码制清单 ═══════════════════════════════════════════ */

const RE_DIGITS = /^[0-9]+$/;
const RE_C39 = /^[0-9A-Z\-. $/+%]+$/;
const RE_ASCII = /^[\x00-\x7F]+$/;

export const CODE_TYPES = [
  {
    id: 'code128', label: 'Code 128', kind: '1d', sample: 'QRING-0001',
    hint: '任意 ASCII 字符，长度不限。一维码里兼容性最好的选择',
    validate: c => RE_ASCII.test(c) ? null : 'Code 128 只支持 ASCII 字符（0–127），不能含中文',
    encode: c => ({ bits: code128(c), text: c }),
  },
  {
    id: 'code39', label: 'Code 39', kind: '1d', sample: 'QRING-001',
    hint: '数字、大写字母 A–Z，以及 - . $ / + % 和空格',
    validate: c => RE_C39.test(c.toUpperCase()) ? null : '只能是数字、大写字母，以及 - . $ / + % 和空格',
    encode: c => ({ bits: code39(c), text: c.toUpperCase() }),
  },
  {
    id: 'ean13', label: 'EAN-13', kind: '1d', sample: '6901234567892',
    hint: '13 位纯数字（含校验位）；也可只输 12 位，自动补校验位',
    validate: c => !RE_DIGITS.test(c) ? 'EAN-13 只能是纯数字'
      : (c.length !== 12 && c.length !== 13) ? `需要 12 或 13 位数字，当前 ${c.length} 位` : null,
    encode: ean13,
  },
  {
    id: 'ean8', label: 'EAN-8', kind: '1d', sample: '69012341',
    hint: '8 位纯数字（含校验位）；也可只输 7 位',
    validate: c => !RE_DIGITS.test(c) ? 'EAN-8 只能是纯数字'
      : (c.length !== 7 && c.length !== 8) ? `需要 7 或 8 位数字，当前 ${c.length} 位` : null,
    encode: ean8,
  },
  {
    id: 'upca', label: 'UPC-A', kind: '1d', sample: '012345678905',
    hint: '12 位纯数字（含校验位）；也可只输 11 位',
    validate: c => !RE_DIGITS.test(c) ? 'UPC-A 只能是纯数字'
      : (c.length !== 11 && c.length !== 12) ? `需要 11 或 12 位数字，当前 ${c.length} 位` : null,
    encode: upcA,
  },
  {
    id: 'itf', label: 'ITF / ITF-14', kind: '1d', sample: '06901234567892',
    hint: '纯数字，位数必须是偶数。ITF-14 固定 14 位',
    validate: c => !RE_DIGITS.test(c) ? 'ITF 只能是纯数字'
      : c.length % 2 ? `位数必须是偶数，当前 ${c.length} 位` : null,
    encode: c => ({ bits: itf(c), text: c }),
  },
  {
    id: 'qr', label: 'QR Code', kind: '2d', sample: 'https://example.com',
    hint: '任意文本，中文按 UTF-8 编码。纠错等级越高越抗污损，但同样内容要占更多格子',
    validate: () => null,
    encode: (c, opts) => ({ qr: encodeQr(c, opts) }),
  },
];

export const findType = id => CODE_TYPES.find(t => t.id === id) ?? CODE_TYPES[0];

/* ══ 绘制 ═══════════════════════════════════════════════ */

const WIDTH = 384;                 // 必须和 protocol.js 的 WIDTH_DOTS 一致
const QUIET_1D = 10;               // 一维码两侧静区，标准建议 ≥10 模块
const QUIET_QR = 4;                // 二维码静区，标准规定 4 模块

/**
 * 画成 384 点宽的画布，直接交给 rasterize（缩放比 1:1，不会被重采样糊掉）。
 *
 * @param {string} typeId
 * @param {string} content
 * @param {{ecl?:string, height?:number, showText?:boolean}} opts
 */
export function renderCode(typeId, content, { ecl = 'M', height = 96, showText = true } = {}) {
  const type = findType(typeId);
  const err = type.validate(content);
  if (err) throw new Error(err);
  const out = type.encode(content, { ecl });

  return out.qr ? drawQr(out.qr, showText)
                : drawLinear(out.bits, out.text, type.label, height, showText);
}

function newCanvas(h) {
  const cv = document.createElement('canvas');
  cv.width = WIDTH;
  cv.height = Math.max(1, Math.round(h));
  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, cv.width, cv.height);
  ctx.fillStyle = '#000';
  return { cv, ctx };
}

function drawLinear(bits, text, label, height, showText) {
  // 模块宽取整，否则条宽忽粗忽细，扫描枪会读错
  const mw = Math.floor((WIDTH - QUIET_1D * 2) / bits.length);
  if (mw < 1) {
    throw new Error(`内容太长：需要 ${bits.length} 个模块，384 点宽最多放 ${WIDTH - QUIET_1D * 2} 个。` +
                    '换 QR 或缩短内容');
  }
  const textH = showText ? 26 : 0;
  const { cv, ctx } = newCanvas(height + textH + 8);
  const x0 = Math.floor((WIDTH - bits.length * mw) / 2);

  for (let i = 0; i < bits.length; i++) {
    if (bits[i] === '1') ctx.fillRect(x0 + i * mw, 4, mw, height);
  }
  if (showText) {
    ctx.font = '20px ui-monospace, Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillText(text, WIDTH / 2, height + 9);
  }
  return cv;
}

function drawQr(qr, showText) {
  const mw = Math.floor(WIDTH / (qr.size + QUIET_QR * 2));
  const side = (qr.size + QUIET_QR * 2) * mw;
  const textH = showText ? 22 : 0;
  const { cv, ctx } = newCanvas(side + textH);
  const off = Math.floor((WIDTH - side) / 2) + QUIET_QR * mw;

  for (let y = 0; y < qr.size; y++) {
    for (let x = 0; x < qr.size; x++) {
      if (qr.modules[y][x]) ctx.fillRect(off + x * mw, QUIET_QR * mw + y * mw, mw, mw);
    }
  }
  if (showText) {
    ctx.font = '15px ui-monospace, Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillText(`QR v${qr.version}-${qr.ecl}`, WIDTH / 2, side + 2);
  }
  return cv;
}
