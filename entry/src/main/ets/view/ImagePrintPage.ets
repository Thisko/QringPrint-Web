import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Metrics, Palette } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { PrintResult, PrinterConnection } from '../bluetooth/PrinterConnection';
import { DITHER_OPTIONS, DitherMode, DitherOption, ditherToBinary, GrayImage } from '../bluetooth/Dither';
import {
  binaryToPreviewPixelMap,
  decodeImageToPrintWidth,
  packBinaryToRaster,
  pixelMapToGray,
  RasterData,
  THRESHOLD_IMAGE,
} from '../bluetooth/RasterEncoder';
import { ConnState, getPrinterStatus, PrinterStatus } from '../model/PrinterStatus';
import { addHistoryGray, HIST_TYPE_IMAGE } from '../model/HistoryStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'ImagePrintPage';

function describeError(err: object): string {
  const business: BusinessError = err as BusinessError;
  const message: string = business.message !== undefined && business.message.length > 0
    ? business.message : JSON.stringify(err);
  const code: string = business.code !== undefined ? ` (code ${business.code})` : '';
  return `${message}${code}`;
}

/**
 * 图片打印测试页:选图 → 选抖动算法 → 实时预览 → 打印。
 *
 * 热敏头是 1-bit 的,只能打黑或不打。纯阈值会把中间灰度一刀切,照片就没了层次;
 * 抖动把量化误差扩散到邻近像素,用点阵疏密模拟灰阶。
 *
 * 预览显示的是**抖动后的真实结果**而不是原图,所见即所打。
 */
@ComponentV2
export struct ImagePrintPage {
  @Local imageUri: string = '';
  @Local ditherMode: DitherMode = DitherMode.FLOYD_STEINBERG;
  @Local previewMap: image.PixelMap | undefined = undefined;
  @Local processing: boolean = false;
  @Local processingHint: string = '';
  @Local printing: boolean = false;
  @Local resultMessage: string = '';
  @Local resultOk: boolean = false;

  private status: PrinterStatus = getPrinterStatus();
  private safeArea: SafeArea = getSafeArea();
  private printer: PrinterConnection = PrinterConnection.getInstance();

  /** 灰度缓存 —— 切换抖动算法时复用,不必重新解码图片 */
  private gray: GrayImage | null = null;

  aboutToAppear(): void {
    this.restoreHistoryPayload();
  }

  /** 从历史记录恢复图片 uri 和抖动算法,然后重新解码加载 */
  private restoreHistoryPayload(): void {
    const payload: string | undefined = AppStorage.get<string>('historyPayload');
    if (payload === undefined || payload.length === 0) {
      return;
    }
    AppStorage.setOrCreate('historyPayload', '');
    try {
      const p: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      const uri: string = String(p['uri'] ?? '');
      if (uri.length > 0) {
        this.imageUri = uri;
        this.ditherMode = Number(p['ditherMode'] ?? this.ditherMode) as DitherMode;
        // 重新走一遍选图后的加载链路
        this.resultMessage = '';
        this.loadGray().then(() => {
          this.renderPreview();
        });
      }
    } catch (err) {
      // 解析失败则保持空
    }
  }

  aboutToDisappear(): void {
    this.releasePreview();
  }

  /** 处理中或打印中,期间所有操作入口都要锁住 */
  private busy(): boolean {
    return this.processing || this.printing;
  }

  private releasePreview(): void {
    // PixelMap 是原生内存,换一张就得把上一张放掉,否则来回切算法会一直堆积
    if (this.previewMap !== undefined) {
      this.previewMap.release();
      this.previewMap = undefined;
    }
  }

  private connected(): boolean {
    return this.status.connState === ConnState.CONNECTED;
  }

