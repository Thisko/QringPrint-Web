import { image } from '@kit.ImageKit';
import { DitherMode, GrayImage } from '../bluetooth/Dither';
import { DEFAULT_TEXT_OPTIONS, TextRenderOptions } from '../bluetooth/RasterEncoder';
import { WIDTH_DOTS } from '../bluetooth/QringProtocol';
import { CODE_TYPES, CodeType } from './BarcodeModel';

/**
 * 自定义画布的文档模型。
 *
 * 坐标单位一律是**打印点**(1 点 = 1/8 mm),画布固定 384 点宽 —— 和打印头一致,
 * 屏幕上再按 显示宽度/384 缩放显示。所有几何量都存点数,
 * 这样合成时不用做任何单位换算,拖拽产生的 vp 位移在视图层除以缩放比即可。
 *
 * 用「单个类 + kind 判别」而不是继承:ArkTS 里 @ObservedV2/@Trace 配合类继承有不确定性,
 * 元素种类就三种、字段也不多,拍平反而更省事。
 */

export enum ElementKind {
  TEXT = 0,
  IMAGE = 1,
  CODE = 2,
}

/** 画布底部留白(点),避免内容贴着切纸口 */
export const CANVAS_BOTTOM_PAD: number = 16;
/** 画布最小长度的可调范围 */
export const MIN_LENGTH_FLOOR: number = 80;
export const MIN_LENGTH_CEIL: number = 1200;
/**
 * 画布高度硬上限。
 * 协议里高度是 16 位字段(65535)且**没有校验**,超了会静默回绕成一个小数字,
 * 打出来是一堆乱码。真正的瓶颈其实是 ACK 超时 120s,所以这里取一个远小于两者的保守值。
 */
export const MAX_CANVAS_HEIGHT: number = 4000;

/** 元素最小尺寸(点),再小就没法拖了 */
export const MIN_ELEMENT_SIZE: number = 24;

let nextId: number = 1;

/**
 * 画布元素。
 *
 * 几何量用 dotX/dotY/dotW/dotH 而不是 x/y/width/height —— 一是标明单位是打印点,
 * 二是避开 width/height 这类名字(万一以后要挪进组件里,会和 CustomComponent 的属性方法撞名)。
 */
@ObservedV2
export class CanvasElement {
  readonly id: string;
  readonly kind: ElementKind;

  @Trace dotX: number = 0;
  @Trace dotY: number = 0;
  @Trace dotW: number = 0;
  @Trace dotH: number = 0;

  /** 原始宽高比(w/h)。锁定比例缩放时按它推导高度 */
  @Trace aspect: number = 1;

  /**
   * 图片几何是否已锁定。
   * 新插入的图片首次解码后要按真实比例重设(见 renderElementNow);
   * 从模板加载的图片几何来自保存的数据,不能再被重设覆盖。
   */
  @Trace geometryLocked: boolean = false;

  /** 屏幕显示用的位图。**必须在删除元素和退页时 release**,这是多元素场景最大的泄漏点 */
  @Trace preview: image.PixelMap | undefined = undefined;

  /** 合成用的二值位图,1 = 黑,长度 dotW * dotH。null 表示还没渲染出来 */
  @Trace binary: Uint8Array | null = null;

  /** 渲染中标志,用于显示转圈 */
  @Trace rendering: boolean = false;

  // ── 文字元素 ──────────────────────────────────────────
  @Trace text: string = '';
  /** 整体替换而不是改内部字段 —— @Trace 只跟踪重新赋值,不跟踪对象内部的改动 */
  @Trace textOptions: TextRenderOptions = DEFAULT_TEXT_OPTIONS;

  // ── 图片元素 ──────────────────────────────────────────
  @Trace imageUri: string = '';
  @Trace ditherMode: DitherMode = DitherMode.FLOYD_STEINBERG;
  /**
   * 解码后的灰度缓存(384 宽)。
   * 缩放和换抖动算法都从它重算,不必重新解码 —— 手机照片解全尺寸要几十 MB。
   * 不加 @Trace:它不参与渲染判断,加了反而会触发多余的刷新。
   */
  sourceGray: GrayImage | null = null;

  // ── 条码元素 ──────────────────────────────────────────
  @Trace codeContent: string = '';
  @Trace codeTypeIndex: number = 0;

  constructor(kind: ElementKind) {
    this.kind = kind;
    this.id = `el_${nextId++}`;
  }

  codeType(): CodeType {
    if (this.codeTypeIndex >= 0 && this.codeTypeIndex < CODE_TYPES.length) {
      return CODE_TYPES[this.codeTypeIndex];
    }
    return CODE_TYPES[0];
  }

