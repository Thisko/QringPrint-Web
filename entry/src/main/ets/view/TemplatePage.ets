import { common } from '@kit.AbilityKit';
import { Metrics, Palette, Typo } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import {
  deleteTemplate,
  loadTemplates,
  renameTemplate,
  TemplateRecord,
} from '../model/TemplateStore';

/** 时间戳 → 「yyyy-MM-dd HH:mm」。updatedAt 为 0 时(旧记录)显示「未知」 */
function formatDate(ts: number): string {
  if (ts <= 0) {
    return '未知';
  }
  const d: Date = new Date(ts);
  const pad: (n: number) => string = (n: number) => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * 模板页(底部「模板」Tab)。
 *
 * 列出所有已保存模板(名称 + 缩略图 + 保存/修改日期);点击进入编辑页(带 templateId);
 * **左滑**出「重命名」(蓝底白笔)和「删除」(红底白垃圾桶)。
 * 用 edgeEffect None 防止卡片被整个滑走。
 *
 * 刷新时机:
 *   aboutToAppear —— 首次进入 Tab
 *   refreshKey 变化 —— 从自定义打印页保存模板后切回本 Tab 时,由 Index 递增刷新
 *   内部改名/删除后 —— 直接调 refresh()
 */
@ComponentV2
@Entry
export struct TemplatePage {
  @Event onOpenTemplate: (templateId: string) => void = () => {};

  /** 由外层(Index)在切到本 Tab 时自增,触发重新加载 */
  @Param refreshKey: number = 0;
  @Monitor('refreshKey')
  onRefreshKey(): void {
    this.refresh();
  }

  @Local templates: TemplateRecord[] = [];
  @Local loading: boolean = true;
  @Local showRename: boolean = false;
  @Local renameTargetId: string = '';
  @Local renameName: string = '';
  /**
   * 列表版本号。每次刷新成功后自增,并进 ForEach key ——
   * ForEach 对 key 不变的行会复用旧实例,模板改名/修改后 id 和数量都不变,
   * 光更新数据不刷新 UI;版本号让 key 必然变化,强制重建。
   */
  @Local listVersion: number = 0;

  private safeArea: SafeArea = getSafeArea();

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.loading = true;
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    loadTemplates(ctx).then((list: TemplateRecord[]) => {
      this.templates = list;
      this.loading = false;
      this.listVersion++;
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

  private openRename(id: string, name: string): void {
    this.renameTargetId = id;
    this.renameName = name;
    this.showRename = true;
  }

  private confirmRename(): void {
    const name: string = this.renameName.trim();
    if (name.length === 0) {
      this.toast('请输入名称');
      return;
    }
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    renameTemplate(ctx, this.renameTargetId, name).then(() => {
      this.showRename = false;
      this.refresh();
    }).catch(() => {
      this.toast('重命名失败');
    });
  }

  private doDelete(id: string): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    deleteTemplate(ctx, id).then(() => {
      this.refresh();
    }).catch(() => {
      this.toast('删除失败');
    });
  }

  @Builder
  renameDialog() {
    Column() {
      TextInput({ placeholder: '输入模板名称', text: $$this.renameName })
        .width('100%')
        .height(48)
        .fontSize(15)
        .backgroundColor(Palette.SURFACE)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onSubmit(() => {
          this.confirmRename();
        })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(15)
          .fontColor(Palette.TEXT_PRIMARY)
          .backgroundColor(Palette.SURFACE)
          .onClick(() => {
            this.showRename = false;
          })

        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .fontColor(Palette.TEXT_ON_BRAND)
          .backgroundColor(Palette.BRAND)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirmRename();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(Metrics.PAGE_PADDING)
    .backgroundColor(Palette.PAGE_BG)
  }

  /** 行下标:0,2,4,…(两列排,每行从偶数下标开始) */
  private rowIndices(): number[] {
    const rows: number[] = [];
    for (let i = 0; i < this.templates.length; i += 2) {
      rows.push(i);
    }
    return rows;
  }

  /** 单张模板卡片:大缩略图 + 名称 + 日期。半屏宽,点击进编辑 */
  @Builder
  templateCard(t: TemplateRecord) {
    Column() {
      // 大缩略图,约半屏宽。白底衬在灰底上,有路径显示图片,没有显示占位
      Stack() {
        if (t.thumbnailPath.length > 0) {
          Image(t.thumbnailPath)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.None)
        } else {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(32)
            .fontColor([Palette.TEXT_SECONDARY])
        }
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius({ topLeft: 12, topRight: 12 })
      // clip 裁掉超出圆角的图像部分,否则缩略图会穿透圆角
      .clip(true)
      .backgroundColor(Palette.SURFACE_SUNKEN)
      .border({ width: 1, color: Palette.PAPER_EDGE })

      Column() {
        Text(t.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatDate(t.updatedAt))
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })

      // 重命名 / 删除,直接放在日期下面,不用滑动。每个按钮用 Stack 包图标使其居中
      Row({ space: 8 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.rename'))
            .fontSize(18)
            .fontColor([Palette.BRAND])
        }
        .layoutWeight(1)
        .height(32)
        .backgroundColor(Palette.SURFACE_SUNKEN)
        .borderRadius(8)
        .onClick(() => {
          this.openRename(t.id, t.name);
        })

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
          this.doDelete(t.id);
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 10 })
    }
    .layoutWeight(1)
    .backgroundColor(Palette.SURFACE)
    .borderRadius(12)

    .onClick(() => {
      this.onOpenTemplate(t.id);
    })
  }

  @Builder
  emptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(44)
        .fontColor([Palette.TEXT_SECONDARY])
      Text('还没有模板')
        .fontSize(15)
        .fontColor(Palette.TEXT_PRIMARY)
        .margin({ top: 12 })
      Text('在自定义打印里点「保存模板」即可保存')
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
          Text('我的模板')
            .fontSize(Typo.APP_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT_PRIMARY)
          Text('My Template')
            .fontSize(Typo.APP_SUBTITLE)
            .fontColor(Palette.TEXT_SECONDARY)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        .layoutWeight(1)
        Text(`${this.templates.length} 个`)
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
      } else if (this.templates.length === 0) {
        this.emptyState()
      } else {
        // 两列网格(x*2):每一行一个 ListItem,内含左右两张模板卡片。
        List({ space: 12 }) {
          ForEach(this.rowIndices(), (rowIdx: number) => {
            ListItem() {
              Row({ space: 12 }) {
                this.templateCard(this.templates[rowIdx])
                if (rowIdx + 1 < this.templates.length) {
                  this.templateCard(this.templates[rowIdx + 1])
                } else {
                  // 奇数个时,右边留白,保持卡片宽度一致
                  Column().layoutWeight(1)
                }
              }
              .width('100%')
            }
          }, (rowIdx: number) => `row_${rowIdx}_${this.listVersion}`)
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
    // 从编辑页返回模板 Tab 时,内容重新可见 → 刷新。
    // 这是「在模板页点卡片进编辑 → 返回」的核心场景,onPop/onPageShow 在 V2 下不可靠。
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number) => {
      if (isVisible) {
        this.refresh();
      }
    })
    .bindSheet(this.showRename, this.renameDialog(), {
      height: SheetSize.MEDIUM,
      preferType: SheetType.BOTTOM,
      title: { title: '重命名模板' },
      backgroundColor: Palette.PAGE_BG,
      // $$ 双向绑定在 V2 下不可靠,改单向绑定 + 关闭时回置
      onDisappear: () => {
        this.showRename = false;
      },
    })
  }
}
