/**
 * 图像 / 文本 → 光栅字节
 *
 * 编码规则与 Python image_to_raster()、以及 SDK 的 com.beeprt.sdk.d.b() 一致：
 *   - 每行 48 字节（384 点 / 8）
 *   - MSB first：bit7 = 最左像素
 *   - 置 1 = 黑
 */

import { WIDTH_DOTS, WIDTH_BYTES } from './protocol.js';

/**
 * 可选的抖动算法。热敏机只有黑/白两级，抖动算法的差别比在灰度屏上明显得多。
 * id 直接存进模板/历史，别随便改。
 */
export const DITHER_ALGOS = [
  { id: 'none',     name: '阈值（不抖动）',       hint: '硬切。线稿、文字、二维码用这个' },
  { id: 'floyd',    name: 'Floyd–Steinberg',     hint: '经典误差扩散，照片通用首选' },
  { id: 'atkinson', name: 'Atkinson',            hint: '只扩散 3/4 误差，对比强、画面更干净' },
  { id: 'jarvis',   name: 'Jarvis–Judice–Ninke', hint: '扩散范围最大，最柔和，暗部细节多' },
  { id: 'stucki',   name: 'Stucki',              hint: '比 Jarvis 锐一点，噪点少' },
  { id: 'burkes',   name: 'Burkes',              hint: 'Stucki 的两行简化版，最快' },
  { id: 'sierra',   name: 'Sierra',              hint: '介于 Floyd 和 Jarvis 之间' },
  { id: 'bayer4',   name: 'Bayer 4×4（有序）',   hint: '规则网点，复古报纸感' },
  { id: 'bayer8',   name: 'Bayer 8×8（有序）',   hint: '网点更细，渐变更平滑' },
];

/**
 * 误差扩散核：[dx, dy, 权重]，误差除以 div 后按权重摊给邻居。
 *
 * Atkinson 的 div 是 8 但权重只加到 6 —— 故意丢掉 1/4 误差，这是它对比度高、
 * 不容易糊成一片灰的原因，不是写错了。
 */
const KERNELS = {
  floyd:    { div: 16, taps: [[1,0,7],[-1,1,3],[0,1,5],[1,1,1]] },
  atkinson: { div: 8,  taps: [[1,0,1],[2,0,1],[-1,1,1],[0,1,1],[1,1,1],[0,2,1]] },
  jarvis:   { div: 48, taps: [[1,0,7],[2,0,5],[-2,1,3],[-1,1,5],[0,1,7],[1,1,5],[2,1,3],
                              [-2,2,1],[-1,2,3],[0,2,5],[1,2,3],[2,2,1]] },
  stucki:   { div: 42, taps: [[1,0,8],[2,0,4],[-2,1,2],[-1,1,4],[0,1,8],[1,1,4],[2,1,2],
                              [-2,2,1],[-1,2,2],[0,2,4],[1,2,2],[2,2,1]] },
  burkes:   { div: 32, taps: [[1,0,8],[2,0,4],[-2,1,2],[-1,1,4],[0,1,8],[1,1,4],[2,1,2]] },
  sierra:   { div: 32, taps: [[1,0,5],[2,0,3],[-2,1,2],[-1,1,4],[0,1,5],[1,1,4],[2,1,2],
                              [-1,2,2],[0,2,3],[1,2,2]] },
};

const BAYER4 = [[0,8,2,10],[12,4,14,6],[3,11,1,9],[15,7,13,5]];
const BAYER8 = [
  [ 0,32, 8,40, 2,34,10,42], [48,16,56,24,50,18,58,26],
  [12,44, 4,36,14,46, 6,38], [60,28,52,20,62,30,54,22],
  [ 3,35,11,43, 1,33, 9,41], [51,19,59,27,49,17,57,25],
  [15,47, 7,39,13,45, 5,37], [63,31,55,23,61,29,53,21],
];


/**
 * 任意图源 → 光栅 + 二值预览画布。
 *
 * 预览画布画的就是最终点阵本身，所见即所得 —— 放大时记得关掉插值
 * （CSS image-rendering: pixelated），否则点阵被糊成灰，预览就骗人了。
 *
 * @param {CanvasImageSource & {width:number,height:number}} source
 * @param {{threshold?:number, dither?:string, invert?:boolean,
 *          contrast?:number, sharpen?:number}} opts
 *        dither 取 DITHER_ALGOS 里的 id，默认 'none'
 *        contrast −100…100，sharpen 0…100，都是 0 表示不动
 * @returns {{data:Uint8Array, widthBytes:number, height:number, preview:HTMLCanvasElement}}
 */
