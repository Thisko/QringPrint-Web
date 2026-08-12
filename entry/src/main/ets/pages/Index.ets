import { common } from '@kit.AbilityKit';
import { PrinterConnection } from '../bluetooth/PrinterConnection';
import { Metrics, Palette, Typo } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { QuickAction, TAB_ITEMS, TabItem } from '../model/HomeModel';
import { CodePrintPage } from '../view/CodePrintPage';
import { CustomPrintPage } from '../view/CustomPrintPage';
import { DevicePickerSheet } from '../view/DevicePickerSheet';
import { HistoryPage } from '../view/HistoryPage';
import { HIST_TYPE_TEXT, HIST_TYPE_IMAGE, HIST_TYPE_CODE, HIST_TYPE_CUSTOM, HistoryRecord } from '../model/HistoryStore';
import { getThemeState, ThemeState } from '../model/DisplayMode';
import { HomePage } from '../view/HomePage';
import { ImagePrintPage } from '../view/ImagePrintPage';
import { MinePage } from '../view/MinePage';
import { TemplatePage } from '../view/TemplatePage';
import { TextPrintPage } from '../view/TextPrintPage';

/** 路由名常量,避免各处手写字符串写错 */
const ROUTE_TEXT_PRINT: string = 'TextPrint';
const ROUTE_IMAGE_PRINT: string = 'ImagePrint';
const ROUTE_CODE_PRINT: string = 'CodePrint';
const ROUTE_CUSTOM_PRINT: string = 'CustomPrint';

/** 底部「模板」Tab 的下标 */
const TAB_TEMPLATE_INDEX: number = 1;

/**
 * 路由表。
 * ArkTS 要求 navDestination 接收**顶层 @Builder 函数引用**,
 * 传内联 lambda 会编译不过。
 *
 * 模板 id 不走 navDestination 的 param(ArkTS 禁 unknown,SDK 签名又是 unknown),
 * 改用 AppStorage 传,由 CustomPrintPage 在 aboutToAppear 里取用。
 */
@Builder
function PageMap(name: string) {
  if (name === ROUTE_TEXT_PRINT) {
    TextPrintPage()
  } else if (name === ROUTE_IMAGE_PRINT) {
    ImagePrintPage()
  } else if (name === ROUTE_CODE_PRINT) {
    CodePrintPage()
  } else if (name === ROUTE_CUSTOM_PRINT) {
    CustomPrintPage()
  }
}

/**
 * 模板 / 历史 / 我的 三个 Tab 的占位页,
 * 目的是让底部四个 Tab 真实可切换,而不是画一个死的导航条。
 */
@ComponentV2
struct PlaceholderPage {
  @Param title: string = '';

  build() {
    Column() {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text('敬请期待')
        .fontSize(14)
        .fontColor(Palette.TEXT_SECONDARY)
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Palette.PAGE_BG)
  }
}

/**
 * 应用外壳。
 *
 * 外层是 Navigation —— 打印子页作为 NavDestination 推进来时会盖住整屏(含底部导航条),
 * 这是子页该有的行为。用 Navigation 而不是 router,是因为 router 已在被逐步淘汰。
 *
 * 内层参考图的底部导航是「圆角浮起的白色条」,而 Tabs 自带的 bar 没法直接设圆角,
 * 所以用 barHeight(0) 收起原生 bar,自绘导航条叠在 Stack 上层,
 * 靠 TabsController.changeIndex() 切页。
 */
@Entry
@ComponentV2
struct Index {
  @Local currentIndex: number = 0;
  @Local showDevicePicker: boolean = false;
  /** 每次切到模板 Tab 自增,驱动 TemplatePage 重新加载 */
  @Local templateRefresh: number = 0;
  /** 上次切到模板 Tab 时的全局模板版本。变化则重建模板页 */
  @Local lastTemplatesRevision: number = 0;
  /**
   * 主题状态。@Trace isDark 变化时,Index build 里对 this.theme.isDark 的引用
   * 触发 Index 重渲 → 重建整个 Tabs → 子页 build 重跑 → Palette getter 换色。
   */
  @Local theme: ThemeState = getThemeState();

