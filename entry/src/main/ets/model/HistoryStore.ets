import { preferences } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { GrayImage } from '../bluetooth/Dither';
import { scaleGrayNearest } from '../bluetooth/Compositor';

/**
 * 打印历史。
 *
 * 复用模板的持久化模式:preferences 存 JSON 数组,读取/写入/删除同套路。
 * 每条记录 = 打印类型名称 + 缩略图 + 时间戳。
 * 打印成功时记录一次,最多保留 MAX_RECORDS 条(超出丢最旧的)。
 */

const STORE_NAME: string = 'qring_history';
const KEY_LIST: string = 'history_list';
/** 最多保留的打印记录数 */
export const MAX_RECORDS: number = 20;

export interface HistoryRecord {
  id: string;
  /** 打印类型名称,如「图片打印」「文字打印」「条码打印」「自定义打印」 */
  typeName: string;
  /** 缩略图文件路径 */
  thumbnailPath: string;
  /** 打印时间戳(ms) */
  printedAt: number;
  /** 打印内容快照(JSON 字符串),点记录重新打印时恢复 */
  payload: string;
}

/** 各打印类型的路由名,历史页跳转用 */
export const HIST_TYPE_TEXT: string = '文字打印';
export const HIST_TYPE_IMAGE: string = '图片打印';
export const HIST_TYPE_CODE: string = '条码打印';
export const HIST_TYPE_CUSTOM: string = '自定义打印';

async function readAll(ctx: common.UIAbilityContext): Promise<HistoryRecord[]> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: preferences.ValueType = await store.get(KEY_LIST, '[]');
    const parsed: HistoryRecord[] = JSON.parse(raw as string) as HistoryRecord[];
    const normalized: HistoryRecord[] = [];
    for (const r of parsed) {
      normalized.push({
        id: r.id,
        typeName: r.typeName,
        thumbnailPath: r.thumbnailPath !== undefined ? r.thumbnailPath : '',
        printedAt: r.printedAt !== undefined ? r.printedAt : 0,
        payload: r.payload !== undefined ? r.payload : '',
      });
    }
    return normalized;
  } catch (err) {
    return [];
  }
}

async function writeAll(ctx: common.UIAbilityContext, records: HistoryRecord[]): Promise<void> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    await store.put(KEY_LIST, JSON.stringify(records));
    await store.flush();
  } catch (err) {
    throw err as Error;
  }
}

/**
 * 把 GrayImage 编码成缩略图 PNG 写盘,返回文件 uri。
 * 缩略图失败返回空串(记录仍会保存,列表显示占位)。
 * 像素读取由调用方在 await 之前用 readPixelsSync 同步完成,这里只管编码写盘。
 */
async function encodeThumb(g: GrayImage, ctx: common.UIAbilityContext): Promise<string> {
  try {
    const maxW: number = 300;
    const ratio: number = Math.min(1, maxW / g.width);
    const tw: number = Math.max(1, Math.round(g.width * ratio));
    const th: number = Math.max(1, Math.round(g.height * ratio));
    const scaled: GrayImage = scaleGrayNearest(g, tw, th);
    const buffer: ArrayBuffer = new ArrayBuffer(scaled.width * scaled.height * 4);
    const view: Uint8Array = new Uint8Array(buffer);
    for (let i = 0; i < scaled.width * scaled.height; i++) {
      const v: number = scaled.data[i];
      const p: number = i * 4;
      view[p] = v;
      view[p + 1] = v;
      view[p + 2] = v;
      view[p + 3] = 255;
    }
    const pm: image.PixelMap = await image.createPixelMap(buffer, {
      size: { width: scaled.width, height: scaled.height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false,
    });
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      try {
        const encoded: ArrayBuffer = await packer.packToData(pm, { format: 'image/png', quality: 90 });
        const path: string = `${ctx.filesDir}/hist_${Date.now()}.png`;
        const file: fileIo.File = fileIo.openSync(path,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, encoded);
        fileIo.closeSync(file);
        return fileUri.getUriFromPath(path);
      } finally {
        packer.release();
      }
    } finally {
      pm.release();
    }
  } catch (err) {
    return '';
  }
}