export function rasterize(source, {
  threshold = 128, dither = 'none', invert = false, contrast = 0, sharpen = 0,
} = {}) {
  const sw = source.width  || source.naturalWidth;
  const sh = source.height || source.naturalHeight;
  if (!sw || !sh) throw new Error('图源尺寸为 0');

  const w = WIDTH_DOTS;
  const h = Math.max(1, Math.round(sh * WIDTH_DOTS / sw));   // 等比缩到 384 宽

  const cv = document.createElement('canvas');
  cv.width = w; cv.height = h;
  const ctx = cv.getContext('2d', { willReadFrequently: true });

  // 透明区域按白色处理（对应 Python 的 alpha_composite 白底）
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, w, h);
  ctx.drawImage(source, 0, 0, w, h);

  const img  = ctx.getImageData(0, 0, w, h);
  const px   = img.data;
  const gray = new Float32Array(w * h);

  // 与 PIL convert("L") 同系数（ITU-R 601-2）
  for (let i = 0, p = 0; p < gray.length; i += 4, p++) {
    gray[p] = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
  }

  // 顺序有讲究：先拉对比度定基调，锐化放最后 —— 反过来会把锐化出来的
  // 光晕再放大一遍，边缘一圈脏点，抖动之后尤其明显
  if (contrast) applyContrast(gray, contrast);
  if (sharpen) applySharpen(gray, w, h, sharpen);

  // 抖动算法就地把灰度压成 0/255，之后统一按 128 切；
  // 不抖动时保留原灰度，直接用阈值切。两条路的 cut 因此不同。
  let cut = threshold;
  if (KERNELS[dither]) {
    errorDiffuse(gray, w, h, KERNELS[dither], threshold);
    cut = 128;
  } else if (dither === 'bayer4' || dither === 'bayer8') {
    orderedDither(gray, w, h, dither === 'bayer4' ? BAYER4 : BAYER8, threshold);
    cut = 128;
  }

  const data = new Uint8Array(WIDTH_BYTES * h);
  for (let y = 0; y < h; y++) {
    const rowOff = y * WIDTH_BYTES;
    const gOff   = y * w;
    for (let x = 0; x < w; x++) {
      let black = gray[gOff + x] < cut;          // 暗 → 黑
      if (invert) black = !black;
      const i4 = (gOff + x) * 4;
      if (black) {
        data[rowOff + (x >> 3)] |= 0x80 >> (x & 7);
        px[i4] = px[i4 + 1] = px[i4 + 2] = 0;
      } else {
        px[i4] = px[i4 + 1] = px[i4 + 2] = 255;
      }
      px[i4 + 3] = 255;
    }
  }

  ctx.putImageData(img, 0, 0);                   // 预览 = 真实点阵
  return { data, widthBytes: WIDTH_BYTES, height: h, preview: cv };
}

/**
 * 对比度。围绕中灰 128 做线性拉伸，用的是那个经典系数：
 *   f = 259(C+255) / 255(259−C)，C ∈ (−255, 255)
 * 滑块给的是 −100…100，映射到 C 上就够用了 —— 再往上灰阶基本全被压成黑白两端。
 *
 * 热敏机只有黑白两级，适当加对比往往比调阈值管用：阈值只是整体挪切割线，
 * 对比度是把亮的推更亮、暗的推更暗，明暗层次先分开，抖动才好看。
 */
function applyContrast(g, amount) {
  const c = Math.max(-255, Math.min(255, amount * 2.55));
  const f = (259 * (c + 255)) / (255 * (259 - c));
  for (let i = 0; i < g.length; i++) {
    const v = f * (g[i] - 128) + 128;
    g[i] = v < 0 ? 0 : v > 255 ? 255 : v;
  }
}

/**
 * 锐化：USM（钝化蒙版）。先高斯模糊一份，再把「原图 − 模糊」的差按比例加回去。
 *   out = v + k·(v − blur)
 *
 * 对热敏打印特别值钱 —— 384 点宽意味着大图要缩很多倍，缩放天然发虚，
 * 直接二值化就糊成一团。先把边缘提起来再抖动，线稿和文字截然不同。
 */
function applySharpen(g, w, h, amount) {
  const k = amount / 50;                       // 100 → 2 倍，已经相当猛
  const blur = new Float32Array(g.length);
  // 3×3 高斯 [1 2 1; 2 4 2; 1 2 1] / 16，边缘按最近像素夹取
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let s = 0;
      for (let dy = -1; dy <= 1; dy++) {
        const yy = Math.min(h - 1, Math.max(0, y + dy));
        for (let dx = -1; dx <= 1; dx++) {
          const xx = Math.min(w - 1, Math.max(0, x + dx));
          s += g[yy * w + xx] * ((dx === 0 ? 2 : 1) * (dy === 0 ? 2 : 1));
        }
      }
      blur[y * w + x] = s / 16;
    }
  }
  for (let i = 0; i < g.length; i++) {
    const v = g[i] + k * (g[i] - blur[i]);
    g[i] = v < 0 ? 0 : v > 255 ? 255 : v;
  }
}

