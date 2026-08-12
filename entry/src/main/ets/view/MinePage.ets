import { common } from '@kit.AbilityKit';
import { CapsuleSegmentButtonV2, SegmentButtonV2Item, SegmentButtonV2Items } from '@kit.ArkUI';
import { Metrics, Palette, Typo } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { applyDisplayMode, DisplayMode, loadDisplayMode, saveDisplayMode } from '../model/DisplayMode';

/**
 * 「我的」页(底部 Tab)。
 *
 * 两个入口:
 *   显示模式 —— 白天/黑夜/跟随系统,三选一高亮。仅系统级:切到黑夜时系统组件
 *                 (状态栏/键盘/系统弹窗)变深色,app 自身页面保持浅色。
 *   关于     —— 显示版本信息。
 */

const APP_VERSION: string = '1.0.0';

@ComponentV2
export struct MinePage {
  @Local currentMode: DisplayMode = DisplayMode.FOLLOW;
  @Local loaded: boolean = false;
  /** 显示模式分段按钮的选项 */
  private segmentItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '跟随系统' },
    { text: '浅色' },
    { text: '深色' },
  ]);

  private safeArea: SafeArea = getSafeArea();

  aboutToAppear(): void {
    this.loadMode();
  }

  private loadMode(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    loadDisplayMode(ctx).then((mode: number) => {
      this.currentMode = mode as DisplayMode;
      this.loaded = true;
    }).catch(() => {
      this.loaded = true;
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Previewer 下可能不可用
    }
  }

  /** 切换显示模式:保存偏好 + 立即应用 */
  private selectMode(mode: DisplayMode): void {
    if (mode === this.currentMode) {
      return;
    }
    this.currentMode = mode;
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    saveDisplayMode(ctx, mode).then(() => {
      applyDisplayMode(ctx, mode);
    }).catch(() => {
      this.toast('保存失败');
    });
  }

  /** 关于:显示版本信息 */
  private showAbout(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '关于',
        message: `错题小印 Qring Printer\n版本 ${APP_VERSION} \n开发者：Thisko`,
        confirm: { value: '知道了', action: () => {} },
      });
    } catch (err) {
      this.toast(`版本 ${APP_VERSION}`);
    }
  }

  /** 滑块值 → 显示模式。0=跟随系统 1=浅色 2=深色 */
  private modeFromSlider(v: number): DisplayMode {
    if (v >= 2) {
      return DisplayMode.DARK;
    }
    if (v >= 1) {
      return DisplayMode.LIGHT;
    }
    return DisplayMode.FOLLOW;
  }

  private sliderFromMode(): number {
    if (this.currentMode === DisplayMode.DARK) {
      return 2;
    }
    if (this.currentMode === DisplayMode.LIGHT) {
      return 1;
    }
    return 0;
  }

  /** 一个设置行入口(关于) */
  @Builder
  aboutRow() {
    Row() {
      Column() {
        Text('关于')
          .fontSize(15)
          .fontColor(Palette.TEXT_PRIMARY)
        Text('版本信息')
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([Palette.TEXT_SECONDARY])
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Palette.SURFACE)
    .borderRadius(12)
    .margin({ top: 12 })
    .onClick(() => {
      this.showAbout();
    })
  }

  build() {
    Column() {
      // 标题区
      Row() {
        Column() {
          Text('我的')
            .fontSize(Typo.APP_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT_PRIMARY)
          Text('My Setting')
            .fontSize(Typo.APP_SUBTITLE)
            .fontColor(Palette.TEXT_SECONDARY)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        .layoutWeight(1)
      }
      .width('100%')
      // 顶栏整体下移一个状态栏的高度,白底顺势铺满状态栏区域
      .height(Metrics.TOP_BAR_HEIGHT + this.safeArea.top)
      .padding({
        left: Metrics.PAGE_PADDING,
        right: Metrics.PAGE_PADDING,
        top: this.safeArea.top,
      })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Palette.SURFACE)

      Scroll() {
        Column() {
          // 显示模式卡片
          Column() {
            Text('显示模式')
              .fontSize(13)
              .fontColor(Palette.TEXT_PRIMARY)
              .width('100%')
              .margin({ bottom: 10 })

            // 分段按钮:0=跟随系统 1=浅色 2=深色
            CapsuleSegmentButtonV2({
              items: this.segmentItems,
              selectedIndex: this.sliderFromMode(),
              $selectedIndex: (index: number) => {
                this.selectMode(this.modeFromSlider(index));
              },
            })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Palette.SURFACE)
          .borderRadius(12)
          .margin({ top: 10 })

          // 关于入口
          this.aboutRow()

          Text(`版本 ${APP_VERSION}`)
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 24 })
        }
        .width('100%')
        .padding({ left: Metrics.PAGE_PADDING, right: Metrics.PAGE_PADDING, bottom: Metrics.TAB_BAR_HEIGHT + this.safeArea.bottom + 16 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.PAGE_BG)
  }
}
