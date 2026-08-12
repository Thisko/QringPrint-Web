import { image } from '@kit.ImageKit';
import { generateBarcode } from '@kit.ScanKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DitherMode, ditherToBinary, GrayImage } from '../bluetooth/Dither';
import {
  blitBinary,
  createBinaryCanvas,
  scaleGrayArea,
  scaleGrayNearest,
  squeezeRows,
} from '../bluetooth/Compositor';
import {
  binaryToPreviewPixelMap,
  decodeImageToPrintWidth,
  measureTextContentWidth,
  pixelMapToGray,
  pixelMapToGrayRaw,
  renderTextToPixelMapIn,
  THRESHOLD_IMAGE,
  THRESHOLD_TEXT,
} from '../bluetooth/RasterEncoder';
import { WIDTH_DOTS } from '../bluetooth/QringProtocol';
import { CanvasDoc, CanvasElement, centeredX, ElementKind } from '../model/CanvasModel';
import { CodeCategory, CodeType } from '../model/BarcodeModel';

const DOMAIN: number = 0x0001;
const TAG: string = 'ElementRender';

/**
 * 画布元素渲染。
 *
 * 核心原则:**每个元素按自己最合适的方式各自二值化,最后才合成**,
 * 而不是先拼成一张灰度图再统一二值化。
 * 三类内容的最优二值化方式完全不同 ——
 *   图片 → Floyd 误差扩散(要灰阶层次)
 *   文字 → 阈值 212(笔画细,阈值低了会被吃掉)
 *   条码 → 阈值 128 且**绝不能抖动**(抖动会把黑条边缘打散,直接扫不出来)
 * 先拍平再统一处理会同时毁��其中两类。
 */

/**
 * 条码生成尺寸,宽高都必须是 384。
 * createBarcode 对 height 有运行时校验,传 140 会抛
 * `401 parameter verification of height failed`;384 是实测能过的值。
 */
const CODE_GEN_SIZE: number = 384;
/** 一维码生成出来是方的,先压扁到这个高度当作它的「原始」形态 */
const ONE_D_NATURAL_HEIGHT: number = 140;

/** 元素默认插入尺寸(点) */
export const DEFAULT_IMAGE_WIDTH: number = 240;
export const DEFAULT_CODE_2D_SIZE: number = 160;
export const DEFAULT_CODE_1D_WIDTH: number = 280;

/** 一维码「自然」宽高比(w/h)。生成后压扁到 140 高,显示时按它推导,保持扁形 */
export function codeOneDAspect(): number {
  return CODE_GEN_SIZE / ONE_D_NATURAL_HEIGHT;
}

// ── 条码 ──────────────────────────────────────────────────

/**
 * 生成条码的原始灰度图。
 *
 * 与 CodePrintPage 共用同一套尺寸约定,保证画布里插的码和单独打的码长得一样。
 */
export async function renderCodeGray(content: string, type: CodeType): Promise<GrayImage> {
  let created: image.PixelMap | null = null;
  try {
    created = await generateBarcode.createBarcode(content, {
      scanType: type.scanType,
      width: CODE_GEN_SIZE,
      height: CODE_GEN_SIZE,
      margin: 2,
    });
    // 用 Raw 版:普通版遇到宽度≠384 会原地改写传入的位图,这里虽然正好是 384,
    // 但语义上元素渲染一律不该有副作用,统一走 Raw
    const gray: GrayImage = await pixelMapToGrayRaw(created);
    return type.category === CodeCategory.ONE_D
      ? squeezeRows(gray, ONE_D_NATURAL_HEIGHT) : gray;
  } catch (err) {
    // 故意继续往上抛:错误要显示给用户(内容不合法、校验位不对等都从这里出来)。
    // 这里只补一条日志,顺便记下是哪个码制挂的
    hilog.error(DOMAIN, TAG, 'createBarcode failed [%{public}s]: %{public}s',
      type.label, JSON.stringify(err));
    throw err as Error;
  } finally {
    if (created !== null) {
      created.release();
    }
  }
}

