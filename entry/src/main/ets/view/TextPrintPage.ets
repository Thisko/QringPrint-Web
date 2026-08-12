import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { font } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Metrics, Palette } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { PrintResult, PrinterConnection } from '../bluetooth/PrinterConnection';
import { renderTextToPixelMap, TextRenderOptions, THRESHOLD_TEXT } from '../bluetooth/RasterEncoder';
import { ConnState, getPrinterStatus, PrinterStatus } from '../model/PrinterStatus';
import { addHistory, HIST_TYPE_TEXT } from '../model/HistoryStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'TextPrintPage';

/** 兜底字体族。系统列表拿不到时至少还有这三个通用族可选 */
const FALLBACK_FAMILIES: string[] = ['sans-serif', 'serif', 'monospace'];

function familyLabel(family: string): string {
  if (family === 'sans-serif') {
    return '系统默认(无衬线)';
  }
  if (family === 'serif') {
    return '衬线';
  }
  if (family === 'monospace') {
    return '等宽';
  }
  return family;
}

/** @Builder 参数必须收敛成单对象,多参数是按值传递、状态变化不刷新 */
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
 * 文字打印测试页。
 *
 * 二值化阈值固定 212(比图片的 128 高很多,否则细笔画会被吃掉),
 * 打印浓度 1 —— 两个都是 Python 实现打文字时的取值。
 */
@ComponentV2
export struct TextPrintPage {
  @Local text: string = '';
  @Local printing: boolean = false;
  @Local resultMessage: string = '';
  @Local resultOk: boolean = false;

  // ── 预览 ──────────────────────────────────────────────
  @Local previewMap: image.PixelMap | undefined = undefined;
  @Local showPreview: boolean = false;
  /** 宽高比,用来让预览图按原始比例撑开高度(渲染结果是 384 宽、高度不定) */
  @Local previewRatio: number = 1;
  /**
   * 边距参考线的内缩比例(%)。
   * 按渲染时的实际像素算,而不是拿当前滑块值现推 —— 参考线必须对应眼前这张图。
   */
  @Local previewInsetX: number = 0;
  @Local previewInsetY: number = 0;
  /** 渲染这张预览时用的边距,弹层里照实标出来 */
  @Local previewMargin: number = 0;

  // ── 排版参数 ──────────────────────────────────────────
  @Local fontFamilies: string[] = FALLBACK_FAMILIES;
  @Local fontOptions: SelectOption[] = [];
  @Local fontIndex: number = 0;
  @Local fontSize: number = 24;
  @Local bold: boolean = false;
  @Local italic: boolean = false;
  @Local underline: boolean = false;
  @Local letterSpacing: number = 0;
  @Local lineSpacing: number = 6;
  /**
   * 页边距(打印点)。1 点 = 1/8 mm,8 点即 1mm。
   * 不能叫 margin —— 会和 CustomComponent 基类的 margin() 属性方法撞名,编译不过。
   */
  @Local pageMargin: number = 8;

  private status: PrinterStatus = getPrinterStatus();
  private safeArea: SafeArea = getSafeArea();
  private printer: PrinterConnection = PrinterConnection.getInstance();

  aboutToAppear(): void {
    this.loadFontList();
    this.restoreHistoryPayload();
  }

  /** 从历史记录恢复文字内容和排版参数 */
  private restoreHistoryPayload(): void {
    const payload: string | undefined = AppStorage.get<string>('historyPayload');
    if (payload === undefined || payload.length === 0) {
      return;
    }
    AppStorage.setOrCreate('historyPayload', '');
    try {
      const p: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      this.text = String(p['text'] ?? this.text);
      this.fontSize = Number(p['fontSize'] ?? this.fontSize);
      this.bold = Boolean(p['bold'] ?? false);
      this.italic = Boolean(p['italic'] ?? false);
      this.underline = Boolean(p['underline'] ?? false);
      this.letterSpacing = Number(p['letterSpacing'] ?? 0);
      this.lineSpacing = Number(p['lineSpacing'] ?? 6);
      this.pageMargin = Number(p['pageMargin'] ?? 8);
      this.fontIndex = Number(p['fontIndex'] ?? 0);
    } catch (err) {
      // 解析失败则保持默认内容
    }
  }

  aboutToDisappear(): void {
    this.releasePreview();
  }

  /** PixelMap 是原生内存,换一张就得把上一张放掉 */
  private releasePreview(): void {
    if (this.previewMap !== undefined) {
      this.previewMap.release();
      this.previewMap = undefined;
    }
  }

