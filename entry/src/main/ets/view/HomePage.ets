import { Metrics, Palette, Typo } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { QuickAction } from '../model/HomeModel';
import { getPrinterStatus, PrinterStatus } from '../model/PrinterStatus';
import { PrinterStatusCard } from './PrinterStatusCard';
import { QuickActionGrid } from './QuickActionGrid';

/**
 * 首页 —— 顶栏 + 打印机状态卡 + 快速打印宫格。
 * 底部导航条由 pages/Index.ets 用 Stack 叠在上层,这里只负责给内容留出底部空间。
 */
@ComponentV2
export struct HomePage {
  /** @ObservedV2 单例,@Trace 字段变化会驱动状态卡刷新 */
  private status: PrinterStatus = getPrinterStatus();
  /** 沉浸式下系统栏不再占位,顶栏要自己让开状态栏那一段 */
  private safeArea: SafeArea = getSafeArea();

  /** 点状态卡 → 由外层拉起设备选择半模态 */
  @Event onOpenDevicePicker: () => void = () => {};

  /** 点宫格卡片 → 由外层决定跳哪个页面(路由栈在 Index.ets 手里) */
  @Event onQuickAction: (action: QuickAction) => void = () => {};

  build() {
    Column() {
      // ── 顶栏 ──────────────────────────────────────────
      Row() {
        Stack() {
          Image($r('app.media.ic_printer'))
            .width(Metrics.BRAND_BADGE_ICON)
            .height(Metrics.BRAND_BADGE_ICON)
            .fillColor(Palette.TEXT_ON_BRAND)
        }
        .width(Metrics.BRAND_BADGE_SIZE)
        .height(Metrics.BRAND_BADGE_SIZE)
        .borderRadius(Metrics.BRAND_BADGE_RADIUS)
        .backgroundColor(Palette.BRAND)

        Column() {
          Text('错题小印')
            .fontSize(Typo.APP_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT_PRIMARY)
          Text('Qring Printer')
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

      // ── 可滚内容区 ────────────────────────────────────
      Scroll() {
        Column() {
          PrinterStatusCard({
            status: this.status,
            onTapCard: () => {
              this.onOpenDevicePicker();
            },
          })

          Text('快速打印')
            .fontSize(Typo.SECTION_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT_PRIMARY)
            .width('100%')
            .margin({ top: 24, bottom: 12 })

          QuickActionGrid({
            onSelect: (action: QuickAction) => {
              this.onQuickAction(action);
            },
          })
        }
        .width('100%')
        .padding({
          left: Metrics.PAGE_PADDING,
          right: Metrics.PAGE_PADDING,
          top: Metrics.PAGE_PADDING,
          // 给悬浮的底部导航条留出空间,否则最后一行卡片会被挡住
          bottom: Metrics.TAB_BAR_HEIGHT + this.safeArea.bottom + 24,
        })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.PAGE_BG)
  }
}