// ── 图片 ──────────────────────────────────────────────────

/**
 * 解码图片成 384 宽的灰度缓存。
 *
 * 解码期直接缩放到 384,比解全尺寸再缩省得多 —— 手机照片动辄 4000px 宽。
 * 这份缓存之后被缩放和换抖动算法反复复用,不必重新解码。
 */
export async function loadImageGray(uri: string): Promise<GrayImage> {
  let decoded: image.PixelMap | null = null;
  try {
    decoded = await decodeImageToPrintWidth(uri);
    // decodeImageToPrintWidth 出来就是 384 宽,普通版不会触发缩放分支,可以安全使用
    return await pixelMapToGray(decoded);
  } finally {
    if (decoded !== null) {
      decoded.release();
    }
  }
}

// ── 单个元素 → 二值位图 ────────────────────────────────────

/**
 * 按元素当前的尺寸渲染出二值位图,并同步更新它的屏幕预览图。
 *
 * 缩放和二值化的**顺序**很关键:必须先缩放灰度、再在目标尺寸上二值化。
 * 反过来先二值化再缩放的话,抖动出来的点阵会被重采样搅烂,
 * 打印效果和预览都会变成一团噪点。
 */
export async function renderElement(
  el: CanvasElement, onStage?: (s: string) => void): Promise<void> {
  const targetW: number = Math.max(1, Math.round(el.dotW));
  const targetH: number = Math.max(1, Math.round(el.dotH));
  let binary: Uint8Array | null = null;

  if (el.kind === ElementKind.TEXT) {
    // 文字不做位图缩放 —— 缩放会糊掉笔画。直接按目标宽度重新排版,
    // 高度由排版结果决定(所以文字元素没有缩放手柄)
    let rendered: image.PixelMap | null = null;
    try {
      onStage?.('排版文字');
      // dotW <= 0 表示 auto:按内容自然宽度排版,不占满整幅宽。
      // 默认插入的文字元素就应该是贴合内容的宽度,而不是一张 384 宽的纸。
      let contentW: number = Math.max(1, Math.round(el.dotW));
      if (el.dotW <= 0) {
        contentW = measureTextContentWidth(el.text, el.textOptions, WIDTH_DOTS);
      }
      rendered = renderTextToPixelMapIn(el.text, el.textOptions, contentW);
      onStage?.('文字→灰度');
      const gray: GrayImage = await pixelMapToGrayRaw(rendered);
      binary = ditherToBinary(gray, DitherMode.NONE, THRESHOLD_TEXT);
      el.dotW = gray.width;
      el.dotH = gray.height;
      el.aspect = gray.height > 0 ? gray.width / gray.height : 1;
      // 文字元素白底透明:文字像直接印在纸上,不是一块白块
      await applyBinary(el, binary, gray.width, gray.height, onStage, true);
      return;
    } finally {
      if (rendered !== null) {
        rendered.release();
      }
    }
  }

  if (el.kind === ElementKind.IMAGE) {
    const source: GrayImage | null = el.sourceGray;
    if (source === null) {
      return;
    }
    onStage?.('图片缩放');
    // 面积平均缩到目标尺寸,再在目标尺寸上跑抖动 —— 这样点阵密度才是对的
    const scaled: GrayImage = scaleGrayArea(source, targetW, targetH);
    onStage?.('图片抖动');
    binary = ditherToBinary(scaled, el.ditherMode, THRESHOLD_IMAGE);
    await applyBinary(el, binary, scaled.width, scaled.height, onStage);
    return;
  }

  onStage?.('生成条码');
  // 条码:最近邻缩放保住条边,固定纯阈值不抖动
  const codeGray: GrayImage = await renderCodeGray(el.codeContent, el.codeType());
  onStage?.('条码缩放');
  const scaledCode: GrayImage = scaleGrayNearest(codeGray, targetW, targetH);
  binary = ditherToBinary(scaledCode, DitherMode.NONE, THRESHOLD_IMAGE);
  await applyBinary(el, binary, scaledCode.width, scaledCode.height, onStage);
}

