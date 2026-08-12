import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Metrics, Palette } from '../common/Theme';
import { familyAt, familyLabel, loadFontFamilies, FontListResult } from '../common/FontList';
import { DITHER_OPTIONS, DitherMode, DitherOption } from '../bluetooth/Dither';
import { TextRenderOptions } from '../bluetooth/RasterEncoder';
import { codeOneDAspect, DEFAULT_CODE_1D_WIDTH, DEFAULT_CODE_2D_SIZE } from '../common/ElementRender';
import { WIDTH_DOTS } from '../bluetooth/QringProtocol';
import { CanvasElement, ElementKind, MIN_ELEMENT_SIZE } from '../model/CanvasModel';
import {
  CODE_TYPES,
  CodeCategory,
  CodeType,
  sampleContent,
  typesOf,
  validateContent,
} from '../model/BarcodeModel';

const DOMAIN: number = 0x0001;
const TAG: string = 'ElementEditSheet';

/** @Builder 参数必须收敛成单对象:多参数按值传递,状态变化不会刷新 Builder 内部 */
interface SliderRowParams {
  label: string;
  value: number;
  min: number;
  max: number;
  suffix: string;
  onChange: (value: number) => void;
}

interface ToggleChipParams {
  label: string;
  active: boolean;
  italic: boolean;
  underline: boolean;
  bold: boolean;
  onTap: () => void;
}

/**
 * 元素编辑半模态 —— 双击画布元素弹出。
 *
 * 三种元素共用一个组件,按 kind 分支。这样外层只要一个 bindSheet,
 * 不用为三种类型各维护一套开关状态。
 *
 * 所有改动**即时写回元素模型**,并通过 onChanged 通知外层重新渲染位图。
 * 没有「取消」——画布编辑器里所见即所得,反悔用删除。
 */
@ComponentV2
export struct ElementEditSheet {
  @Param @Require element: CanvasElement;
  @Event onChanged: () => void = () => {};
  @Event onDelete: () => void = () => {};
  @Event onClose: () => void = () => {};

  // ── 文字 ──────────────────────────────────────────────
  @Local fontFamilies: string[] = [];
  @Local fontOptions: SelectOption[] = [];
  @Local fontIndex: number = 0;
  @Local text: string = '';
  @Local fontSize: number = 24;
  @Local bold: boolean = false;
  @Local italic: boolean = false;
  @Local underline: boolean = false;
  @Local letterSpacing: number = 0;
  @Local lineSpacing: number = 6;
  @Local pageMargin: number = 8;
  @Local boxWidth: number = WIDTH_DOTS;

  // ── 条码 ──────────────────────────────────────────────
  @Local codeContent: string = '';
  @Local codeError: string = '';
  /** 当前码制类别。一维/二维的可选项和输入规则完全不同,必须分开选 */
  @Local codeCategory: CodeCategory = CodeCategory.TWO_D;

  aboutToAppear(): void {
    hilog.info(0x0001, 'ElementEditSheet', 'aboutToAppear kind=%{public}d', this.element.kind);
    this.syncFromElement();
  }

  /** 把元素当前状态灌进本地控件 */
  private syncFromElement(): void {
    const el: CanvasElement = this.element;
    if (el.kind === ElementKind.TEXT) {
      const result: FontListResult = loadFontFamilies(this.systemFonts());
      this.fontFamilies = result.families;
      this.fontOptions = result.options;
      const opts: TextRenderOptions = el.textOptions;
      const found: number = this.fontFamilies.indexOf(opts.fontFamily);
      this.fontIndex = found >= 0 ? found : 0;
      this.text = el.text;
      this.fontSize = opts.fontSize;
      this.bold = opts.bold;
      this.italic = opts.italic;
      this.underline = opts.underline;
      this.letterSpacing = opts.letterSpacing;
      this.lineSpacing = opts.lineSpacing;
      this.pageMargin = opts.margin;
      this.boxWidth = Math.max(MIN_ELEMENT_SIZE, Math.round(el.dotW));
    } else if (el.kind === ElementKind.CODE) {
      this.codeContent = el.codeContent;
      this.codeCategory = el.codeType().category;
    }
  }

  private systemFonts(): string[] {
    try {
      return this.getUIContext().getFont().getSystemFontList();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getSystemFontList unavailable: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Previewer 下可能不可用
    }
  }