  /** 换掉预览图并把旧的放掉。原生内存不会被 GC 自动回收 */
  setPreview(next: image.PixelMap | undefined): void {
    if (this.preview !== undefined) {
      this.preview.release();
    }
    this.preview = next;
  }

  release(): void {
    this.setPreview(undefined);
    this.binary = null;
    this.sourceGray = null;
  }
}

/** 画布文档 */
@ObservedV2
export class CanvasDoc {
  /** 增删都整体换数组:@Trace 对「原地 push」的跟踪不如重新赋值可靠 */
  @Trace elements: CanvasElement[] = [];
  /** 最小长度(点)。内容不足这么长时按它出纸,方便固定长度的标签 */
  @Trace minLength: number = 200;
  /** 当前选中的元素 id,空串表示没选中 */
  @Trace selectedId: string = '';

  add(element: CanvasElement): void {
    this.elements = [...this.elements, element];
    this.selectedId = element.id;
  }

  remove(id: string): void {
    const kept: CanvasElement[] = [];
    for (const el of this.elements) {
      if (el.id === id) {
        el.release();
      } else {
        kept.push(el);
      }
    }
    this.elements = kept;
    if (this.selectedId === id) {
      this.selectedId = '';
    }
  }

  /** 置顶:移到数组末尾。合成按数组顺序 blit,后面的盖住前面的,所以置顶 = 盖住其他元素 */
  toTop(id: string): void {
    const list: CanvasElement[] = [...this.elements];
    const idx: number = list.findIndex((el: CanvasElement) => el.id === id);
    if (idx < 0) {
      return;
    }
    const el: CanvasElement = list.splice(idx, 1)[0];
    list.push(el);
    this.elements = list;
  }

  /** 置底:移到数组开头,被其他元素盖住 */
  toBottom(id: string): void {
    const list: CanvasElement[] = [...this.elements];
    const idx: number = list.findIndex((el: CanvasElement) => el.id === id);
    if (idx < 0) {
      return;
    }
    const el: CanvasElement = list.splice(idx, 1)[0];
    list.unshift(el);
    this.elements = list;
  }

  find(id: string): CanvasElement | undefined {
    for (const el of this.elements) {
      if (el.id === id) {
        return el;
      }
    }
    return undefined;
  }

  selected(): CanvasElement | undefined {
    return this.selectedId.length > 0 ? this.find(this.selectedId) : undefined;
  }

  releaseAll(): void {
    for (const el of this.elements) {
      el.release();
    }
    this.elements = [];
    this.selectedId = '';
  }

  /**
   * 画布当前长度(点)。
   * 取「最靠下元素的底边 + 留白」和「最小长度」中的大者,所以拖到底部会自动延长。
   */
  height(): number {
    let bottom: number = 0;
    for (const el of this.elements) {
      const elBottom: number = el.dotY + el.dotH;
      if (elBottom > bottom) {
        bottom = elBottom;
      }
    }
    const fitted: number = bottom > 0 ? bottom + CANVAS_BOTTOM_PAD : 0;
    return Math.min(MAX_CANVAS_HEIGHT, Math.max(this.minLength, fitted));
  }

  /**
   * 内容实际高度(点):最靠下元素的底边 + 留白,**不含最小长度**。
   *
   * 打印用这个而不是 height():height() 会按视口高度把空白也铺出去,
   * 内容不满一屏时打印会白白吐出一大段白纸。
   * 编辑器里的画布显示仍用 height()(留出可摆放的工作区)。
   */
  contentHeight(): number {
    let bottom: number = 0;
    for (const el of this.elements) {
      const elBottom: number = el.dotY + el.dotH;
      if (elBottom > bottom) {
        bottom = elBottom;
      }
    }
    return bottom > 0 ? Math.min(MAX_CANVAS_HEIGHT, bottom + CANVAS_BOTTOM_PAD) : 0;
  }

  /** 内容是否已经超出高度上限被截断 */
  overflowed(): boolean {
    let bottom: number = 0;
    for (const el of this.elements) {
      const elBottom: number = el.dotY + el.dotH;
      if (elBottom > bottom) {
        bottom = elBottom;
      }
    }
    return bottom + CANVAS_BOTTOM_PAD > MAX_CANVAS_HEIGHT;
  }
}

/** 新元素的默认落点:横向居中,纵向落在现有内容下方,免得叠在一起 */
export function nextInsertY(doc: CanvasDoc): number {
  let bottom: number = 0;
  for (const el of doc.elements) {
    const elBottom: number = el.dotY + el.dotH;
    if (elBottom > bottom) {
      bottom = elBottom;
    }
  }
  return bottom > 0 ? bottom + 8 : 8;
}

export function centeredX(dotW: number): number {
  return Math.max(0, Math.round((WIDTH_DOTS - dotW) / 2));
}