  private pathStack: NavPathStack = new NavPathStack();
  private controller: TabsController = new TabsController();
  private printer: PrinterConnection = PrinterConnection.getInstance();
  /** 沉浸式下底部手势条不再占位,导航条要自己垫高 */
  private safeArea: SafeArea = getSafeArea();

  aboutToAppear(): void {
    // 蓝牙能力在 Previewer 里不存在,PrinterConnection 内部已全量 try/catch,
    // 这里正常调用即可,不会把预览搞白屏。
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.printer.init(context);
    this.printer.autoReconnect();
  }

  onPageShow(): void {
    this.printer.onForeground();
    // 从打印子页返回时刷新模板列表 —— 用户可能刚保存/修改了模板。
    // select() 只在切 Tab 时触发,返回同一 Tab 不会走到那。
    this.templateRefresh++;
  }

  onPageHide(): void {
    // 切后台停掉状态轮询,别在后台每 10s 发一轮查询
    this.printer.onBackground();
  }

  private select(index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    this.currentIndex = index;
    this.controller.changeIndex(index);
    // 切到模板 Tab 时,检查全局模板版本是否变化(CustomPrintPage 返回时递增)。
    // 变了就重建模板页 → aboutToAppear 刷新。命令式比较,不依赖任何响应式装饰器。
    if (index === TAB_TEMPLATE_INDEX) {
      this.templateRefresh++;
      const rev: number = AppStorage.get<number>('templatesRevision') ?? 0;
      if (rev !== this.lastTemplatesRevision) {
        this.lastTemplatesRevision = rev;
        this.templateRefresh++;
      }
    }
  }

  /** 历史记录点击 → 跳对应打印页重新打印。payload 放 AppStorage,打印页 aboutToAppear 读取 */
  private reopenHistory(rec: HistoryRecord): void {
    AppStorage.setOrCreate('historyPayload', rec.payload);
    if (rec.typeName === HIST_TYPE_TEXT) {
      this.pathStack.pushPath({ name: ROUTE_TEXT_PRINT });
    } else if (rec.typeName === HIST_TYPE_IMAGE) {
      this.pathStack.pushPath({ name: ROUTE_IMAGE_PRINT });
    } else if (rec.typeName === HIST_TYPE_CODE) {
      this.pathStack.pushPath({ name: ROUTE_CODE_PRINT });
    } else if (rec.typeName === HIST_TYPE_CUSTOM) {
      this.pathStack.pushPath({ name: ROUTE_CUSTOM_PRINT });
    }
  }

  private handleQuickAction(action: QuickAction): void {
    if (action.key === 'txt') {
      this.pathStack.pushPath({ name: ROUTE_TEXT_PRINT });
    } else if (action.key === 'image') {
      this.pathStack.pushPath({ name: ROUTE_IMAGE_PRINT });
    } else if (action.key === 'qrcode') {
      this.pathStack.pushPath({ name: ROUTE_CODE_PRINT });
    } else if (action.key === 'custom') {
      // 从首页进自定义打印,保存模板后返回也要刷新模板列表。
      // 不带 onPop 的话,返回时不触发刷新,模板页列表还是旧的。
      this.pathStack.pushPathByName(ROUTE_CUSTOM_PRINT, '', () => {
        this.templateRefresh++;
      });
    } else {
      // showToast 会抛(Previewer 下尤其),这里跟 CodePrintPage.toast() 保持一致包一层
      try {
        this.getUIContext().getPromptAction().showToast({
          message: `${action.title} 功能开发中`,
          duration: 2000,
        });
      } catch (err) {
        // 提示失败不影响主流程,忽略即可
      }
    }
  }

  @Builder
  devicePicker() {
    DevicePickerSheet({
      onFinished: () => {
        this.showDevicePicker = false;
      },
    })
  }

