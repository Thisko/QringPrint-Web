import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Metrics, Palette } from '../common/Theme';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { docToTemplateData, findTemplate, saveTemplate, templateToElements, TemplateElementData, TemplateRecord } from '../model/TemplateStore';
import { PrintResult, PrinterConnection } from '../bluetooth/PrinterConnection';
import { packBinaryToRaster, RasterData } from '../bluetooth/RasterEncoder';
import { WIDTH_DOTS } from '../bluetooth/QringProtocol';
import {
  CanvasComposite,
  composeCanvas,
  DEFAULT_CODE_2D_SIZE,
  DEFAULT_IMAGE_WIDTH,
  renderElementNow,
} from '../common/ElementRender';
import { DEFAULT_TEXT_OPTIONS } from '../bluetooth/RasterEncoder';
import {
  CanvasDoc,
  CanvasElement,
  centeredX,
  ElementKind,
  MIN_LENGTH_CEIL,
  MIN_LENGTH_FLOOR,
  nextInsertY,
} from '../model/CanvasModel';
import { CodeCategory, CODE_TYPES } from '../model/BarcodeModel';
import { ConnState, getPrinterStatus, PrinterStatus } from '../model/PrinterStatus';
import { GrayImage } from '../bluetooth/Dither';
import { addHistoryGray, HIST_TYPE_CUSTOM } from '../model/HistoryStore';
import { CanvasElementView } from './CanvasElementView';
import { ElementEditSheet } from './ElementEditSheets';

const DOMAIN: number = 0x0001;
const TAG: string = 'CustomPrintPage';

/** 画布在屏幕上的显示宽度(vp)。384 点按这个宽度等比显示 */
const CANVAS_DISPLAY_WIDTH: number = 320;

function describeError(err: object): string {
  const business: BusinessError = err as BusinessError;
  const message: string = business.message !== undefined && business.message.length > 0
    ? business.message : JSON.stringify(err);
  const code: string = business.code !== undefined ? ` (code ${business.code})` : '';
  return `${message}${code}`;
}

/**
 * 自定义打印 —— 画布编辑器。
 *
 * 坐标系:模型里一切都是**打印点**,画布固定 384 点宽(等于打印头点数),
 * 屏幕上乘 DISPLAY_SCALE 显示。这样合成时零换算,拖拽只需把 vp 位移除以缩放比。
 *
 * 合成策略:每个元素**各自二值化**后再 OR 合并到一张 384×H 的二值画布,
 * 而不是先拼灰度再统一二值化 —— 图片要 Floyd、文字要阈值 212、条码要阈值 128 且不能抖动,
 * 拍平会同时毁掉其中两类。详见 ElementRender.ts 的注释。
 */
@ComponentV2
@Entry
export struct CustomPrintPage {
  @Local doc: CanvasDoc = new CanvasDoc();
  /** 从模板页打开时加载的模板 id,空串表示新画布 */
  @Local currentTemplateId: string = '';
  /** 从模板打开时记录的模板名,保存弹窗默认填入 */
  @Local currentTemplateName: string = '';
  @Local showEditor: boolean = false;
  @Monitor('showEditor')
  onShowEditorChange(): void {
    hilog.info(DOMAIN, TAG, 'showEditor -> %{public}s', this.showEditor ? 'true' : 'false');
  }
  @Local dragging: boolean = false;
  @Local busy: boolean = false;
  @Local busyHint: string = '';
  @Local printing: boolean = false;
  @Local resultMessage: string = '';
  @Local resultOk: boolean = false;
  /** 元素几何变化后自增,用来驱动画布高度等派生显示重新计算 */
  @Local revision: number = 0;
  /** 渲染进度阶段,诊断用:排查 rerender 卡在哪个 await */
  @Local renderStage: string = '就绪';
  /** 模板命名弹窗是否显示 */
  @Local showTemplateDialog: boolean = false;
  /** 模板名输入 */
  @Local templateName: string = '';

  private status: PrinterStatus = getPrinterStatus();
  private safeArea: SafeArea = getSafeArea();
  private printer: PrinterConnection = PrinterConnection.getInstance();

