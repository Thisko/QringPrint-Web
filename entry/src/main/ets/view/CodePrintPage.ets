import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { generateBarcode } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Metrics, Palette } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { PrintResult, PrinterConnection } from '../bluetooth/PrinterConnection';
import { DitherMode, ditherToBinary, GrayImage } from '../bluetooth/Dither';
import { binaryToPreviewPixelMap, pixelMapToGray, THRESHOLD_IMAGE } from '../bluetooth/RasterEncoder';
import { addHistory, HIST_TYPE_CODE } from '../model/HistoryStore';
import {
  CodeCategory,
  CodeType,
  sampleContent,
  typesOf,
  validateContent,
} from '../model/BarcodeModel';
import { ConnState, getPrinterStatus, PrinterStatus } from '../model/PrinterStatus';

const DOMAIN: number = 0x0001;
const TAG: string = 'CodePrintPage';

/**
 * 生成尺寸,宽高都固定 384。
 *
 * 宽 384 正好是打印头点数,后面 pixelMapToGray 里的兜底缩放会被跳过。
 * 高**也必须**给 384 —— createBarcode 对 height 有校验,一维码原来传 140 会直接抛
 * `401 parameter verification of height failed`。二维码用 384 是实测能过的,
 * 一维码沿用同一组尺寸,不去猜 SDK 那个没公开的下限。
 */
const GEN_SIZE: number = 384;
/**
 * 一维码实际打印高度(点)。
 * 生成拿到的是 384 高的方图,打之前纵向压到这个高度:
 * 一维码的信息全在横向,压扁不影响识读,但能省下一大截纸(384 点 ≈ 48mm)。
 */
const ONE_D_PRINT_HEIGHT: number = 140;
/** 输入停顿多久后才生成,避免每敲一个字符就跑一次 */
const DEBOUNCE_MS: number = 400;

/**
 * 纵向抽行压缩。
 *
 * 一维码同一根竖条内每一行完全相同,所以按最近邻抽行是无损的。
 * 不能取平均:平均会在黑白交界处糊出灰边,二值化后条宽就变了,直接影响识读。
 */
