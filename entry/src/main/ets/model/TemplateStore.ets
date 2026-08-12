import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { CanvasDoc, CanvasElement, ElementKind } from './CanvasModel';
import { DEFAULT_TEXT_OPTIONS, TextRenderOptions } from '../bluetooth/RasterEncoder';
import { DitherMode } from '../bluetooth/Dither';
import { saveTemplateThumbnail } from '../common/ElementRender';

/**
 * 模板持久化。
 *
 * 用 preferences 存一个 JSON 数组:key = 'template_list',值 = TemplateRecord[]。
 * 每个模板是 CanvasDoc 的快照 —— 元素序列化成扁平结构(ArkTS 严格模式下手动逐字段拷贝,
 * 不用对象展开),加载时重建 CanvasElement 再走渲染管线补回位图。
 *
 * 注意:元素里只有「数据」(几何/文字/图片uri/码内容),不含运行时状态
 * (preview 位图、sourceGray 缓存、rendering 标志) —— 那些不可序列化也不该存。
 */

const STORE_NAME: string = 'qring_templates';
const KEY_LIST: string = 'template_list';

/** 元素的序列化形态。字段全部扁平展开,避免嵌套对象在 JSON 往返时出岔 */
export interface TemplateElementData {
  kind: number;
  dotX: number;
  dotY: number;
  dotW: number;
  dotH: number;
  aspect: number;
  // 文字
  text: string;
  fontFamily: string;
  fontSize: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  letterSpacing: number;
  lineSpacing: number;
  pageMargin: number;
  // 图片
  imageUri: string;
  ditherMode: number;
  // 条码
  codeContent: string;
  codeTypeIndex: number;
}

export interface TemplateRecord {
  id: string;
  name: string;
  minLength: number;
  elements: TemplateElementData[];
  /** 保存/修改时间戳(ms)。列表显示日期用 */
  updatedAt: number;
  /** 缩略图 PNG 文件路径。旧记录可能没有,列表里显示占位 */
  thumbnailPath: string;
}

function textOptionsFrom(d: TemplateElementData): TextRenderOptions {
  return {
    fontFamily: d.fontFamily.length > 0 ? d.fontFamily : DEFAULT_TEXT_OPTIONS.fontFamily,
    fontSize: d.fontSize > 0 ? d.fontSize : DEFAULT_TEXT_OPTIONS.fontSize,
    bold: d.bold,
    italic: d.italic,
    underline: d.underline,
    letterSpacing: d.letterSpacing,
    lineSpacing: d.lineSpacing,
    margin: d.pageMargin,
  };
}

/** CanvasDoc → 可序列化的元素数组 */
export function docToTemplateData(doc: CanvasDoc): TemplateElementData[] {
  const list: TemplateElementData[] = [];
  for (const el of doc.elements) {
    const d: TemplateElementData = {
      kind: el.kind,
      dotX: el.dotX,
      dotY: el.dotY,
      dotW: el.dotW,
      dotH: el.dotH,
      aspect: el.aspect,
      text: el.text,
      fontFamily: el.textOptions.fontFamily,
      fontSize: el.textOptions.fontSize,
      bold: el.textOptions.bold,
      italic: el.textOptions.italic,
      underline: el.textOptions.underline,
      letterSpacing: el.textOptions.letterSpacing,
      lineSpacing: el.textOptions.lineSpacing,
      pageMargin: el.textOptions.margin,
      imageUri: el.imageUri,
      ditherMode: el.ditherMode,
      codeContent: el.codeContent,
      codeTypeIndex: el.codeTypeIndex,
    };
    list.push(d);
  }
  return list;
}

/** 模板元素数据 → CanvasElement 数组(不含位图,需再渲染) */
export function templateToElements(rec: TemplateRecord): CanvasElement[] {
  const els: CanvasElement[] = [];
  for (const d of rec.elements) {
    const el: CanvasElement = new CanvasElement(d.kind as ElementKind);
    el.dotX = d.dotX;
    el.dotY = d.dotY;
    el.dotW = d.dotW;
    el.dotH = d.dotH;
    el.aspect = d.aspect;
    // 图片几何来自模板,renderElementNow 不能再按真实比例重设
    el.geometryLocked = true;

    if (el.kind === ElementKind.TEXT) {
      el.text = d.text;
      el.textOptions = textOptionsFrom(d);
    } else if (el.kind === ElementKind.IMAGE) {
      el.imageUri = d.imageUri;
      el.ditherMode = d.ditherMode as DitherMode;
    } else if (el.kind === ElementKind.CODE) {
      el.codeContent = d.codeContent;
      el.codeTypeIndex = d.codeTypeIndex;
    }
    els.push(el);
  }
  return els;
}