async function applyBinary(
  el: CanvasElement, binary: Uint8Array, width: number, height: number,
  onStage?: (s: string) => void, transparentWhite?: boolean): Promise<void> {
  onStage?.('生成预览图');
  el.binary = binary;
  const next: image.PixelMap =
    await binaryToPreviewPixelMap(binary, width, height, transparentWhite);
  el.setPreview(next);
}

/**
 * 单元素完整渲染入口(模块级,不依赖组件 this)。
 *
 * 之前把这段逻辑放在 @ComponentV2 的 private async 方法里,在真机上
 * `await this.xxx()` 的调用链会卡死、后续代码不执行(界面一直停在调用前)。
 * 抽成模块级函数后,组件只需用 .then/.catch 链调用,彻底绕开 this+async 的组合问题。
 *
 * 首次渲染图片时按真实宽高比设尺寸:
 * 解码(loadImageGray)得到 384 宽灰度的真实 aspect,再按它设 dotH,
 * 图片框就不是插入时的正方形占位,而是贴合照片本身的形状。
 * 换图(sourceGray 被清 null)时同样走这步,重新贴合新图比例。
 */
export async function renderElementNow(
  el: CanvasElement, onStage?: (s: string) => void): Promise<void> {
  el.rendering = true;
  onStage?.('开始渲染');
  try {
    if (el.kind === ElementKind.IMAGE && el.sourceGray === null && el.imageUri.length > 0) {
      onStage?.('解码图片');
      const gray: GrayImage = await loadImageGray(el.imageUri);
      el.sourceGray = gray;
      // 图片原始宽高比,贴合实际比例显示,不再是正方形占位。
      // 仅新插入(geometryLocked=false)时重设;从模板加载的几何来自保存数据,
      // 不能在这里被覆盖。
      if (!el.geometryLocked) {
        el.aspect = gray.height > 0 ? gray.width / gray.height : 1;
        el.dotW = DEFAULT_IMAGE_WIDTH;
        el.dotH = Math.max(1, Math.round(DEFAULT_IMAGE_WIDTH / el.aspect));
        el.dotX = centeredX(el.dotW);
        el.geometryLocked = true;
      }
    }
    await renderElement(el, onStage);
    onStage?.('渲染完成');
  } finally {
    el.rendering = false;
  }
}

// ── 整幅合成 ──────────────────────────────────────────────

export interface CanvasComposite {
  binary: Uint8Array;
  width: number;
  height: number;
}

/**
 * 把所有元素合成成一张 384 × H 的二值图。
 *
 * 预览和打印都吃这一份数据,所以「所见即所打」是真的逐点一致,不是近似。
 */
export function composeCanvas(doc: CanvasDoc): CanvasComposite {
  // 用内容高度而不是视口高度:打印只出到最靠下元素底边,不铺空白
  const height: number = doc.contentHeight();
  const canvas: Uint8Array = createBinaryCanvas(WIDTH_DOTS, height);

  for (const el of doc.elements) {
    const bits: Uint8Array | null = el.binary;
    if (bits === null) {
      continue;
    }
    const w: number = Math.max(1, Math.round(el.dotW));
    const h: number = Math.max(1, Math.round(el.dotH));
    // 元素的实际位图尺寸可能和 dotW/dotH 差个舍入,以位图为准免得错行
    const rows: number = Math.min(h, Math.floor(bits.length / w));
    blitBinary(canvas, WIDTH_DOTS, height, bits, w, rows, el.dotX, el.dotY);
  }

  hilog.info(DOMAIN, TAG, 'composed %{public}d elements, height %{public}d',
    doc.elements.length, height);
  return { binary: canvas, width: WIDTH_DOTS, height: height };
}