function squeezeRows(src: GrayImage, targetHeight: number): GrayImage {
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

function describeError(err: object): string {
  const business: BusinessError = err as BusinessError;
  const message: string = business.message !== undefined && business.message.length > 0
    ? business.message : JSON.stringify(err);
  const code: string = business.code !== undefined ? ` (code ${business.code})` : '';
  return `${message}${code}`;
}

/**
 * 条码打印页。
 *
 * 码制清单严格来自 scanCore.ScanType 的实际枚举值,按一维/二维分组。
 * 内容变化后防抖生成预览 —— 预览就是实际会打印的位图,不是示意图。
 *
 * 注意:条码**不做抖动**,固定走纯阈值二值化。
 * 抖动会把黑条边缘打散成点阵,直接破坏条码的可识别性。
 */
@ComponentV2
export struct CodePrintPage {
  @Local category: CodeCategory = CodeCategory.TWO_D;
  @Local typeIndex: number = 0;
  @Local content: string = 'https://example.com';
  @Local previewMap: image.PixelMap | undefined = undefined;
  @Local validationError: string = '';
  @Local generateError: string = '';
  @Local generating: boolean = false;
  @Local printing: boolean = false;
  @Local resultMessage: string = '';
  @Local resultOk: boolean = false;

  private status: PrinterStatus = getPrinterStatus();
  private safeArea: SafeArea = getSafeArea();
  private printer: PrinterConnection = PrinterConnection.getInstance();
  private debounceTimer: number = -1;
  /**
   * 生成序号。切码制和连续输入会并发触发多次生成,
   * 而 createBarcode 是异步的 —— 先发起的不保证先返回。
   * 每次生成领一个号,回来时对不上就说明自己已经过期了。
   */
  private generation: number = 0;

  aboutToAppear(): void {
    this.restoreHistoryPayload();
    this.generate();
  }

  /** 从历史记录恢复条码内容、类别和码制 */
  private restoreHistoryPayload(): void {
    const payload: string | undefined = AppStorage.get<string>('historyPayload');
    if (payload === undefined || payload.length === 0) {
      return;
    }
    AppStorage.setOrCreate('historyPayload', '');
    try {
      const p: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      this.category = Number(p['category'] ?? this.category) as CodeCategory;
      this.typeIndex = Number(p['typeIndex'] ?? this.typeIndex);
      const content: string = String(p['content'] ?? '');
      if (content.length > 0) {
        this.content = content;
      }
    } catch (err) {
      // 解析失败则保持默认
    }
  }

  aboutToDisappear(): void {
    this.cancelDebounce();
    this.releasePreview();
  }

  private busy(): boolean {
    return this.generating || this.printing;
  }

  private cancelDebounce(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  private releasePreview(): void {
    // PixelMap 是原生内存,换一张就得把上一张放掉
    if (this.previewMap !== undefined) {
      this.previewMap.release();
      this.previewMap = undefined;
    }
  }

  private options(): CodeType[] {
    return typesOf(this.category);
  }

  private currentType(): CodeType {
    const list: CodeType[] = this.options();
    if (this.typeIndex >= 0 && this.typeIndex < list.length) {
      return list[this.typeIndex];
    }
    return list[0];
  }

  private selectOptions(): SelectOption[] {
    const result: SelectOption[] = [];
    for (const type of this.options()) {
      result.push({ value: type.label });
    }
    return result;
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

  private switchCategory(next: CodeCategory): void {
    if (this.category === next || this.busy()) {
      return;
    }
    // 先撤掉待触发的防抖生成 —— 它带的是切换前的旧内容
    this.cancelDebounce();
    this.category = next;
    this.typeIndex = 0;
    // 保留用户已输入的内容:换码制不该把人家敲的东西冲掉。
    // 内容不合规时下面会给出提示,想要示例可以点「填入示例」。
    this.generate();
  }

  private switchType(index: number): void {
    if (this.typeIndex === index || this.busy()) {
      return;
    }
    this.cancelDebounce();
    this.typeIndex = index;
    this.generate();
  }

  /** 按当前码制填入一个合法示例,省得对着规则自己凑 */
  private fillSample(): void {
    if (this.busy()) {
      return;
    }
    this.cancelDebounce();
    this.content = sampleContent(this.currentType());
    this.generate();
  }

  private scheduleGenerate(): void {
    this.cancelDebounce();
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      this.generate();
    }, DEBOUNCE_MS);
  }

  private async generate(): Promise<void> {
    const token: number = ++this.generation;
    const type: CodeType = this.currentType();
    const error: string | null = validateContent(type, this.content);
    this.validationError = error !== null ? error : '';
    this.generateError = '';
    this.resultMessage = '';

    if (error !== null) {
      this.releasePreview();
      this.generating = false;
      return;
    }

    this.generating = true;
    let created: image.PixelMap | null = null;
    try {
      // 宽高都给 GEN_SIZE。height 传 140 会被 SDK 判为非法参数(401),一维码就是这么挂的
      created = await generateBarcode.createBarcode(this.content, {
        scanType: type.scanType,
        width: GEN_SIZE,
        height: GEN_SIZE,
        margin: 2,
      });

      // 走一遍真正的打印链路:灰度 →(一维码纵向压缩)→ 二值 → 位图。
      // 这样预览显示的是逐点等同于实际打印的那张图,不是另画一张示意图。
      let gray: GrayImage = await pixelMapToGray(created);
      if (type.category === CodeCategory.ONE_D) {
        gray = squeezeRows(gray, ONE_D_PRINT_HEIGHT);
      }
      const binary: Uint8Array = ditherToBinary(gray, DitherMode.NONE, THRESHOLD_IMAGE);
      const rendered: image.PixelMap =
        await binaryToPreviewPixelMap(binary, gray.width, gray.height);

      if (token !== this.generation) {
        // 期间又发起了更新的一次生成 —— 这张已经过期。
        // 不释放就是原生内存泄漏,覆盖上去则会让预览退回旧内容,
        // 而预览就是待打印的那张图,打出来就是错的码。
        rendered.release();
        return;
      }
      this.releasePreview();
      this.previewMap = rendered;
    } catch (err) {
      if (token !== this.generation) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'createBarcode failed: %{public}s', JSON.stringify(err));
      this.releasePreview();
      // 本地校验只能覆盖长度和字符集,校验位算法等规则以 SDK 为准,这里把它的错误如实透出
      this.generateError = `生成失败:${describeError(err as object)}`;
    } finally {
      // 原始方图只是中间产物,转成灰度后就没用了
      if (created !== null) {
        created.release();
      }
      // 只有最新的那次才有资格收起转圈,否则旧的一收,新的还在跑就没提示了
      if (token === this.generation) {
        this.generating = false;
      }
    }
  }

  private async doPrint(): Promise<void> {
    if (this.busy()) {
      return;
    }
    if (!this.connected()) {
      this.toast('请先在首页连接打印机');
      return;
    }
    const preview: image.PixelMap | undefined = this.previewMap;
    if (preview === undefined) {
      this.toast('请先输入有效内容');
      return;
    }

    this.printing = true;
    this.resultMessage = '';
    try {
      const fault: string | null = await this.printer.preflightCheck();
      if (fault !== null) {
        this.showFault(fault);
        return;
      }
      // 固定纯阈值,不抖动 —— 抖动会把黑条边缘打散,条码就扫不出来了
      const result: PrintResult =
        await this.printer.printPixelMap(preview, THRESHOLD_IMAGE, null);
      this.resultOk = result.ok;
      this.resultMessage = result.message;
      if (result.ok) {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const payload: string = JSON.stringify({
          content: this.content,
          category: this.category,
          typeIndex: this.typeIndex,
        });
        addHistory(ctx, HIST_TYPE_CODE, preview, payload);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'print failed: %{public}s', JSON.stringify(err));
      this.resultOk = false;
      this.resultMessage = `打印失败:${describeError(err as object)}`;
    } finally {
      this.printing = false;
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
  categoryRadio(value: string, label: string, target: CodeCategory) {
    Row() {
      Radio({ value: value, group: 'codeCategory' })
        .checked(this.category === target)
        .enabled(!this.busy())
        .onChange((isChecked: boolean) => {
          if (isChecked) {
            this.switchCategory(target);
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
      this.switchCategory(target);
    })
  }

  build() {
    NavDestination() {
      Column() {
        this.connectionBanner()

        Scroll() {
          Column() {
            // ── 类别单选 ──────────────────────────────
            Row({ space: 24 }) {
              this.categoryRadio('oneD', '条形码', CodeCategory.ONE_D)
              this.categoryRadio('twoD', '二维码', CodeCategory.TWO_D)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Palette.SURFACE)
            .borderRadius(12)

            // ── 码制选择 ──────────────────────────────
            Column() {
              Row() {
                Text('码制')
                  .fontSize(13)
                  .fontColor(Palette.TEXT_PRIMARY)
                  .layoutWeight(1)
                Select(this.selectOptions())
                  .selected(this.typeIndex)
                  .value(this.currentType().label)
                  .font({ size: 13 })
                  .enabled(!this.busy())
                  .onSelect((index: number) => {
                    this.switchType(index);
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row() {
                Text(this.currentType().hint)
                  .fontSize(11)
                  .fontColor(Palette.TEXT_SECONDARY)
                  .layoutWeight(1)
                Text('填入示例')
                  .fontSize(11)
                  .fontColor(Palette.BRAND)
                  .margin({ left: 10 })
                  .onClick(() => {
                    this.fillSample();
                  })
              }
              .width('100%')
              .margin({ top: 8 })
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .padding(12)
            .margin({ top: 12 })
            .backgroundColor(Palette.SURFACE)
            .borderRadius(12)

            // ── 内容输入 ──────────────────────────────
            TextArea({ placeholder: '输入要编码的内容', text: $$this.content })
              .width('100%')
              .height(100)
              .fontSize(15)
              .backgroundColor(Palette.SURFACE)
              .borderRadius(12)
              .padding(12)
              .margin({ top: 12 })
              .enabled(!this.busy())
              .onChange(() => {
                this.scheduleGenerate();
              })

            if (this.validationError.length > 0) {
              Text(this.validationError)
                .fontSize(12)
                .fontColor(Palette.DANGER)
                .width('100%')
                .margin({ top: 8 })
            } else if (this.generateError.length > 0) {
              Text(this.generateError)
                .fontSize(12)
                .fontColor(Palette.DANGER)
                .width('100%')
                .margin({ top: 8 })
            }

            // ── 预览 ────────────────────────────────���─
            Stack() {
              if (this.previewMap !== undefined) {
                Image(this.previewMap)
                  .width('100%')
                  .objectFit(ImageFit.Contain)
                  // 关掉插值,条码的黑白边界才不会被糊掉
                  .interpolation(ImageInterpolation.None)
              } else {
                Text('输入合法内容后自动生成预览')
                  .fontSize(12)
                  .fontColor(Palette.TEXT_SECONDARY)
              }

              if (this.generating) {
                LoadingProgress()
                  .width(28)
                  .height(28)
                  .color(Palette.BRAND)
              }
            }
            .width('100%')
            .height(200)
            .margin({ top: 12 })
            .padding(12)
            .backgroundColor(Palette.SURFACE)
            .borderRadius(12)

            Text('预览即打印效果 · 条码固定纯阈值二值化,不做抖动')
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

        Button(this.printing ? '打印中…' : '打印')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontColor(Palette.TEXT_ON_BRAND)
          .backgroundColor(
            this.busy() || !this.connected() || this.previewMap === undefined
              ? Palette.OFFLINE : Palette.BRAND)
          .enabled(!this.busy())
          .margin({ top: 12 })
          .onClick(() => {
            this.doPrint();
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
    .title('条码打印')
    // 全屏沉浸下 NavDestination 不会自己避让,不垫这一下标题栏和返回键会缩进状态栏里点不到
    .padding({ top: this.safeArea.top })
    .backgroundColor(Palette.PAGE_BG)
  }
}