  @Builder
  bottomTabBar() {
    Row() {
      ForEach(TAB_ITEMS, (item: TabItem, index: number) => {
        Column() {
          Image(item.icon)
            .width(Metrics.TAB_ICON)
            .height(Metrics.TAB_ICON)
            .fillColor(this.currentIndex === index ? Palette.BRAND : Palette.TEXT_SECONDARY)
          Text(item.label)
            .fontSize(Typo.TAB_LABEL)
            .fontColor(this.currentIndex === index ? Palette.BRAND : Palette.TEXT_SECONDARY)
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.select(index);
        })
      }, (item: TabItem) => item.key)
    }
    .width('100%')
    // 白底延伸到手势条下方,图标本身靠 padding 抬上来
    .height(Metrics.TAB_BAR_HEIGHT + this.safeArea.bottom)
    .padding({ bottom: this.safeArea.bottom })
    .backgroundColor(Palette.SURFACE)
    .borderRadius({
      topLeft: Metrics.TAB_BAR_RADIUS,
      topRight: Metrics.TAB_BAR_RADIUS,
    })
    .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: -2 })
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
          TabContent() {
            HomePage({
              onOpenDevicePicker: () => {
                this.showDevicePicker = true;
              },
              onQuickAction: (action: QuickAction) => {
                this.handleQuickAction(action);
              },
            })
          }

          TabContent() {
            // onPop 返回时 templateRefresh++ → 条件翻转 → 旧 TemplatePage 销毁、新实例创建
            // → aboutToAppear 必然重新 refresh()。比 @Monitor 监听 refreshKey 可靠,
            // 画布内容显示就靠这个 if/else 强制重建技巧解决的(绕开 V2 响应式不可靠)。
            // templateRefresh 变化 → if/else 翻转 → 模板页重建 → aboutToAppear 刷新
            if (this.templateRefresh % 2 === 0) {
              TemplatePage({
                refreshKey: this.templateRefresh,
                onOpenTemplate: (templateId: string) => {
                  AppStorage.setOrCreate('openTemplateId', templateId);
                  this.pathStack.pushPathByName(ROUTE_CUSTOM_PRINT, '', () => {});
                },
              })
            } else {
              TemplatePage({
                refreshKey: this.templateRefresh,
                onOpenTemplate: (templateId: string) => {
                  AppStorage.setOrCreate('openTemplateId', templateId);
                  this.pathStack.pushPathByName(ROUTE_CUSTOM_PRINT, '', () => {});
                },
              })
            }
          }

          TabContent() {
            // 历史页自身用 onVisibleAreaChange 在重新可见时刷新(和模板页一致)
            HistoryPage({
              refreshKey: this.templateRefresh,
              onReopen: (rec: HistoryRecord) => {
                this.reopenHistory(rec);
              },
            })
          }

          TabContent() {
            MinePage()
          }
        }
        // 收起原生 bar,改用下面自绘的圆角导航条
        .barHeight(0)
        .scrollable(true)
        .animationDuration(0)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.currentIndex = index;
        })

        this.bottomTabBar()
      }
      .width('100%')
      .height('100%')
      // 引用 this.theme.isDark 建立对 ThemeState 的订阅 —— @Trace 变化时本组件重渲,
      // 重建整个 Tabs,Palette getter 随之换色
      .opacity(this.theme.isDark ? 1 : 1)
      .backgroundColor(Palette.PAGE_BG)
      .bindSheet(this.showDevicePicker, this.devicePicker(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        title: { title: '选择打印机' },
        backgroundColor: Palette.SURFACE,
        // 单向绑定 + onDisappear 回置:用户下滑关闭时 ArkUI 会自己收起,
        // 这里把标志位复位,否则下次点卡片打不开。
        onDisappear: () => {
          this.showDevicePicker = false;
        },
      })
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(PageMap)
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.PAGE_BG)
  }
}