export async function compositeToPixelMap(composite: CanvasComposite): Promise<image.PixelMap> {
  return await binaryToPreviewPixelMap(composite.binary, composite.width, composite.height);
}

/**
 * 生成模板缩略图 PNG 文件,返回文件路径。
 *
 * 把画布合成成二值图 → 等比缩小到缩略图尺寸 → 编码 PNG → 写进应用文件目录。
 * 缩略图在保存模板时生成一次,模板列表直接用 Image(路径)显示,不用每次渲染。
 * 等比缩放用最近邻(缩略图小、二值内容保真,不用面积平均)。
 */
/**
 * 把画布合成成缩略图,返回 PNG 字节。
 *
 * 历史打印记录用:打出来的内容存成缩略图字节,由调用方决定落盘文件名。
 * 与 saveTemplateThumbnail 共用缩放/编码逻辑,只是返回字节而不是写文件。
 */
export async function thumbnailBytes(doc: CanvasDoc): Promise<ArrayBuffer | null> {
  const composite: CanvasComposite = composeCanvas(doc);
  const maxW: number = 300;
  const maxH: number = 300;
  const ratio: number = Math.min(maxW / composite.width, maxH / composite.height, 1);
  const tw: number = Math.max(1, Math.round(composite.width * ratio));
  const th: number = Math.max(1, Math.round(composite.height * ratio));
  const gray: GrayImage = {
    data: composite.binary,
    width: composite.width,
    height: composite.height,
  };
  const scaled: GrayImage = scaleGrayNearest(gray, tw, th);
  const pm: image.PixelMap = await binaryToPreviewPixelMap(scaled.data, scaled.width, scaled.height);
  try {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      try {
        return await packer.packToData(pm, { format: 'image/png', quality: 90 });
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'thumbnailBytes pack failed: %{public}s', JSON.stringify(err));
        throw err as Error;
      }
    } finally {
      packer.release();
    }
  } finally {
    pm.release();
  }
}

export async function saveTemplateThumbnail(
  doc: CanvasDoc, ctx: common.UIAbilityContext): Promise<string> {
  const composite: CanvasComposite = composeCanvas(doc);
  // 模板页是两列网格,每张卡片缩略图约半屏宽。用 300px 宽作上限,
  // 3 倍屏上半屏(≈180vp)显示时足够清晰,又不至于太大浪费内存。
  const maxW: number = 300;
  const maxH: number = 300;
  const ratio: number = Math.min(maxW / composite.width, maxH / composite.height, 1);
  const tw: number = Math.max(1, Math.round(composite.width * ratio));
  const th: number = Math.max(1, Math.round(composite.height * ratio));
  const gray: GrayImage = {
    data: composite.binary,
    width: composite.width,
    height: composite.height,
  };
  const scaled: GrayImage = scaleGrayNearest(gray, tw, th);
  const pm: image.PixelMap = await binaryToPreviewPixelMap(scaled.data, scaled.width, scaled.height);

  const path: string = `${ctx.filesDir}/tpl_${Date.now()}.png`;
  let file: fileIo.File | null = null;
  try {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      // packToData 是 packing 的替代(deprecated since 13)
      const encoded: ArrayBuffer = await packer.packToData(pm, { format: 'image/png', quality: 90 });
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, encoded);
    } catch (err) {
      // 缩略图失败不阻断保存 —— 列表会显示占位。这里记日志后重新抛出,
      // 由 saveTemplate 的 try 兜底。rethrow 也是 linter 认可的处理方式。
      hilog.error(DOMAIN, TAG, 'thumbnail pack/write failed: %{public}s', JSON.stringify(err));
      throw err as Error;
    } finally {
      packer.release();
    }
    try {
      fileIo.closeSync(file);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'thumbnail close failed: %{public}s', JSON.stringify(err));
      throw err as Error;
    }
    file = null;
    return path;
  } finally {
    pm.release();
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        // 关闭失败不影响主流程
      }
    }
  }
}