  // ── 文字:改动写回 ────────────────────────────────────
  private commitText(): void {
    // 整体替换而不是改内部字段 —— @Trace 只跟踪重新赋值
    const opts: TextRenderOptions = {
      fontFamily: familyAt(this.fontFamilies, this.fontIndex),
      fontSize: this.fontSize,
      bold: this.bold,
      italic: this.italic,
      underline: this.underline,
      letterSpacing: this.letterSpacing,
      lineSpacing: this.lineSpacing,
      margin: this.pageMargin,
    };
    this.element.text = this.text;
    this.element.textOptions = opts;
    // 排版宽度就是元素宽度;高度由排版结果决定,渲染时会回写
    this.element.dotW = Math.max(MIN_ELEMENT_SIZE,
      Math.min(WIDTH_DOTS - this.element.dotX, this.boxWidth));
    this.onChanged();
  }

  // ── 条码:改动写回 ────────────────────────────────────
  private commitCode(): void {
    const type: CodeType = this.element.codeType();
    const error: string | null = validateContent(type, this.codeContent);
    this.codeError = error !== null ? error : '';
    if (error !== null) {
      return;
    }
    this.element.codeContent = this.codeContent;
    this.onChanged();
  }

  private switchCodeType(index: number): void {
    // Select 给的是「当前类别内」的下标,元素里存的是 CODE_TYPES 的全局下标,
    // 这里换算一次。typesOf 返回的是同一批对象引用,所以 indexOf 能对上
    const list: CodeType[] = typesOf(this.codeCategory);
    if (index < 0 || index >= list.length) {
      return;
    }
    const global: number = CODE_TYPES.indexOf(list[index]);
    this.element.codeTypeIndex = global >= 0 ? global : 0;
    // 类别变了,按新类别重设形状:一维码扁、二维码方。
    // 必须在这里改而不是渲染时 —— 渲染完再改会闪一下错误的比例。
    this.applyCodeShape();
    // 换码制不清空用户输入,只重新校验
    this.commitCode();
  }

  /** 条码换类别后重设宽高比和尺寸。用户手动缩放过的比例会被覆盖,这是切换类别的预期行为 */
  private applyCodeShape(): void {
    const isOneD: boolean = this.element.codeType().category === CodeCategory.ONE_D;
    if (isOneD) {
      this.element.aspect = codeOneDAspect();
      this.element.dotW = DEFAULT_CODE_1D_WIDTH;
      this.element.dotH = Math.max(1, Math.round(this.element.dotW / this.element.aspect));
    } else {
      this.element.aspect = 1;
      this.element.dotW = DEFAULT_CODE_2D_SIZE;
      this.element.dotH = DEFAULT_CODE_2D_SIZE;
    }
  }

  /** 切换一维/二维:类别内规则完全不同,默认落到该类别第一个码制 */
  private switchCodeCategory(next: CodeCategory): void {
    if (this.codeCategory === next) {
      return;
    }
    this.codeCategory = next;
    this.switchCodeType(0);
  }

  /** 只列当前类别的码制 —— 一维和二维混在一个下拉里选不清楚 */
  private codeOptions(): SelectOption[] {
    const result: SelectOption[] = [];
    for (const type of typesOf(this.codeCategory)) {
      result.push({ value: type.label });
    }
    return result;
  }

  /** 元素当前码制在所属类别里的下标,给 Select 用 */
  private codeIndexInCategory(): number {
    const list: CodeType[] = typesOf(this.codeCategory);
    const found: number = list.indexOf(this.element.codeType());
    return found >= 0 ? found : 0;
  }

  @Builder
  categoryRadio(value: string, label: string, target: CodeCategory) {
    Row() {
      Radio({ value: value, group: 'elementCodeCategory' })
        .checked(this.codeCategory === target)
        .onChange((isChecked: boolean) => {
          if (isChecked) {
            this.switchCodeCategory(target);
          }
        })
      Text(label)
        .fontSize(14)
        .fontColor(Palette.TEXT_PRIMARY)
        .margin({ left: 2 })
    }
    .alignItems(VerticalAlign.Center)
    // 点文字也能选中,不用非得戳中那个小圆点
    .onClick(() => {
      this.switchCodeCategory(target);
    })
  }

