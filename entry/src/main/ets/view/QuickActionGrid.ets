import { Metrics, Palette, Typo } from '../common/Theme';
import { QUICK_ACTIONS, QuickAction, quickActionGridHeight } from '../model/HomeModel';

/**
 * 快速打印 2×2 宫格。
 *
 * Grid 嵌在 Scroll 里必须给显式高度 —— 否则子项会一次性全量加载,或者高度直接塌陷成 0。
 * 高度由 quickActionGridHeight() 从数据长度算出,增删卡片不用手改。
 */
@ComponentV2
export struct QuickActionGrid {
  @Event onSelect: (action: QuickAction) => void = () => {};

  build() {
    Grid() {
      ForEach(QUICK_ACTIONS, (item: QuickAction) => {
        GridItem() {
          Column() {
            Stack() {
              Image(item.icon)
                .width(Metrics.TILE_ICON)
                .height(Metrics.TILE_ICON)
                // 13 个 SVG 都是硬编码 #FFFFFF 的单色图标,靠 fillColor 在不同底色上复用
                .fillColor(Palette.TILE_ICON)
            }
            .width(Metrics.TILE_SIZE)
            .height(Metrics.TILE_SIZE)
            .borderRadius(Metrics.TILE_RADIUS)
            .backgroundColor(item.tileColor)

            Text(item.title)
              .fontSize(Typo.ACTION_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT_TITLE)
              .margin({ top: 12 })

            Text(item.subtitle)
              .fontSize(Typo.ACTION_SUBTITLE)
              .fontColor(Palette.TEXT_SECONDARY)
              .margin({ top: 4 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .borderRadius(Metrics.ACTION_CARD_RADIUS)
          .stateStyles({
            normal: {
              .backgroundColor(Palette.SURFACE)
            },
            pressed: {
              .backgroundColor(Palette.PRESSED)
            },
          })
          .onClick(() => {
            this.onSelect(item);
          })
        }
        .height(Metrics.ACTION_CARD_HEIGHT)
      }, (item: QuickAction) => item.key)
    }
    .columnsTemplate('1fr 1fr')
    .rowsGap(Metrics.GRID_GAP)
    .columnsGap(Metrics.GRID_GAP)
    .width('100%')
    .height(quickActionGridHeight())
  }
}