/** 通用误差扩散，就地把灰度压成 0/255 */
function errorDiffuse(g, w, h, { div, taps }, cut) {
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      const old = g[i];
      const nv = old < cut ? 0 : 255;
      g[i] = nv;
      const e = (old - nv) / div;
      if (e === 0) continue;
      for (let t = 0; t < taps.length; t++) {
        const dx = taps[t][0], dy = taps[t][1];
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= w || ny >= h) continue;      // 只往右/往下扩散，不用判 ny<0
        g[ny * w + nx] += e * taps[t][2];
      }
    }
  }
}

/**
 * 有序抖动（Bayer）。阈值矩阵以 cut 为中心铺开，
 * 所以阈值滑块在这里表现为整体明暗，和误差扩散那条路语义一致。
 */
function orderedDither(g, w, h, matrix, cut) {
  const n = matrix.length;
  const denom = n * n;
  for (let y = 0; y < h; y++) {
    const row = matrix[y % n];
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      const t = cut + ((row[x % n] + 0.5) / denom - 0.5) * 255;
      g[i] = g[i] < t ? 0 : 255;
    }
  }
}

/**
 * 文字 → 384 宽的画布（自动换行），对应 Python 的 text_to_image()。
 * 返回画布，再交给 rasterize() 二值化。文字建议阈值 212。
 */
/** 字间距要靠 ctx.letterSpacing，老一点的 WebKit（iOS Bluefy）没有 */
export const supportsLetterSpacing = () =>
  'letterSpacing' in document.createElement('canvas').getContext('2d');

export function renderText(text, {
  fontSize = 24,
  fontFamily = '"PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif',
  bold = false,
  weight = 400,
  italic = false,
  underline = false,
  letterSpacing = 0,
  align = 'left',
  margin = 8,
  lineSpacing = 6,
} = {}) {
  // bold 是 weight 的快捷写法，两个都给时取粗的那个
  const w400 = bold ? Math.max(700, weight) : weight;
  const font = `${italic ? 'italic ' : ''}${w400} ${fontSize}px ${fontFamily}`;
  const usable = WIDTH_DOTS - margin * 2;

  // 先用一张 1×1 画布量文字宽度（对应 Python 的 probe.textlength）
  const probe = document.createElement('canvas').getContext('2d');
  // 字间距要在量之前设上 —— measureText 会把它算进去，折行才不会算少
  probe.letterSpacing = `${letterSpacing}px`;
  probe.font = font;

  const lines = [];
  for (const para of String(text).split('\n')) {
    if (!para) { lines.push(''); continue; }
    let cur = '';
    for (const ch of para) {                       // 逐字符累加，中英文都能断
      if (probe.measureText(cur + ch).width <= usable) {
        cur += ch;
      } else {
        lines.push(cur);
        cur = ch;
      }
    }
    lines.push(cur);
  }

  const lh = fontSize + lineSpacing;
  const cv = document.createElement('canvas');
  cv.width  = WIDTH_DOTS;
  cv.height = Math.max(1, margin * 2 + lh * lines.length);

  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, cv.width, cv.height);
  ctx.letterSpacing = `${letterSpacing}px`;
  ctx.font = font;
  ctx.fillStyle = '#000';
  ctx.textBaseline = 'top';
  ctx.textAlign = align;

  /**
   * ctx.letterSpacing 在最后一个字后面也留一格（CSS letter-spacing 就是这么定义的）。
   * 那一格算在 measureText 的宽度里，右对齐/居中时会把整行往左推一格，
   * 看着就是没对齐 —— 定位时补回来，量下划线时再扣掉。
   */
  const trail = letterSpacing;
  const x = align === 'center' ? WIDTH_DOTS / 2 + trail / 2
          : align === 'right'  ? WIDTH_DOTS - margin + trail
          : margin;

  // 下划线粗细跟着字号走，不然大字配一根发丝线很怪
  const uw = Math.max(1, Math.round(fontSize / 16));
  lines.forEach((ln, i) => {
    const top = margin + i * lh;
    ctx.fillText(ln, x, top);
    if (underline && ln) {
      const tw = Math.max(0, ctx.measureText(ln).width - trail);   // 只画到最后一个字
      const x0 = align === 'center' ? WIDTH_DOTS / 2 - tw / 2
               : align === 'right'  ? WIDTH_DOTS - margin - tw
               : margin;
      ctx.fillRect(x0, top + fontSize * 0.92, tw, uw);
    }
  });

  return cv;
}

/** File / Blob → ImageBitmap（解码期直接给最终宽度，避免几十 MB 的全尺寸解码） */
export async function loadImage(file) {
  if (typeof createImageBitmap === 'function') {
    try { return await createImageBitmap(file); } catch { /* 回退 */ }
  }
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
}