  aboutToAppear(): void {
    // 从模板页打开时,Index 把模板 id 放进了 AppStorage;取出来加载并消费掉。
    // 不用 navDestination 的 param —— ArkTS 禁 unknown,SDK 回调签名又是 unknown。
    const pending: string | undefined = AppStorage.get<string>('openTemplateId');
    if (pending !== undefined && pending.length > 0) {
      AppStorage.setOrCreate('openTemplateId', '');
      this.currentTemplateId = pending;
      this.loadTemplate();
      return;
    }
    // 从历史记录重新打印:payload 存了 CanvasDoc 快照(elements + minLength)
    const histPayload: string | undefined = AppStorage.get<string>('historyPayload');
    if (histPayload !== undefined && histPayload.length > 0) {
      AppStorage.setOrCreate('historyPayload', '');
      this.restoreFromHistory(histPayload);
    }
  }

  /** 从历史快照恢复整个画布 */
  private restoreFromHistory(payload: string): void {
    try {
      // payload 是 JSON.stringify({elements: TemplateElementData[], minLength}) 的结果,
      // elements 字段已经是解析后的数组对象,直接取用,不能 String() 后二次 JSON.parse
      const parsed: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      const minLength: number = Number(parsed['minLength'] ?? 200);
      const rawEls: Object = parsed['elements'] as Object;
      const elements: TemplateElementData[] = rawEls as TemplateElementData[];
      if (elements.length === 0) {
        return;
      }
      this.doc.releaseAll();
      // 重建元素并渲染
      this.doc.elements = elements.map((d: TemplateElementData) => this.rebuildElement(d));
      this.doc.minLength = minLength;
      this.bump();
      for (const el of this.doc.elements) {
        this.runRender(el);
      }
    } catch (err) {
      // 解析失败则保持空画布
    }
  }

  /** 从模板元素数据重建 CanvasElement。复用 templateToElements 的逻辑,但只对单条 */
  private rebuildElement(d: TemplateElementData): CanvasElement {
    // templateToElements 接受 TemplateRecord,构造一个临时 record
    const rec: TemplateRecord = {
      id: 'hist', name: '', minLength: 0, updatedAt: 0, thumbnailPath: '',
      elements: [d],
    };
    return templateToElements(rec)[0];
  }

  aboutToDisappear(): void {
    // 每个元素都持有原生位图,漏一个就是一份泄漏
    this.doc.releaseAll();
    // 返回时通知模板页刷新。递增全局计数,Index 用 @StorageLink 监听并重建模板 Tab。
    // 不依赖 onPop/onPageShow(那些在 V2 下触发不可靠),aboutToDisappear 销毁必然触发。
    const n: number = AppStorage.get<number>('templatesRevision') ?? 0;
    AppStorage.setOrCreate('templatesRevision', n + 1);
  }

  /**
   * 加载模板填充画布。
   *
   * 用 .then/.catch 链而不是 async/await —— 组件私有 async 方法 + await this.xxx()
   * 之前真机上会卡死,这里全部走模块级函数和 Promise 链。
   * 加载后逐元素渲染(图片需重新解码、条码重新生成、文字重新排版)。
   */
  private loadTemplate(): void {
    this.busy = true;
    this.busyHint = '正在加载模板…';
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    findTemplate(ctx, this.currentTemplateId).then((rec: TemplateRecord | undefined) => {
      if (rec === undefined) {
        this.toast('模板不存在');
        this.busy = false;
        return;
      }
      this.doc.releaseAll();
      this.doc.elements = templateToElements(rec);
      this.doc.minLength = rec.minLength;
      this.currentTemplateName = rec.name;
      this.bump();
      for (const el of this.doc.elements) {
        this.runRender(el);
      }
      this.busy = false;
    }).catch(() => {
      this.toast('加载模板失败');
      this.busy = false;
    });
  }

  private dotScale(): number {
    return CANVAS_DISPLAY_WIDTH / WIDTH_DOTS;
  }

  private selectedEl(): CanvasElement | undefined {
    return this.doc.selected();
  }

  private connected(): boolean {
    return this.status.connState === ConnState.CONNECTED;
  }