/**
 * 添加一条打印记录(GrayImage 版)。图片/自定义打印用。
 */
export async function addHistoryGray(
  ctx: common.UIAbilityContext, typeName: string, g: GrayImage, payload: string): Promise<void> {
  const records: HistoryRecord[] = await readAll(ctx);
  const thumbPath: string = await encodeThumb(g, ctx);
  const rec: HistoryRecord = {
    id: `h${Date.now()}`,
    typeName: typeName,
    thumbnailPath: thumbPath,
    printedAt: Date.now(),
    payload: payload,
  };
  const next: HistoryRecord[] = [rec, ...records];
  const capped: HistoryRecord[] = next.slice(0, MAX_RECORDS);
  await writeAll(ctx, capped);
}

/**
 * 添加一条打印记录。
 * 新的排最前;超过 MAX_RECORDS 丢最旧的。
 * 传入打印结果 PixelMap,内部转缩略图保存。
 *
 * ⚠ 调用方(打印页)打印完 finally 会 release PixelMap。这里**必须先**同步把像素读出来,
 * 再做任何 await —— 否则 readAll 挂起期间 PixelMap 已被释放,saveThumb 读到的是空数据。
 * 所以 saveThumbSync 用 getImageInfoSync/readPixelsToBufferSync 立即拷贝,才交给异步写盘。
 */
export async function addHistory(
  ctx: common.UIAbilityContext, typeName: string, pm: image.PixelMap, payload: string): Promise<void> {
  // 同步读像素(必须在任何 await 之前,避免 release 竞态)
  const gray: GrayImage | null = readPixelsSync(pm);
  const records: HistoryRecord[] = await readAll(ctx);
  const thumbPath: string = gray !== null ? await encodeThumb(gray, ctx) : '';
  const rec: HistoryRecord = {
    id: `h${Date.now()}`,
    typeName: typeName,
    thumbnailPath: thumbPath,
    printedAt: Date.now(),
    payload: payload,
  };
  const next: HistoryRecord[] = [rec, ...records];
  // 截断到最多 MAX_RECORDS 条
  const capped: HistoryRecord[] = next.slice(0, MAX_RECORDS);
  await writeAll(ctx, capped);
}

/** 同步读 PixelMap 像素转灰度。返回 null 表示读取失败 */
function readPixelsSync(pm: image.PixelMap): GrayImage | null {
  try {
    const info: image.ImageInfo = pm.getImageInfoSync();
    const w: number = info.size.width;
    const h: number = info.size.height;
    if (w <= 0 || h <= 0) {
      return null;
    }
    const pixelBytes: number = pm.getPixelBytesNumber();
    const raw: ArrayBuffer = new ArrayBuffer(pixelBytes);
    pm.readPixelsToBufferSync(raw);
    const src: Uint8Array = new Uint8Array(raw);
    const bytesPerPixel: number = Math.max(1, Math.floor(pixelBytes / (w * h)));
    const grayData: Uint8Array = new Uint8Array(w * h);
    for (let i = 0; i < w * h; i++) {
      const p: number = i * bytesPerPixel;
      const r: number = src[p];
      const g: number = bytesPerPixel > 1 ? src[p + 1] : r;
      const b: number = bytesPerPixel > 2 ? src[p + 2] : r;
      grayData[i] = Math.round(0.299 * r + 0.587 * g + 0.114 * b);
    }
    return { data: grayData, width: w, height: h };
  } catch (err) {
    return null;
  }
}

export async function loadHistory(ctx: common.UIAbilityContext): Promise<HistoryRecord[]> {
  return await readAll(ctx);
}

export async function deleteHistory(ctx: common.UIAbilityContext, id: string): Promise<void> {
  const records: HistoryRecord[] = await readAll(ctx);
  const kept: HistoryRecord[] = [];
  for (const r of records) {
    if (r.id === id) {
      if (r.thumbnailPath.length > 0) {
        try {
          fileIo.unlinkSync(r.thumbnailPath);
        } catch (err) {
          // 文件可能已被清理,忽略
        }
      }
    } else {
      kept.push(r);
    }
  }
  await writeAll(ctx, kept);
}
