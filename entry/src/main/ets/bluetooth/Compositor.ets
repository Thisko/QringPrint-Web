import { GrayImage } from './Dither';

/**
 * 画布合成工具 —— 纯数组运算,不依赖 ImageKit,可以在任何线程调用。
 *
 * ⚠ 两套极性,别搞混:
 *   GrayImage.data  0 = 黑,255 = 白(光度值)
 *   binary          1 = 黑(打这个点),0 = 白
 * 翻转发生在 ditherToBinary 里。所以二值画布的「空白」是填 0,不是 0xFF。
 *
 * 项目里原先没有任何缩放/裁剪/拼接能力,这些都是为自定义画布新写的。
 */

/** 灰度空白值(白)。缩放时越界取样回落到它,不会凭空多出黑边 */
const GRAY_WHITE: number = 255;

/**
 * 最近邻缩放。
 *
 * 条码专用:一维码的信息全在黑白条的**边界位置**上,
 * 任何插值都会在交界处糊出灰边,二值化后条宽就变了,直接扫不出来。
 * 宁可锯齿也不能糊。
 */
export function scaleGrayNearest(src: GrayImage, targetW: number, targetH: number): GrayImage {
  const w: number = Math.max(1, Math.round(targetW));
  const h: number = Math.max(1, Math.round(targetH));
  if (w === src.width && h === src.height) {
    return src;
  }
  const out: Uint8Array = new Uint8Array(w * h);

  for (let y = 0; y < h; y++) {
    const srcY: number = Math.min(src.height - 1, Math.floor(y * src.height / h));
    const srcRow: number = srcY * src.width;
    const dstRow: number = y * w;
    for (let x = 0; x < w; x++) {
      const srcX: number = Math.min(src.width - 1, Math.floor(x * src.width / w));
      out[dstRow + x] = src.data[srcRow + srcX];
    }
  }
  return { data: out, width: w, height: h };
}

/**
 * 面积平均缩放(box filter)。
 *
 * 图片专用:缩小时把落在同一个目标像素里的源像素取平均,保住灰阶层次,
 * 之后再跑 Floyd 扩散才有东西可抖。用最近邻的话细节直接丢光,抖出来是一片噪点。
 *
 * 放大时退化成最近邻取样(没有新信息可造),这里不做双线性 ——
 * 热敏打印最终只有黑白两色,放大后的平滑过渡在二值化时会被吃掉,不值得那个开销。
 */
export function scaleGrayArea(src: GrayImage, targetW: number, targetH: number): GrayImage {
  const w: number = Math.max(1, Math.round(targetW));
  const h: number = Math.max(1, Math.round(targetH));
  if (w === src.width && h === src.height) {
    return src;
  }
  // 放大方向没有可平均的源像素,直接走最近邻
  if (w >= src.width && h >= src.height) {
    return scaleGrayNearest(src, w, h);
  }

  const out: Uint8Array = new Uint8Array(w * h);
  const xRatio: number = src.width / w;
  const yRatio: number = src.height / h;

  for (let y = 0; y < h; y++) {
    const y0: number = Math.floor(y * yRatio);
    // 至少覆盖一行,否则某些比例下 y0 === y1 会导致除零
    const y1: number = Math.max(y0 + 1, Math.min(src.height, Math.ceil((y + 1) * yRatio)));
    const dstRow: number = y * w;

    for (let x = 0; x < w; x++) {
      const x0: number = Math.floor(x * xRatio);
      const x1: number = Math.max(x0 + 1, Math.min(src.width, Math.ceil((x + 1) * xRatio)));

      let sum: number = 0;
      let count: number = 0;
      for (let sy = y0; sy < y1; sy++) {
        const srcRow: number = sy * src.width;
        for (let sx = x0; sx < x1; sx++) {
          sum += src.data[srcRow + sx];
          count++;
        }
      }
      out[dstRow + x] = count > 0 ? Math.round(sum / count) : GRAY_WHITE;
    }
  }
  return { data: out, width: w, height: h };
}

/**
 * 纵向抽行压缩。一维码生成出来是 384 的方图,打之前压扁省纸。
 *
 * 同一根竖条内每行完全相同,按最近邻抽行是无损的;
 * 取平均反而会在黑白交界处糊出灰边。
 */
export function squeezeRows(src: GrayImage, targetHeight: number): GrayImage {
  if (targetHeight >= src.height) {
    return src;
  }
  const out: Uint8Array = new Uint8Array(src.width * targetHeight);
  for (let y = 0; y < targetHeight; y++) {
    const srcY: number = Math.min(src.height - 1,
      Math.floor(y * src.height / targetHeight));
    const from: number = srcY * src.width;
    out.set(src.data.subarray(from, from + src.width), y * src.width);
  }
  return { data: out, width: src.width, height: targetHeight };
}

/** 新建一张全白的二值画布(二值里 0 就是白,所以零值即可) */
export function createBinaryCanvas(width: number, height: number): Uint8Array {
  return new Uint8Array(Math.max(1, width) * Math.max(1, height));
}

/**
 * 把 src 叠到 dst 的 (originX, originY) 处,超出部分自动裁掉。
 *
 * 用**或**合并而不是覆盖:元素重叠时黑点应该保留,
 * 覆盖的话后画的元素会用自己的白底把下面的内容擦掉,而热敏打印里「白」等于不打,
 * 擦出来的是一块空洞,不是想要的效果。
 */
export function blitBinary(
  dst: Uint8Array, dstW: number, dstH: number,
  src: Uint8Array, srcW: number, srcH: number,
  originX: number, originY: number): void {

  const ox: number = Math.round(originX);
  const oy: number = Math.round(originY);

  // 先把要拷的范围夹到画布内,循环里就不用每个点判越界
  const startX: number = Math.max(0, -ox);
  const startY: number = Math.max(0, -oy);
  const endX: number = Math.min(srcW, dstW - ox);
  const endY: number = Math.min(srcH, dstH - oy);

  for (let y = startY; y < endY; y++) {
    const srcRow: number = y * srcW;
    const dstRow: number = (y + oy) * dstW;
    for (let x = startX; x < endX; x++) {
      if (src[srcRow + x] === 1) {
        dst[dstRow + x + ox] = 1;
      }
    }
  }
}