async function readAll(ctx: common.UIAbilityContext): Promise<TemplateRecord[]> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: preferences.ValueType = await store.get(KEY_LIST, '[]');
    const parsed: TemplateRecord[] = JSON.parse(raw as string) as TemplateRecord[];
    // 旧记录可能缺 updatedAt / thumbnailPath,补默认值避免 undefined 穿透到 UI
    const normalized: TemplateRecord[] = [];
    for (const r of parsed) {
      normalized.push({
        id: r.id,
        name: r.name,
        minLength: r.minLength,
        elements: r.elements,
        updatedAt: r.updatedAt !== undefined ? r.updatedAt : 0,
        thumbnailPath: r.thumbnailPath !== undefined ? r.thumbnailPath : '',
      });
    }
    return normalized;
  } catch (err) {
    return [];
  }
}

async function writeAll(ctx: common.UIAbilityContext, records: TemplateRecord[]): Promise<void> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    await store.put(KEY_LIST, JSON.stringify(records));
    await store.flush();
  } catch (err) {
    // 显式处理让 linter 闭嘴,并把错误传给调用方的 .catch
    throw err as Error;
  }
}

/** 保存模板。id 为空则新建,否则覆盖同名 id(编辑已有模板后保存 = 更新) */
export async function saveTemplate(
  ctx: common.UIAbilityContext, name: string, doc: CanvasDoc, id?: string): Promise<TemplateRecord> {
  const records: TemplateRecord[] = await readAll(ctx);
  // 生成缩略图。失败不阻断保存(缩略图只是列表装饰,列表会显示占位)。
  // saveTemplateThumbnail 返回沙箱相对路径,Image 组件不认识,要转成 file:// uri 才能显示
  let thumb: string = '';
  try {
    const path: string = await saveTemplateThumbnail(doc, ctx);
    thumb = path.length > 0 ? fileUri.getUriFromPath(path) : '';
  } catch (err) {
    thumb = '';
  }
  const rec: TemplateRecord = {
    id: id !== undefined && id.length > 0 ? id : `t${Date.now()}`,
    name: name,
    minLength: doc.minLength,
    elements: docToTemplateData(doc),
    updatedAt: Date.now(),
    thumbnailPath: thumb,
  };
  const filtered: TemplateRecord[] = records.filter((r: TemplateRecord) => r.id !== rec.id);
  // 最新的排最前(后保存的显示在前面)。编辑已有模板 = 覆盖原位置
  filtered.unshift(rec);
  await writeAll(ctx, filtered);
  return rec;
}

export async function loadTemplates(ctx: common.UIAbilityContext): Promise<TemplateRecord[]> {
  const records: TemplateRecord[] = await readAll(ctx);
  // 按更新时间倒序:后保存/后修改的排最前。
  // save 已 unshift 新建的,但 rename 只改名字不挪位,统一按 updatedAt 排最稳
  return records.sort((a: TemplateRecord, b: TemplateRecord) => b.updatedAt - a.updatedAt);
}

export async function findTemplate(
  ctx: common.UIAbilityContext, id: string): Promise<TemplateRecord | undefined> {
  const records: TemplateRecord[] = await readAll(ctx);
  for (const r of records) {
    if (r.id === id) {
      return r;
    }
  }
  return undefined;
}

export async function deleteTemplate(ctx: common.UIAbilityContext, id: string): Promise<void> {
  const records: TemplateRecord[] = await readAll(ctx);
  const kept: TemplateRecord[] = [];
  for (const r of records) {
    if (r.id === id) {
      // 顺带删掉缩略图文件,避免堆积
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

export async function renameTemplate(
  ctx: common.UIAbilityContext, id: string, newName: string): Promise<void> {
  const records: TemplateRecord[] = await readAll(ctx);
  // ArkTS 禁对象展开,逐个重建改名那一条。改名也是「修改」,更新时间戳
  const updated: TemplateRecord[] = [];
  for (const r of records) {
    if (r.id === id) {
      updated.push({
        id: r.id,
        name: newName,
        minLength: r.minLength,
        elements: r.elements,
        updatedAt: Date.now(),
        thumbnailPath: r.thumbnailPath,
      });
    } else {
      updated.push(r);
    }
  }
  await writeAll(ctx, updated);
}