  /**
   * 按当前排版参数渲染一张,弹半模态给用户看。
   *
   * 做成点按触发而不是实时预览:renderTextToPixelMap 是同步的整图重绘,
   * 挂在字号/间距滑块上会每拖一格就重画一次,手感直接卡死。
   */
  private async openPreview(): Promise<void> {
    if (this.printing) {
      return;
    }
    if (this.text.length === 0) {
      this.toast('请输入要打印的内容');
      return;
    }
    try {
      const options: TextRenderOptions = this.buildOptions();
      const rendered: image.PixelMap = renderTextToPixelMap(this.text, options);
      const info: image.ImageInfo = await rendered.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      this.releasePreview();
      this.previewMap = rendered;
      this.previewRatio = height > 0 ? width / height : 1;
      // 边距在位图里是实打实的白边,换算成百分比后叠一圈虚线把它标出来
      this.previewInsetX = width > 0 ? options.margin / width * 100 : 0;
      this.previewInsetY = height > 0 ? options.margin / height * 100 : 0;
      this.previewMargin = options.margin;
      this.showPreview = true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'preview render failed: %{public}s', JSON.stringify(err));
      this.toast('预览生成失败');
    }
  }

  /**
   * 枚举设备上真实存在的字体,而不是硬编一份猜测清单 ——
   * 不同机型预装字体差别很大,写死的族名在别的机器上会静默回落到默认字体。
   *
   * 两个来源合起来用:
   *   getSystemFontList() —— 只返回「已安装字体」,很多机型上这份列表很短甚至是空的
   *   getUIFontConfig()   —— 系统字体配置,信息量大得多:
   *                          generic[].family        字体集主族名
   *                          generic[].alias[].name  字重/字宽变体
   *                          fallbackGroups[]…family 各语种回退族(中日韩、泰文、emoji…)
   *
   * 注:getUIFontConfig 只在 @ohos.font 全局命名空间上,
   * UIContext.getFont() 里没有这个方法,所以这里两种调用方式并存。
   */
  private loadFontList(): void {
    const families: string[] = [];
    for (const generic of FALLBACK_FAMILIES) {
      families.push(generic);
    }

    const push: (name: string) => void = (name: string) => {
      if (name.length > 0 && families.indexOf(name) < 0) {
        families.push(name);
      }
    };

    try {
      const installed: Array<string> = this.getUIContext().getFont().getSystemFontList();
      for (const name of installed) {
        push(name);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getSystemFontList unavailable: %{public}s', JSON.stringify(err));
    }

    try {
      const config: font.UIFontConfig = font.getUIFontConfig();
      for (const generic of config.generic) {
        push(generic.family);
        for (const alias of generic.alias) {
          push(alias.name);
        }
      }
      for (const group of config.fallbackGroups) {
        for (const fallback of group.fallback) {
          push(fallback.family);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getUIFontConfig unavailable: %{public}s', JSON.stringify(err));
    }

    const options: SelectOption[] = [];
    for (const family of families) {
      options.push({ value: familyLabel(family) });
    }
    this.fontFamilies = families;
    this.fontOptions = options;
    this.fontIndex = 0;
    hilog.info(DOMAIN, TAG, 'font families: %{public}d', families.length);
  }

  private currentFamily(): string {
    if (this.fontIndex >= 0 && this.fontIndex < this.fontFamilies.length) {
      return this.fontFamilies[this.fontIndex];
    }
    return 'sans-serif';
  }

  private buildOptions(): TextRenderOptions {
    return {
      fontFamily: this.currentFamily(),
      fontSize: this.fontSize,
      bold: this.bold,
      italic: this.italic,
      underline: this.underline,
      letterSpacing: this.letterSpacing,
      lineSpacing: this.lineSpacing,
      margin: this.pageMargin,
    };
  }

  private connected(): boolean {
    return this.status.connState === ConnState.CONNECTED;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Previewer 下可能不可用
    }
  }

  /** 故障用弹窗而不是 Toast —— 这是拦停操作的硬条件,得让用户确认过再走 */
  private showFault(message: string): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '无法打印',
        message: message,
        confirm: {
          value: '知道了',
          action: () => {},
        },
      });
    } catch (err) {
      this.toast(message);
    }
  }

  private async doPrint(): Promise<void> {
    if (this.printing) {
      return;
    }
    if (!this.connected()) {
      this.toast('请先在首页连接打印机');
      return;
    }
    if (this.text.length === 0) {
      this.toast('请输入要打印的内容');
      return;
    }

    this.printing = true;
    this.resultMessage = '';

    let pixelMap: image.PixelMap | null = null;
    try {
      // 打印前现查一次机器状态,缺纸/开盖/过热直接拦住
      const fault: string | null = await this.printer.preflightCheck();
      if (fault !== null) {
        this.showFault(fault);
        return;
      }

      pixelMap = renderTextToPixelMap(this.text, this.buildOptions());
      const result: PrintResult = await this.printer.printPixelMap(pixelMap, THRESHOLD_TEXT, 1);
      this.resultOk = result.ok;
      this.resultMessage = result.message;
      if (result.ok) {
        // 历史记录在打印完成后异步做,不阻塞主线程,也不读会被 release 的 pixelMap
        this.recordHistoryAsync();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'print failed: %{public}s', JSON.stringify(err));
      this.resultOk = false;
      this.resultMessage = '文本渲染失败';
    } finally {
      // PixelMap 是原生内存,不释放会累积泄漏
      if (pixelMap !== null) {
        pixelMap.release();
      }
      this.printing = false;
    }
  }

  /** 打印成功后记录历史(异步,不阻塞主线程)。缩略图重新渲染小尺寸文字图,不读打印的 pixelMap */
  private recordHistoryAsync(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const payload: string = JSON.stringify({
      text: this.text,
      fontSize: this.fontSize,
      bold: this.bold,
      italic: this.italic,
      underline: this.underline,
      letterSpacing: this.letterSpacing,
      lineSpacing: this.lineSpacing,
      pageMargin: this.pageMargin,
      fontIndex: this.fontIndex,
    });
    try {
      // 缩略图用较小的字体渲染,避免大图同步读像素阻塞主线程
      const o: TextRenderOptions = this.buildOptions();
      const smallOpts: TextRenderOptions = {
        fontFamily: o.fontFamily,
        fontSize: 14,
        bold: o.bold,
        italic: o.italic,
        underline: o.underline,
        letterSpacing: o.letterSpacing,
        lineSpacing: o.lineSpacing,
        margin: o.margin,
      };
      const small: image.PixelMap = renderTextToPixelMap(this.text, smallOpts);
      addHistory(ctx, HIST_TYPE_TEXT, small, payload).then(() => {
        small.release();
      }).catch(() => {
        small.release();
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'record history failed: %{public}s', JSON.stringify(err));
      // 历史记录失败不影响打印结果
    }
  }

  @Builder
  connectionBanner() {
    Row() {
      Circle()
        .width(6)
        .height(6)
        .fill(this.connected() ? Palette.ONLINE : Palette.OFFLINE)
      Text(this.connected()
        ? `已连接 ${this.status.deviceName}`
        : '未连接打印机 —— 请回首页点状态卡选择设备')
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
        .margin({ left: 6 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .backgroundColor(Palette.SURFACE)
    .borderRadius(10)
    .alignItems(VerticalAlign.Center)
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
      .enabled(!this.printing)
      .opacity(this.printing ? 0.4 : 1)
      .onClick(p.onTap)
  }

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
        .enabled(!this.printing)
        .onChange((value: number) => {
          p.onChange(Math.round(value));
        })
    }
    .width('100%')
    .margin({ top: 6 })
  }

  @Builder
  previewSheet() {
    Column() {
      Row() {
        Text(`纸宽 384 点 · 边距 ${this.previewMargin} 点 ≈ ${(this.previewMargin / 8).toFixed(1)}mm`)
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .layoutWeight(1)
        // 图例:说明那圈虚线是什么
        Text('虚线内为文字区')
          .fontSize(11)
          .fontColor(Palette.BRAND)
      }
      .width('100%')
      .margin({ bottom: 10 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        if (this.previewMap !== undefined) {
          // 纸张本体:外层灰底 + 这里一圈浅边框,白纸的边界才看得出来。
          // 否则白边距贴在白容器上完全看不见 —— 边距等于没显示。
          Stack() {
            Image(this.previewMap)
              .width('100%')
              .height('100%')
              // 关掉插值,笔画边界才不会被糊成灰
              .interpolation(ImageInterpolation.None)

            // 边距参考线:居中内缩,四边各让出 margin,框住的就是文字可用区
            Column()
              .width(`${Math.max(0, 100 - this.previewInsetX * 2)}%`)
              .height(`${Math.max(0, 100 - this.previewInsetY * 2)}%`)
              .border({ width: 1, color: Palette.BRAND, style: BorderStyle.Dashed })
              // 纯参考线,别拦住手势
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          // aspectRatio 必须挂在 Stack 上,不能挂 Image:
          // 挂 Image 的话 Stack 自身没有确定高度,会被 Scroll 拉成整屏高,
          // 而 Stack 默认 Center 对齐 —— 图片就被垂直居中了,
          // 虚线框的百分比高度也跟着按整屏算,框远大于文本。
          .aspectRatio(this.previewRatio)
          .border({ width: 1, color: '#D8DCE3' })
          .backgroundColor('#FFFFFF')
        }
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      // 灰底衬出白纸
      .backgroundColor(Palette.PAGE_BG)
      .padding(12)
    }
    .width('100%')
    .height('100%')
    .padding(Metrics.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Palette.PAGE_BG)
  }

  build() {
    NavDestination() {
      Column() {
        this.connectionBanner()

        Scroll() {
          Column() {
            TextArea({ placeholder: '输入要打印的文字,支持换行', text: $$this.text })
              .width('100%')
              .height(140)
              .fontSize(15)
              .backgroundColor(Palette.SURFACE)
              .borderRadius(12)
              .padding(12)
              .maxLength(1000)
              .showCounter(true)

            Text('排版设置')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT_PRIMARY)
              .width('100%')
              .margin({ top: 16, bottom: 8 })

            Column() {
              Row() {
                Text('字体')
                  .fontSize(13)
                  .fontColor(Palette.TEXT_PRIMARY)
                  .layoutWeight(1)
                Select(this.fontOptions)
                  .selected(this.fontIndex)
                  .value(familyLabel(this.currentFamily()))
                  .font({ size: 13 })
                  .enabled(!this.printing)
                  .onSelect((index: number) => {
                    this.fontIndex = index;
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(`共 ${this.fontFamilies.length} 种 · 回退族不一定能被画布解析,选了没变化就换一个`)
                .fontSize(10)
                .fontColor(Palette.TEXT_SECONDARY)
                .width('100%')
                .margin({ top: 4 })

              Row({ space: 8 }) {
                this.toggleChip({
                  label: 'B',
                  active: this.bold,
                  bold: true,
                  italic: false,
                  underline: false,
                  onTap: () => {
                    this.bold = !this.bold;
                  },
                })
                this.toggleChip({
                  label: 'I',
                  active: this.italic,
                  bold: false,
                  italic: true,
                  underline: false,
                  onTap: () => {
                    this.italic = !this.italic;
                  },
                })
                this.toggleChip({
                  label: 'U',
                  active: this.underline,
                  bold: false,
                  italic: false,
                  underline: true,
                  onTap: () => {
                    this.underline = !this.underline;
                  },
                })
              }
              .width('100%')
              .margin({ top: 12 })

              this.sliderRow({
                label: '字号',
                value: this.fontSize,
                min: 12,
                max: 60,
                suffix: ' 点',
                onChange: (value: number) => {
                  this.fontSize = value;
                },
              })

              this.sliderRow({
                label: '字间距',
                value: this.letterSpacing,
                min: 0,
                max: 16,
                suffix: ' 点',
                onChange: (value: number) => {
                  this.letterSpacing = value;
                },
              })

              this.sliderRow({
                label: '行间距',
                value: this.lineSpacing,
                min: 0,
                max: 32,
                suffix: ' 点',
                onChange: (value: number) => {
                  this.lineSpacing = value;
                },
              })

              // 上限 48 点(6mm):再大文字可用宽度就被挤得没剩多少了
              this.sliderRow({
                label: '页边距',
                value: this.pageMargin,
                min: 0,
                max: 48,
                suffix: ' 点',
                onChange: (value: number) => {
                  this.pageMargin = value;
                },
              })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Palette.SURFACE)
            .borderRadius(12)

            Text(`按 384 点宽渲染并自动换行 · 阈值 ${THRESHOLD_TEXT} · 浓度 1`)
              .fontSize(11)
              .fontColor(Palette.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 8, bottom: 8 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .margin({ top: 12 })

        Row() {
          Button('打印预览')
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontColor(Palette.BRAND)
            .backgroundColor(Palette.SURFACE)
            .opacity(this.printing || this.text.length === 0 ? 0.4 : 1)
            .enabled(!this.printing && this.text.length > 0)
            .onClick(() => {
              this.openPreview();
            })

          Button(this.printing ? '打印中…' : '打印')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor(Palette.TEXT_ON_BRAND)
            .backgroundColor(this.printing || !this.connected() ? Palette.OFFLINE : Palette.BRAND)
            .enabled(!this.printing)
            .margin({ left: 12 })
            .onClick(() => {
              this.doPrint();
            })
        }
        .width('100%')
        .margin({ top: 12 })
        .bindSheet($$this.showPreview, this.previewSheet(), {
          height: SheetSize.LARGE,
          preferType: SheetType.BOTTOM,
          title: { title: '打印预览' },
          backgroundColor: Palette.PAGE_BG,
        })

        if (this.resultMessage.length > 0) {
          Text(this.resultMessage)
            .fontSize(13)
            .fontColor(this.resultOk ? Palette.ONLINE : Palette.DANGER)
            .width('100%')
            .margin({ top: 10 })
        }
      }
      .width('100%')
      .height('100%')
      .padding(Metrics.PAGE_PADDING)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Palette.PAGE_BG)
    }
    .title('文字打印')
    // 全屏沉浸下 NavDestination 不会自己避让,不垫这一下标题栏和返回键会缩进状态栏里点不到
    .padding({ top: this.safeArea.top })
    .backgroundColor(Palette.PAGE_BG)
  }
}