  private async repickImage(): Promise<void> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const selected: photoAccessHelper.PhotoSelectResult = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (selected.photoUris.length === 0) {
        return;
      }
      this.element.imageUri = selected.photoUris[0];
      // 换图要重新解码,清掉灰度缓存让外层重建
      this.element.sourceGray = null;
      this.onChanged();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'repick failed: %{public}s', JSON.stringify(err));
      this.toast('打开相册失败');
    }
  }

  // ── 通用控件 ──────────────────────────────────────────

  @Builder
  sliderRow(p: SliderRowParams) {
    Column() {
      Row() {
        Text(p.label)
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .layoutWeight(1)
        Text(`${p.value}${p.suffix}`)
          .fontSize(13)
          .fontColor(Palette.TEXT_SECONDARY)
      }
      .width('100%')

      Slider({
        value: p.value,
        min: p.min,
        max: p.max,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .selectedColor(Palette.BRAND)
        .trackThickness(4)
        .onChange((value: number) => {
          p.onChange(Math.round(value));
        })
    }
    .width('100%')
    .margin({ top: 6 })
  }

  @Builder
  toggleChip(p: ToggleChipParams) {
    Text(p.label)
      .layoutWeight(1)
      .height(36)
      .textAlign(TextAlign.Center)
      .fontSize(15)
      // 让按钮本身就长成它代表的样式,不用看文字也知道是什么
      .fontWeight(p.bold ? FontWeight.Bold : FontWeight.Normal)
      .fontStyle(p.italic ? FontStyle.Italic : FontStyle.Normal)
      .decoration({ type: p.underline ? TextDecorationType.Underline : TextDecorationType.None })
      .fontColor(p.active ? Palette.TEXT_ON_BRAND : Palette.TEXT_PRIMARY)
      .backgroundColor(p.active ? Palette.BRAND : Palette.SURFACE)
      .borderRadius(8)
      .onClick(p.onTap)
  }

  @Builder
  sectionCard(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor(Palette.TEXT_PRIMARY)
      .width('100%')
      .margin({ top: 12, bottom: 6 })
  }

  // ── 三种元素各自的编辑区 ──────────────────────────────

  @Builder
  textEditor() {
    Column() {
      TextArea({ placeholder: '输入文字内容', text: $$this.text })
        .width('100%')
        .height(90)
        .fontSize(15)
        .backgroundColor(Palette.SURFACE)
        .borderRadius(10)
        .padding(10)
        .onChange(() => {
          this.commitText();
        })

     // this.sectionCard('字体')
      // 字体下拉。之前用 ‹ › 循环切换,字体清单长的时候一路点下去很累;
      // 若真机上 Select 在 sheet 里复现 AceSheet 布局错,再退回 ‹ › 方案。
      Row() {
        Text('字体')
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .layoutWeight(1)
        Select(this.fontOptions)
          .selected(this.fontIndex)
          .value(familyLabel(familyAt(this.fontFamilies, this.fontIndex)))
          .font({ size: 13 })
          .onSelect((index: number) => {
            this.fontIndex = index;
            this.commitText();
          })
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        this.toggleChip({
          label: '粗体', active: this.bold, bold: true, italic: false, underline: false,
          onTap: () => {
            this.bold = !this.bold;
            this.commitText();
          },
        })
        this.toggleChip({
          label: '斜体', active: this.italic, bold: false, italic: true, underline: false,
          onTap: () => {
            this.italic = !this.italic;
            this.commitText();
          },
        })
        this.toggleChip({
          label: '下划线', active: this.underline, bold: false, italic: false, underline: true,
          onTap: () => {
            this.underline = !this.underline;
            this.commitText();
          },
        })
      }
      .width('100%')
      .margin({ top: 10 })

      this.sliderRow({
        label: '字号', value: this.fontSize, min: 12, max: 60, suffix: ' 点',
        onChange: (value: number) => {
          this.fontSize = value;
          this.commitText();
        },
      })
      this.sliderRow({
        label: '字间距', value: this.letterSpacing, min: 0, max: 16, suffix: ' 点',
        onChange: (value: number) => {
          this.letterSpacing = value;
          this.commitText();
        },
      })
      this.sliderRow({
        label: '行间距', value: this.lineSpacing, min: 0, max: 32, suffix: ' 点',
        onChange: (value: number) => {
          this.lineSpacing = value;
          this.commitText();
        },
      })
      this.sliderRow({
        label: '内边距', value: this.pageMargin, min: 0, max: 48, suffix: ' 点',
        onChange: (value: number) => {
          this.pageMargin = value;
          this.commitText();
        },
      })
      // 文字没有缩放手柄,宽度只能在这里调 —— 它决定折行位置
      this.sliderRow({
        label: '排版宽度', value: this.boxWidth, min: 48, max: WIDTH_DOTS, suffix: ' 点',
        onChange: (value: number) => {
          this.boxWidth = value;
          this.commitText();
        },
      })
    }
    .width('100%')
  }

  @Builder
  imageEditor() {
    Column() {
      this.sectionCard('抖动算法(预览即打印效果)')
      Row({ space: 8 }) {
        ForEach(DITHER_OPTIONS, (option: DitherOption) => {
          Text(option.label)
            .layoutWeight(1)
            .height(36)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor(this.element.ditherMode === option.mode
              ? Palette.TEXT_ON_BRAND : Palette.TEXT_PRIMARY)
            .backgroundColor(this.element.ditherMode === option.mode
              ? Palette.BRAND : Palette.SURFACE)
            .borderRadius(8)
            .onClick(() => {
              this.element.ditherMode = option.mode;
              this.onChanged();
            })
        }, (option: DitherOption) => option.label)
      }
      .width('100%')

      Text(`当前尺寸 ${Math.round(this.element.dotW)} × ${Math.round(this.element.dotH)} 点 · 拖右下角可缩放`)
        .fontSize(11)
        .fontColor(Palette.TEXT_SECONDARY)
        .width('100%')
        .margin({ top: 10 })

      Button('重新选图')
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(Palette.BRAND)
        .backgroundColor(Palette.SURFACE)
        .margin({ top: 12 })
        .onClick(() => {
          this.repickImage();
        })
    }
    .width('100%')
  }

  @Builder
  codeEditor() {
    Column() {
      this.sectionCard('类别')
      Row({ space: 24 }) {
        this.categoryRadio('elOneD', '条形码', CodeCategory.ONE_D)
        this.categoryRadio('elTwoD', '二维码', CodeCategory.TWO_D)
      }
      .width('100%')

      //this.sectionCard('码制')
      // 码制下拉,只列当前类别的一维/二维码制。与 ‹ › 循环切换同一套
      // switchCodeType 写回逻辑,只是选择方式改成点开下拉一次选到。
      Row() {
        Text('码制')
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .layoutWeight(1)
        Select(this.codeOptions())
          .selected(this.codeIndexInCategory())
          .value(this.element.codeType().label)
          .font({ size: 13 })
          .onSelect((index: number) => {
            this.switchCodeType(index);
          })
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      Text(this.element.codeType().hint)
        .fontSize(11)
        .fontColor(Palette.TEXT_SECONDARY)
        .width('100%')
        .margin({ top: 8 })

      this.sectionCard('内容')
      TextArea({ placeholder: '输入要编码的内容', text: $$this.codeContent })
        .width('100%')
        .height(80)
        .fontSize(15)
        .backgroundColor(Palette.SURFACE)
        .borderRadius(10)
        .padding(10)
        .onChange(() => {
          this.commitCode();
        })

      if (this.codeError.length > 0) {
        Text(this.codeError)
          .fontSize(12)
          .fontColor(Palette.DANGER)
          .width('100%')
          .margin({ top: 8 })
      }

      Text('填入示例')
        .fontSize(12)
        .fontColor(Palette.BRAND)
        .margin({ top: 10 })
        .onClick(() => {
          this.codeContent = sampleContent(this.element.codeType());
          this.commitCode();
        })
    }
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          if (this.element.kind === ElementKind.TEXT) {
            this.textEditor()
          } else if (this.element.kind === ElementKind.IMAGE) {
            this.imageEditor()
          } else {
            this.codeEditor()
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      Row() {
        Button('删除')
          .layoutWeight(1)
          .height(46)
          .fontSize(15)
          .fontColor(Palette.DANGER)
          .backgroundColor(Palette.SURFACE)
          .onClick(() => {
            this.onDelete();
            this.onClose();
          })

        Button('完成')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .fontColor(Palette.TEXT_ON_BRAND)
          .backgroundColor(Palette.BRAND)
          .margin({ left: 12 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .padding(Metrics.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Palette.PAGE_BG)
  }
}