  /**
   * 是否已经挑过图。
   * 用 imageUri 而不是 gray 判断:解码失败时 gray 是 null,但这种情况恰恰更需要能重选。
   */
  private hasImage(): boolean {
    return this.imageUri.length > 0;
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

  private currentHint(): string {
    for (const option of DITHER_OPTIONS) {
      if (option.mode === this.ditherMode) {
        return option.hint;
      }
    }
    return '';
  }

  private async pickImage(): Promise<void> {
    if (this.busy()) {
      return;
    }
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const selected: photoAccessHelper.PhotoSelectResult = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (selected.photoUris.length === 0) {
        return;
      }
      this.imageUri = selected.photoUris[0];
      this.resultMessage = '';
      await this.loadGray();
      await this.renderPreview();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'photo picker failed: %{public}s', JSON.stringify(err));
      this.toast('打开相册失败');
    }
  }

  /** 解码 + 灰度化,结果缓存起来供各算法复用 */
  private async loadGray(): Promise<void> {
    this.gray = null;
    this.releasePreview();
    let decoded: image.PixelMap | null = null;
    try {
      this.processing = true;
      this.processingHint = '正在解码图片…';
      decoded = await decodeImageToPrintWidth(this.imageUri);
      this.gray = await pixelMapToGray(decoded);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'decode failed: %{public}s', JSON.stringify(err));
      this.resultOk = false;
      this.resultMessage = `图片解码失败:${describeError(err as object)}`;
    } finally {
      if (decoded !== null) {
        decoded.release();
      }
      this.processing = false;
    }
  }

  /** 跑一遍抖动并生成预览位图 */
  private async renderPreview(): Promise<void> {
    const gray: GrayImage | null = this.gray;
    if (gray === null) {
      return;
    }
    try {
      this.processing = true;
      this.processingHint = '正在生成预览…';
      // 让出一帧,保证 loading 态先渲染出来 ——
      // 抖动是同步密集计算,不让出去的话 UI 会直接卡住、加载态根本看不见
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 16);
      });

      const binary: Uint8Array = ditherToBinary(gray, this.ditherMode, THRESHOLD_IMAGE);
      const next: image.PixelMap =
        await binaryToPreviewPixelMap(binary, gray.width, gray.height);
      this.releasePreview();
      this.previewMap = next;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'preview failed: %{public}s', JSON.stringify(err));
    } finally {
      this.processing = false;
    }
  }

  private async selectMode(mode: DitherMode): Promise<void> {
    if (this.ditherMode === mode || this.busy()) {
      return;
    }
    this.ditherMode = mode;
    await this.renderPreview();
  }

  private async doPrint(): Promise<void> {
    if (this.busy()) {
      return;
    }
    if (!this.connected()) {
      this.toast('请先在首页连接打印机');
      return;
    }
    const gray: GrayImage | null = this.gray;
    if (gray === null) {
      this.toast('请先选择一张图片');
      return;
    }

    this.printing = true;
    this.resultMessage = '';
    try {
      // 打印前现查一次机器状态,缺纸/开盖/过热直接拦住
      const fault: string | null = await this.printer.preflightCheck();
      if (fault !== null) {
        this.showFault(fault);
        return;
      }

      // 直接复用灰度缓存,不重新解码 —— 预览看到的和打出来的是同一份数据
      const binary: Uint8Array = ditherToBinary(gray, this.ditherMode, THRESHOLD_IMAGE);
      const raster: RasterData = packBinaryToRaster(binary, gray.width, gray.height);
      const result: PrintResult = await this.printer.printRaster(raster, null);
      this.resultOk = result.ok;
      this.resultMessage = result.message;
      if (result.ok) {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const payload: string = JSON.stringify({
          uri: this.imageUri,
          ditherMode: this.ditherMode,
        });
        addHistoryGray(ctx, HIST_TYPE_IMAGE, gray, payload);
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
  ditherSelector() {
    Column() {
      Row({ space: 8 }) {
        ForEach(DITHER_OPTIONS, (option: DitherOption) => {
          Text(option.label)
            .layoutWeight(1)
            .height(36)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontWeight(this.ditherMode === option.mode ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.ditherMode === option.mode
              ? Palette.TEXT_ON_BRAND : Palette.TEXT_PRIMARY)
            .backgroundColor(this.ditherMode === option.mode
              ? Palette.BRAND : Palette.SURFACE)
            .borderRadius(8)
            // 处理中 / 打印中一律锁住,并给出视觉上的禁用反馈
            .opacity(this.busy() ? 0.4 : 1)
            .enabled(!this.busy())
            .onClick(() => {
              this.selectMode(option.mode);
            })
        }, (option: DitherOption) => option.label)
      }
      .width('100%')

      Text(this.currentHint())
        .fontSize(11)
        .fontColor(Palette.TEXT_SECONDARY)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Column() {
        this.connectionBanner()

        Stack() {
          if (this.previewMap !== undefined) {
            // 显示抖动后的真实结果。关掉插值,否则放大时点阵会被糊成灰,预览就失真了
            Image(this.previewMap)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .interpolation(ImageInterpolation.None)
              .borderRadius(12)
          } else if (this.imageUri.length > 0) {
            Image(this.imageUri)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .borderRadius(12)
          } else {
            Column() {
              Image($r('app.media.ic_image'))
                .width(40)
                .height(40)
                .fillColor(Palette.TEXT_SECONDARY)
              Text('点击选择图片')
                .fontSize(14)
                .fontColor(Palette.TEXT_SECONDARY)
                .margin({ top: 10 })
            }
            .justifyContent(FlexAlign.Center)
          }

          if (this.processing) {
            Column() {
              LoadingProgress()
                .width(32)
                .height(32)
                .color(Palette.BRAND)
              Text(this.processingHint)
                .fontSize(12)
                .fontColor(Palette.TEXT_SECONDARY)
                .margin({ top: 10 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            // 半透明遮罩:既显示进度,也在视觉上表明这块区域不可点
            .backgroundColor('#D9FFFFFF')
            .borderRadius(12)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: 12 })
        .backgroundColor(Palette.SURFACE)
        .borderRadius(12)
        .onClick(() => {
          this.pickImage();
        })

        Text('抖动算法(预览即打印效果)')
          .fontSize(12)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 14, bottom: 8 })

        this.ditherSelector()

        Row() {
          Button('重新选择')
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontColor(Palette.BRAND)
            .backgroundColor(Palette.SURFACE)
            // 还没选过图就没有「重新」可言 —— 此时选图走上面那块预览区
            .opacity(this.busy() || !this.hasImage() ? 0.4 : 1)
            .enabled(!this.busy() && this.hasImage())
            .onClick(() => {
              this.pickImage();
            })

          Button(this.printing ? '打印中…' : '打印')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor(Palette.TEXT_ON_BRAND)
            .backgroundColor(
              this.busy() || !this.connected() || this.gray === null
                ? Palette.OFFLINE : Palette.BRAND)
            .enabled(!this.busy())
            .margin({ left: 12 })
            .onClick(() => {
              this.doPrint();
            })
        }
        .width('100%')
        .margin({ top: 14 })

        if (this.printing) {
          Row() {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Palette.BRAND)
            Text('正在发送数据并等待打印完成…')
              .fontSize(12)
              .fontColor(Palette.TEXT_SECONDARY)
              .margin({ left: 8 })
          }
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)
        }

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
    .title('图片打印')
    // 全屏沉浸下 NavDestination 不会自己避让,不垫这一下标题栏和返回键会缩进状态栏里点不到
    .padding({ top: this.safeArea.top })
    .backgroundColor(Palette.PAGE_BG)
  }
}
