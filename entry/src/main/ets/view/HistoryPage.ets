import { common } from '@kit.AbilityKit';
import { Metrics, Palette, Typo } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { deleteHistory, HistoryRecord, loadHistory } from '../model/HistoryStore';

/** 时间戳 → 「yyyy-MM-dd HH:mm」。printedAt 为 0 时显示「未知」 */
function formatDate(ts: number): string {
  if (ts <= 0) {
    return '未知';
  }
  const d: Date = new Date(ts);
  const pad: (n: number) => string = (n: number) => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * 历史打印页(底部「历史」Tab)。
 *
 * 复用模板页的两列网格布局:缩略图 + 名称 + 时间。但没有重命名、没有点击进编辑,
 * 每张卡片底部只有一个「删除」按钮。删除后本地 refresh() 刷新。
 */
@ComponentV2
export struct HistoryPage {
  /** 由外层(Index)在切到本 Tab 时自增,触发重新加载 */
  @Param refreshKey: number = 0;
  @Monitor('refreshKey')
  onRefreshKey(): void {
    this.refresh();
  }

  /** 点记录重新打印:由 Index 决定跳哪个打印页 */
  @Event onReopen: (rec: HistoryRecord) => void = () => {};

  @Local records: HistoryRecord[] = [];
  @Local loading: boolean = true;

  private safeArea: SafeArea = getSafeArea();

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.loading = true;
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    loadHistory(ctx).then((list: HistoryRecord[]) => {
      this.records = list;
      this.loading = false;
    }).catch(() => {
      this.loading = false;
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Previewer 下可能不可用
    }
  }

  private doDelete(id: string): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    deleteHistory(ctx, id).then(() => {
      this.refresh();
    }).catch(() => {
      this.toast('删除失败');
    });
  }

  /** 行下标:0,2,4,…(两列排,每行从偶数下标开始) */
  private rowIndices(): number[] {
    const rows: number[] = [];
    for (let i = 0; i < this.records.length; i += 2) {
      rows.push(i);
    }
    return rows;
  }

  /** 单张历史卡片:缩略图 + 名称 + 时间 + 删除按钮。点卡片重新打印 */
  @Builder
  historyCard(r: HistoryRecord) {
    Column() {
      // 缩略图。白底衬在灰底上,有路径显示图片,没有显示占位
      Stack() {
        if (r.thumbnailPath.length > 0) {
          Image(r.thumbnailPath)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.None)
        } else {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(32)
            .fontColor([Palette.TEXT_SECONDARY])
        }
        // 缩略图上的「重新打印」提示
        Column() {
          Text('点此重新打印')
            .fontSize(10)
            .fontColor(Palette.TEXT_ON_BRAND)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('#66000000')
            .borderRadius(8)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius({ topLeft: 12, topRight: 12 })
      // clip 裁掉超出圆角的图像部分,否则缩略图会穿透圆角
      .clip(true)
      .backgroundColor(Palette.SURFACE_SUNKEN)
      .border({ width: 1, color: Palette.PAPER_EDGE })

      Column() {
        Text(r.typeName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatDate(r.printedAt))
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })

      // 只有删除按钮,没有重命名
      Row({ space: 8 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(18)
            .fontColor([Palette.DANGER])
        }
        .layoutWeight(1)
        .height(32)
        .backgroundColor(Palette.SURFACE_SUNKEN)
        .borderRadius(8)
        .onClick(() => {
          this.doDelete(r.id);
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 10 })
    }
    .layoutWeight(1)
    .backgroundColor(Palette.SURFACE)
    .borderRadius(12)
    .onClick(() => {
      this.onReopen(r);
    })
  }

  @Builder
  emptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(44)
        .fontColor([Palette.TEXT_SECONDARY])
      Text('还没有打印记录')
        .fontSize(15)
        .fontColor(Palette.TEXT_PRIMARY)
        .margin({ top: 12 })
      Text('打印成功后会自动记录在这里')
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      // 标题区
      Row() {
        Column() {
          Text('打印历史')
            .fontSize(Typo.APP_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT_PRIMARY)
          Text('History Print')
            .fontSize(Typo.APP_SUBTITLE)
            .fontColor(Palette.TEXT_SECONDARY)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        .layoutWeight(1)
        Text(`${this.records.length} 条`)
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
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

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Palette.BRAND)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.records.length === 0) {
        this.emptyState()
      } else {
        // 两列网格(x*2):每一行一个 ListItem,内含左右两张卡片
        List({ space: 12 }) {
          ForEach(this.rowIndices(), (rowIdx: number) => {
            ListItem() {
              Row({ space: 12 }) {
                this.historyCard(this.records[rowIdx])
                if (rowIdx + 1 < this.records.length) {
                  this.historyCard(this.records[rowIdx + 1])
                } else {
                  // 奇数个时,右边留白,保持卡片宽度一致
                  Column().layoutWeight(1)
                }
              }
              .width('100%')
            }
          }, (rowIdx: number) => `hist_${rowIdx}_${this.records.length}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: Metrics.PAGE_PADDING, right: Metrics.PAGE_PADDING, top: 4, bottom: Metrics.TAB_BAR_HEIGHT + this.safeArea.bottom + 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.PAGE_BG)
    // 从打印页返回历史 Tab 时内容重新可见 → 刷新
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number) => {
      if (isVisible) {
        this.refresh();
      }
    })
  }
}