  private locked(): boolean {
    return this.busy || this.printing;
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
        confirm: { value: '知道了', action: () => {} },
      });
    } catch (err) {
      this.toast(message);
    }
  }

  private bump(): void {
    this.revision++;
    // 重新赋一遍数组,逼 ForEach 重新求值。内容显示已改成父组件直接观察 el.preview,
    // 这里再多一层保险:某些机型上 ForEach 缓存复用会跳过 item 重建,重赋数组能兜住。
    this.doc.elements = [...this.doc.elements];
    this.resultMessage = '';
  }

  // ── 渲染 ──────────────────────────────────────────────

  /**
   * 触发单个元素渲染。**不用 await,用 .then/.catch 链**。
   *
   * 之前是组件里的 private async rerender + `await this.rerender(el)`,
   * 真机上会卡死在 await、后续代码不执行(调试显示一直停在「rerender 前」)。
   * 渲染逻辑已抽到模块级 renderElementNow(不依赖组件 this),
   * 这里只负责接结果:成功 → bump() 驱动画布重建;失败 → 红字显示。
   */
  private runRender(el: CanvasElement, onDone?: () => void): void {
    this.renderStage = '渲染中';
    renderElementNow(el, (s: string) => {
      this.renderStage = s;
    }).then(() => {
      this.bump();
      this.renderStage = '完成';
      if (onDone !== undefined) {
        onDone();
      }
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'render element failed: %{public}s', JSON.stringify(err));
      this.resultOk = false;
      this.resultMessage = `元素渲染失败:${describeError(err as object)}`;
      this.renderStage = '出错';
      if (onDone !== undefined) {
        onDone();
      }
    });
  }

  /**
   * 手柄拖动过程中的实时重渲染。
   *
   * 刻意**不 bump**:bump 会重建 ForEach、销毁当前 CanvasElementView,
   * 正在拖的手势会被打断。这里只更新 el.preview / 几何(@Trace,父组件直接观察),
   * 内容即时刷新;松手后 onCommit → runRender → bump 兜底一次完整重建。
   */
  private renderLive(el: CanvasElement): void {
    renderElementNow(el).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'live render failed: %{public}s', JSON.stringify(err));
    });
  }

  // ── 插入 ──────────────────────────────────────────────

  private insertText(): void {
    if (this.locked()) {
      return;
    }
    const el: CanvasElement = new CanvasElement(ElementKind.TEXT);
    el.text = '双击编辑文字';
    el.textOptions = DEFAULT_TEXT_OPTIONS;
    // dotW = 0 表示 auto:渲染时按内容自然宽度排版,不占满整幅宽。
    // 先给个占位高度:渲染完成前高度为 0 的话,元素框是 0 高,既看不见也点不中。
    el.dotH = DEFAULT_TEXT_OPTIONS.fontSize + DEFAULT_TEXT_OPTIONS.margin * 2;
    el.dotX = 0;
    el.dotY = nextInsertY(this.doc);
    this.doc.add(el);
    this.runRender(el);
  }

  private async insertImage(): Promise<void> {
    if (this.locked()) {
      return;
    }
    let uri: string = '';
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const selected: photoAccessHelper.PhotoSelectResult = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (selected.photoUris.length === 0) {
        return;
      }
      uri = selected.photoUris[0];
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'photo picker failed: %{public}s', JSON.stringify(err));
      this.toast('打开相册失败');
      return;
    }

    this.busy = true;
    this.busyHint = '正在解码图片…';
    const el: CanvasElement = new CanvasElement(ElementKind.IMAGE);
    el.imageUri = uri;
    // 先给占位几何,框立刻可见;解码完成后 renderElementNow 按真实比例重设
    el.dotW = DEFAULT_IMAGE_WIDTH;
    el.dotH = DEFAULT_IMAGE_WIDTH;
    el.aspect = 1;
    el.dotX = centeredX(el.dotW);
    el.dotY = nextInsertY(this.doc);
    this.doc.add(el);
    this.runRender(el, () => {
      this.busy = false;
    });
  }

  private async insertCode(): Promise<void> {
    if (this.locked()) {
      return;
    }
    this.busy = true;
    this.busyHint = '正在生成条码…';
    const el: CanvasElement = new CanvasElement(ElementKind.CODE);
    // 默认插二维码,内容给一个能立刻看到效果的示例
    const qrIndex: number = CODE_TYPES.findIndex(
      (t: import('../model/BarcodeModel').CodeType) => t.category === CodeCategory.TWO_D);
    el.codeTypeIndex = qrIndex >= 0 ? qrIndex : 0;
    el.codeContent = 'https://example.com';
    el.dotW = DEFAULT_CODE_2D_SIZE;
    el.dotH = DEFAULT_CODE_2D_SIZE;
    el.aspect = 1;
    el.dotX = centeredX(el.dotW);
    el.dotY = nextInsertY(this.doc);
    this.doc.add(el);
    this.runRender(el, () => {
      this.busy = false;
    });
  }

  /**
   * 编辑器里改了元素内容后回调。
   * 条码换类别时的大小由 ElementEditSheet.applyCodeShape 设置好,这里只负责重渲染。
   */
  private onElementChanged(): void {
    const el: CanvasElement | undefined = this.doc.selected();
    if (el === undefined) {
      return;
    }
    this.runRender(el);
  }

  // ── 保存模板 / 打印 ───────────────────────────────────

  /** 深克隆一个元素,插到原元素下方。复制品共享 sourceGray(它是解码缓存,不占原生内存) */
  private copyElement(src: CanvasElement): void {
    if (this.locked()) {
      return;
    }
    const clone: CanvasElement = new CanvasElement(src.kind);
    // 几何
    clone.dotX = Math.max(0, src.dotX + 8);
    clone.dotY = src.dotY + src.dotH + 8;
    clone.dotW = src.dotW;
    clone.dotH = src.dotH;
    clone.aspect = src.aspect;
    // 克隆已有明确几何,图片渲染时不得按真实比例重设
    clone.geometryLocked = true;
    // 文字
    clone.text = src.text;
    clone.textOptions = {
      fontFamily: src.textOptions.fontFamily,
      fontSize: src.textOptions.fontSize,
      bold: src.textOptions.bold,
      italic: src.textOptions.italic,
      underline: src.textOptions.underline,
      letterSpacing: src.textOptions.letterSpacing,
      lineSpacing: src.textOptions.lineSpacing,
      margin: src.textOptions.margin,
    };
    // 图片 —— 灰度缓存是纯数据,引用共享即可,不用深拷贝
    clone.imageUri = src.imageUri;
    clone.ditherMode = src.ditherMode;
    clone.sourceGray = src.sourceGray;
    // 条码
    clone.codeContent = src.codeContent;
    clone.codeTypeIndex = src.codeTypeIndex;
    // 渲染
    this.doc.add(clone);
    this.runRender(clone);
  }

  /** 打开模板命名弹窗。从模板进入时默认填当前模板名 */
  private saveTemplate(): void {
    if (this.locked()) {
      return;
    }
    if (this.doc.elements.length === 0) {
      this.toast('画布是空的,先插入点内容');
      return;
    }
    // 先把元素编辑弹窗收掉 —— 若它还开着,保存弹窗会叠在它后面
    this.showEditor = false;
    this.templateName = this.currentTemplateName;
    this.showTemplateDialog = true;
  }

  /**
   * 确认保存模板 → 落盘到 preferences。
   * 从模板页打开时 currentTemplateId 非空,保存 = 覆盖该模板;新画布 = 新建。
   */
  private confirmSaveTemplate(): void {
    this.doSave(false);
  }

  /**
   * 另存为 → 总是新建一个模板,不复盖当前模板。
   * 清掉 currentTemplateId,再走保存。
   */
  private confirmSaveAs(): void {
    this.doSave(true);
  }

  private doSave(asNew: boolean): void {
    const name: string = this.templateName.trim();
    if (name.length === 0) {
      this.toast('请输入模板名称');
      return;
    }
    const targetId: string = (asNew || this.currentTemplateId.length === 0)
      ? '' : this.currentTemplateId;
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    saveTemplate(ctx, name, this.doc, targetId.length > 0 ? targetId : undefined).then(() => {
      this.showTemplateDialog = false;
      this.toast(`模板「${name}」已保存`);
    }).catch(() => {
      this.toast('保存失败');
    });
  }

  /** 清空画布:释放所有元素并重置 */
  private clearCanvas(): void {
    if (this.locked()) {
      return;
    }
    if (this.doc.elements.length === 0) {
      this.toast('画布已经是空的');
      return;
    }
    this.doc.releaseAll();
    this.bump();
    this.toast('画布已清空');
  }

  private async doPrint(): Promise<void> {
    if (this.locked()) {
      return;
    }
    if (!this.connected()) {
      this.toast('请先在首页连接打印机');
      return;
    }
    if (this.doc.elements.length === 0) {
      this.toast('画布是空的,先插入点内容');
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
      // 和预览吃同一份合成结果,逐点一致
      const composite: CanvasComposite = composeCanvas(this.doc);
      const raster: RasterData =
        packBinaryToRaster(composite.binary, composite.width, composite.height);
      const result: PrintResult = await this.printer.printRaster(raster, null);
      this.resultOk = result.ok;
      this.resultMessage = result.message;
      if (result.ok) {
        // 二值(1=黑/0=白)转灰度(0=黑/255=白)存历史
        const n: number = composite.width * composite.height;
        const grayData: Uint8Array = new Uint8Array(n);
        for (let i = 0; i < n; i++) {
          grayData[i] = composite.binary[i] === 1 ? 0 : 255;
        }
        const gray: GrayImage = {
          data: grayData,
          width: composite.width,
          height: composite.height,
        };
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        // 自定义打印存 CanvasDoc 快照(复用模板序列化),点记录重新打印时恢复整个画布
        const payload: string = JSON.stringify({
          elements: docToTemplateData(this.doc),
          minLength: this.doc.minLength,
        });
        addHistoryGray(ctx, HIST_TYPE_CUSTOM, gray, payload);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'print failed: %{public}s', JSON.stringify(err));
      this.resultOk = false;
      this.resultMessage = `打印失败:${describeError(err as object)}`;
    } finally {
      this.printing = false;
    }
  }

  // ── UI ────────────────────────────────────────────────

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
  toolButton(label: string, action: () => void, icon?: Resource) {
    Row({ space: 6 }) {
      // 图标（可选）
      if (icon) {
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor([Palette.TEXT_PRIMARY])
      }

      // 文字
      Text(label)
        .fontSize(14)
        .fontColor(Palette.TEXT_PRIMARY)
    }
    .layoutWeight(1)
    .height(Metrics.EDITOR_TOOL_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Palette.SURFACE)
    .borderRadius(8)
    .opacity(this.locked() ? 0.4 : 1)
    .enabled(!this.locked())
    .onClick(action)
  }

  @Builder
  editorSheet() {
    // selected() 可能为空(比如刚删完),空时不构建内容,避免空引用
    if (this.doc.selected() !== undefined) {
      ElementEditSheet({
        element: this.doc.selected(),
        onChanged: () => {
          this.onElementChanged();
        },
        onDelete: () => {
          this.doc.remove(this.doc.selectedId);
          this.bump();
        },
        onClose: () => {
          this.showEditor = false;
        },
      })
    }
  }

  @Builder
  templateDialog() {
    Column() {
      TextInput({ placeholder: '输入模板名称', text: $$this.templateName })
        .width('100%')
        .height(48)
        .fontSize(15)
        .backgroundColor(Palette.SURFACE)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onSubmit(() => {
          this.confirmSaveTemplate();
        })

      // 主操作一行:另存为(从模板进入时) + 保存
      Row({ space: 10 }) {
        if (this.currentTemplateId.length > 0) {
          Button('另存为')
            .layoutWeight(1)
            .height(46)
            .fontSize(15)
            .fontColor(Palette.BRAND)
            .backgroundColor(Palette.SURFACE)
            .onClick(() => {
              this.confirmSaveAs();
            })
        }

        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .fontColor(Palette.TEXT_ON_BRAND)
          .backgroundColor(Palette.BRAND)
          .onClick(() => {
            this.confirmSaveTemplate();
          })
      }
      .width('100%')
      .margin({ top: 16 })

      // 取消单独一行,放最下
      Button('取消')
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontColor(Palette.TEXT_PRIMARY)
        .backgroundColor(Palette.SURFACE)
        .margin({ top: 10 })
        .onClick(() => {
          this.showTemplateDialog = false;
        })
    }
    .width('100%')
    .padding(Metrics.PAGE_PADDING)
    .backgroundColor(Palette.PAGE_BG)
  }

  /**

  /**   * 标题栏删除按钮:标准 Symbol 符号,黑色,圆角背景。
   * 尺寸用 TOP_ACTION_SIZE(36vp)与返回按钮一致,menus 用 CustomBuilder 保证图标渲染。
   */
  @Builder
  trashMenu() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(Metrics.TOP_ACTION_ICON)
        .fontColor([Palette.TRASHCOLOR])
    }
    .width(Metrics.TOP_ACTION_SIZE)         // 按钮尺寸 36vp
    .height(Metrics.TOP_ACTION_SIZE)        // 按钮尺寸 36vp
    .margin({ right: 12 ,top:10})
    .backgroundColor(Palette.SURFACE_SUNKEN)
    .stateEffect(true)                      // 点击波纹效果
    .onClick(() => {
      this.clearCanvas();
    })
  }


  @Builder
  canvasBody() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 纸张本体。灰底衬白纸,才看得出纸的边界在哪
      Column()
        .width(CANVAS_DISPLAY_WIDTH)
        .height(this.doc.height() * this.dotScale())
        .backgroundColor(Palette.PAPER)
        .border({ width: 1, color: Palette.PAPER_EDGE })

      ForEach(this.doc.elements, (el: CanvasElement) => {
        // 必须套一层真实布局节点来承载 position/尺寸。
        // 直接把 .position() 写进 CanvasElementView 内部的根节点是无效的 ——
        // 自定义组件外面还有一层包装节点,内部 position 只在包装盒里生效,
        // 包装盒本身还是被 Stack 按 TopStart 摆,所有元素会堆在左上角。
        Stack() {
          // 内容图直接放父级 build,读 el.preview(@Trace)。
          // 之前放在 CanvasElementView 里走 @Param 传 pixelmap 不可靠 ——
          // @Param 对对象做初始化拷贝,父组件后续赋的位图子组件看不到,结果就是只有边框没有内容。
          // 父组件直接观察 @Trace 字段,preview 一变就会触发重绘,不需要 ForEach 重建。
          if (el.preview !== undefined) {
            Image(el.preview)
              .width('100%')
              .height('100%')
              // 关掉插值:抖动点阵和条码边界被糊掉就白做了
              .interpolation(ImageInterpolation.None)
              // 内容不拦手势,交给上面那层 CanvasElementView
              .hitTestBehavior(HitTestMode.None)
          }

          CanvasElementView({
            element: el,
            dotScale: this.dotScale(),
            selected: this.doc.selectedId === el.id,
            onSelect: () => {
              this.doc.selectedId = el.id;
            },
            onEdit: () => {
              hilog.info(DOMAIN, TAG, 'onEdit selected=%{public}s', this.doc.selectedId);
              this.showEditor = true;
            },
            onLiveEdit: () => {
              this.renderLive(el);
            },
            onDragging: (dragging: boolean) => {
              this.dragging = dragging;
            },
            onCommit: () => {
              // 拖动中不重算位图,松手才按新尺寸重新渲染
              this.runRender(el);
            },
          })
        }
        .width(Math.max(1, el.dotW * this.dotScale()))
        .height(Math.max(1, el.dotH * this.dotScale()))
        .position({
          x: el.dotX * this.dotScale(),
          y: el.dotY * this.dotScale(),
        })
      // key = id + revision,缺一不可:
      //   id           —— 元素身份稳定,ForEach 靠它区分谁是谁
      //   revision     —— 每次渲染完成 bump() 会自增并重赋数组,数组一变 ForEach 就重新 diff,
      //                   此时 key 里带 revision 才必然变化,才触发 destroy→create → 闭包重跑
      // 只重赋数组不改 key:复用旧 item,闭包不重跑,preview 更新看不到(前两轮就是这么挂的)
      // 只改 key 不重赋数组:ForEach 数据源没变,key 生成器根本不被调用(也挂过)
      }, (el: CanvasElement) => `${el.id}_${this.revision}`)

      // 选中元素的操作排:画在画布 Stack 的**最后**(天然最顶层),绝对定位到选中元素上方。
      // 它不属于任何元素、不参与元素层级,所以选中下层元素时操作排浮出来,元素本身仍在下层。
      // 元素被置顶/置底只改数组顺序,zIndex 不再影响显示 —— 操作排永远在最上。
      if (this.selectedEl() !== undefined) {
        Row({ space: 4 }) {
          Text('↑')
            .width(28).height(28).fontSize(14).textAlign(TextAlign.Center)
            .fontColor(Palette.TEXT_ON_BRAND).backgroundColor(Palette.BRAND).borderRadius(14)
            .onClick(() => {
              this.doc.toTop(this.doc.selectedId);
              this.bump();
            })
          Text('↓')
            .width(28).height(28).fontSize(14).textAlign(TextAlign.Center)
            .fontColor(Palette.TEXT_ON_BRAND).backgroundColor(Palette.BRAND).borderRadius(14)
            .onClick(() => {
              this.doc.toBottom(this.doc.selectedId);
              this.bump();
            })
          Text('⎘')
            .width(28).height(28).fontSize(14).textAlign(TextAlign.Center)
            .fontColor(Palette.TEXT_ON_BRAND).backgroundColor(Palette.BRAND).borderRadius(14)
            .onClick(() => {
              this.copyElement(this.selectedEl()!);
            })
          Text('✕')
            .width(28).height(28).fontSize(14).textAlign(TextAlign.Center)
            .fontColor(Palette.TEXT_ON_BRAND).backgroundColor(Palette.DANGER).borderRadius(14)
            .onClick(() => {
              this.doc.remove(this.doc.selectedId);
              this.bump();
            })
        }
        // 宽度自适应,只包住按钮,不横跨整幅画布 —— 否则这条透明的行会挡住
        // 同一高度区域所有元素的点击,导致双击编辑失效
        .width('auto')
        .position({
          // 水平居中于元素中心:4 按钮(28*4)+ 3 gap(4*3)= 124vp,半宽 62
          x: this.selectedEl()!.dotX * this.dotScale() +
             this.selectedEl()!.dotW * this.dotScale() / 2 - 62,
          y: this.selectedEl()!.dotY * this.dotScale() - 40,
        })
        .hitTestBehavior(HitTestMode.Default)
      }
    }
    .width(CANVAS_DISPLAY_WIDTH)
    .height(this.doc.height() * this.dotScale())
  }

  /**
   * 画布容器。
   *
   * 用 if/else 双分支切换来**强制重建整棵画布**:revision 变化时条件翻转,
   * 旧分支销毁、新分支创建,ForEach 从零重建所有元素,闭包必然读到最新 el.preview。
   *
   * 为什么需要这么粗暴:内容显示依赖 ForEach item 闭包里的 `if (el.preview)` 重新求值,
   * 而 ArkUI 对 @ObservedV2 对象数组的 ForEach 增量 diff 在这个场景不可靠 ——
   * 只靠「key 变化」或「数组重赋」单独其一都不触发重建,试了多轮没生效。
   * 条件渲染切换是确定性行为,不依赖 ForEach 的 diff 逻辑。
   *
   * 拖动不受影响:拖动只改 dotX/dotY(@Trace),父组件直接观察,不必走重建;
   * 只有插入/编辑/松手后 bump() 翻转 revision,此时强制重建是想要的。
   */
  @Builder
  canvasArea() {
    if (this.revision % 2 === 0) {
      this.canvasBody()
    } else {
      this.canvasBody()
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.connectionBanner()

        Scroll() {
          Column() {
            this.canvasArea()
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        // 内容高度超过视口时,右侧显示滚动条;不超出时隐藏
        .scrollBar(BarState.Auto)
        // 拖元素时必须锁住滚动,否则纵向拖拽会被外层 Scroll 抢走
        .enableScrollInteraction(!this.dragging)
        // 画布默认长度 = 视口剩余高度
        // 这里量的是可视区高度(vp),换算回打印点存进 minLength
        // 内容超过它时 doc.height() 会自动跟着长
        .onAreaChange((_old: Area, next: Area) => {
          const vp: number = Number(next.height);
          if (vp > 0) {
            // 减掉上下 padding,得到纸张真正能铺开的高度
            const dots: number = Math.round((vp - 24) / this.dotScale());
            this.doc.minLength =
              Math.max(MIN_LENGTH_FLOOR, Math.min(MIN_LENGTH_CEIL, dots));
          }
        })
        // 点空白处取消选中
        .onClick(() => {
          this.doc.selectedId = '';
        })

        // 插入栏:放在画布和打印按钮之间,一目了然
        Row({ space: 8 }) {
          this.toolButton('文字', () => {
            this.insertText();
          },
            $r('sys.symbol.doc_plaintext_and_pencil')
          )
          this.toolButton('图片', () => {
            this.insertImage();
          },
            $r('sys.symbol.picture_2')
          )
          this.toolButton('条码', () => {
            this.insertCode();
          },
            $r('sys.symbol.qrcode'))
        }
        .width('100%')
        .margin({ top: 10 })

        Row() {
          Text(`长度 ${this.doc.height()} 点 ≈ ${(this.doc.height() / 8).toFixed(0)}mm`)
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
            .layoutWeight(1)
          if (this.doc.overflowed()) {
            Text('内容已超出长度上限,超出部分不会打印')
              .fontSize(11)
              .fontColor(Palette.DANGER)
          }
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)


        if (this.busy) {
          Row() {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Palette.BRAND)
            Text(this.busyHint)
              .fontSize(12)
              .fontColor(Palette.TEXT_SECONDARY)
              .margin({ left: 8 })
          }
          .margin({ top: 8 })
          .alignItems(VerticalAlign.Center)
        }

        Row() {
          Button('保存模板')
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontColor(Palette.BRAND)
            .backgroundColor(Palette.SURFACE)
            .opacity(this.locked() ? 0.4 : 1)
            .enabled(!this.locked())
            .onClick(() => {
              this.saveTemplate();
            })

          Button(this.printing ? '打印中…' : '打印')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor(Palette.TEXT_ON_BRAND)
            .backgroundColor(
              this.locked() || !this.connected() || this.doc.elements.length === 0
                ? Palette.OFFLINE : Palette.BRAND)
            .enabled(!this.locked())
            .margin({ left: 12 })
            .onClick(() => {
              this.doPrint();
            })
        }
        .width('100%')
        .margin({ top: 10 })
        // 元素编辑弹窗。之前用 bindContentCover —— 在沉浸 NavDestination 下渲染错位,
        // 内容被状态栏压住、还叠到别的弹窗后面,双击后等于没弹出来。
        // 换成 bindSheet:与文字打印页预览弹窗同一套路,沉浸下可用。
        // 挂在底部按钮行而不是根 Column —— 避免同一节点挂两个 bindSheet 互相覆盖。
        // 单向绑定 + onDisappear 回置,与保存模板弹窗一致($$ 双向绑定在 V2 下不可靠)。
        .bindSheet(this.showEditor, this.editorSheet(), {
          height: SheetSize.LARGE,
          preferType: SheetType.BOTTOM,
          title: { title: '编辑元素' },
          backgroundColor: Palette.PAGE_BG,
          onDisappear: () => {
            this.showEditor = false;
          },
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
      .bindSheet(this.showTemplateDialog, this.templateDialog(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        title: { title: '保存模板' },
        onDisappear: () => {
          this.showTemplateDialog = false;
        },
      })
    }
    .title('自定义打印')
    // 标题栏右上角:清空画布,自绘黑色垃圾桶图标(CustomBuilder)
    .menus(this.trashMenu)
    // 全屏沉浸下 NavDestination 不会自己避让,不垫这一下标题栏和返回键会缩进状态栏里点不到
    .padding({ top: this.safeArea.top })
    .backgroundColor(Palette.PAGE_BG)
  }
}
