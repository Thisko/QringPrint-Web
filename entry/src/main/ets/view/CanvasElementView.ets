import { hilog } from '@kit.PerformanceAnalysisKit';
import { Metrics, Palette } from '../common/Theme';
import { WIDTH_DOTS } from '../bluetooth/QringProtocol';
import { CanvasElement, ElementKind, MIN_ELEMENT_SIZE } from '../model/CanvasModel';

const DOMAIN: number = 0x0001;
const TAG: string = 'CanvasElementView';

/** 字号手柄范围,和双击编辑器里的字号滑块保持一致 */
const FONT_MIN: number = 12;
const FONT_MAX: number = 60;
/** 文字宽度手柄的最小宽度(点),和编辑器里的排版宽度滑块保持一致 */
const WIDTH_MIN: number = 48;

/**
 * 画布上的单个元素:显示 + 拖动 + 缩放。
 *
 * ⚠ 尺寸和位置**由调用方施加在组件实例上**,不在这里的根节点上写 .position()。
 *
 * 手柄/操作排用「精确像素 position + markAnchor 锚点」定位:
 *   position 相对根 Stack(元素框)算,单位 vp。
 *   用 markAnchor 把组件的锚点挪到手柄中心,position 就把锚点放到指定坐标 ——
 *   这样手柄正好压在角上(半里半外),而不是被 translate 推到框外。
 *
 * 选中态控件:
 *   图片/条码 → 右下角等比缩放手柄
 *   文字       → 右下角字号手柄、右上角宽度手柄(图标,拖动中实时重渲染)
 *   全部       → 顶部操作排 置顶/置底/复制/删除
 *               靠上时在元素上方,元素贴画布顶部时翻到下方,避免被画布裁掉
 */
@ComponentV2
export struct CanvasElementView {
  @Param @Require element: CanvasElement;
  /**
   * 显示缩放:1 个打印点等于多少 vp。
   * 不能叫 scale —— 会和 CustomComponent 基类的 scale() 属性方法撞名,编译不过。
   */
  @Param dotScale: number = 1;
  @Param selected: boolean = false;

  @Event onSelect: () => void = () => {};
  @Event onEdit: () => void = () => {};
  /** 拖动/缩放期间要把外层 Scroll 锁住,否则手势会被抢走 */
  @Event onDragging: (dragging: boolean) => void = () => {};
  /** 松手后回调,由外层触发重新渲染 */
  @Event onCommit: () => void = () => {};
  /** 手柄拖动过程中每帧回调,由外层触发实时重渲染 */
  @Event onLiveEdit: () => void = () => {};

  // 手势起点快照。PanGesture 的 offset 是相对起点的累计值,
  // 每帧累加会因为浮点误差漂移,必须记下起点再算绝对值。
  private startX: number = 0;
  private startY: number = 0;
  private startW: number = 0;
  private startFont: number = 0;

  /** 图片/条码用等比缩放;文字没有这个,它用字号/宽度手柄 */
  private resizable(): boolean {
    return this.element.kind !== ElementKind.TEXT;
  }

  private toDots(vp: number): number {
    return this.dotScale > 0 ? vp / this.dotScale : 0;
  }

  private elW(): number {
    return this.element.dotW * this.dotScale;
  }

  private elH(): number {
    return this.element.dotH * this.dotScale;
  }

  /** 整体替换 textOptions(@Trace 只跟踪重新赋值,不跟踪内部字段改动) */
  private setFontSize(v: number): void {
    const o = this.element.textOptions;
    this.element.textOptions = {
      fontFamily: o.fontFamily,
      fontSize: v,
      bold: o.bold,
      italic: o.italic,
      underline: o.underline,
      letterSpacing: o.letterSpacing,
      lineSpacing: o.lineSpacing,
      margin: o.margin,
    };
  }

  /** 图片/条码的等比缩放手柄,锚点压在元素右下角 */
  @Builder
  resizeHandle() {
    Column()
      .width(Metrics.HANDLE_SIZE)
      .height(Metrics.HANDLE_SIZE)
      .backgroundColor(Palette.HANDLE_FILL)
      .border({ width: 2, color: Palette.HANDLE_EDGE })
      .borderRadius(Metrics.HANDLE_SIZE / 2)
      .position({ x: this.elW(), y: this.elH() })
      // 锚点挪到方块中心 → position 处 = 右下角,方块半里半外
      .markAnchor({ x: Metrics.HANDLE_SIZE / 2, y: Metrics.HANDLE_SIZE / 2 })
      .gesture(
        PanGesture({ fingers: 1, distance: 1 })
          .onActionStart(() => {
            this.startW = this.element.dotW;
            this.onSelect();
            this.onDragging(true);
          })
          .onActionUpdate((event: GestureEvent) => {
            const deltaW: number = this.toDots(event.offsetX);
            // 锁定宽高比:只认宽度方向位移,高度按原始比例推导
            const maxW: number = WIDTH_DOTS - this.element.dotX;
            const nextW: number = Math.max(MIN_ELEMENT_SIZE,
              Math.min(maxW, Math.round(this.startW + deltaW)));
            const aspect: number = this.element.aspect > 0 ? this.element.aspect : 1;
            this.element.dotW = nextW;
            this.element.dotH = Math.max(MIN_ELEMENT_SIZE, Math.round(nextW / aspect));
          })
          .onActionEnd(() => {
            this.onDragging(false);
            this.onCommit();
          })
          .onActionCancel(() => {
            this.onDragging(false);
            this.onCommit();
          })
      )
  }

  /** 文字字号手柄:右下角,A 图标。纵向拖改字号,拖动中实时重渲染 */
  @Builder
  fontSizeHandle() {
    Text('A')
      .width(30)
      .height(22)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .textAlign(TextAlign.Center)
      .fontColor(Palette.TEXT_ON_BRAND)
      .backgroundColor(Palette.BRAND)
      .borderRadius(11)
      .position({ x: this.elW(), y: this.elH() })
      .markAnchor({ x: 15, y: 11 })
      .gesture(
        PanGesture({ fingers: 1, distance: 1 })
          .onActionStart(() => {
            this.startFont = this.element.textOptions.fontSize;
            this.onSelect();
            this.onDragging(true);
          })
          .onActionUpdate((event: GestureEvent) => {
            // 纵向拖:向下增大字号。和编辑器字号滑块范围一致
            const next: number = Math.max(FONT_MIN,
              Math.min(FONT_MAX, Math.round(this.startFont + this.toDots(event.offsetY))));
            this.setFontSize(next);
            this.onLiveEdit();
          })
          .onActionEnd(() => {
            this.onDragging(false);
            this.onCommit();
          })
          .onActionCancel(() => {
            this.onDragging(false);
            this.onCommit();
          })
      )
  }

  /** 文字宽度手柄:右上角,↔ 图标。横向拖改宽度,拖动中实时重渲染 */
  @Builder
  widthHandle() {
    Text('↔')
      .width(30)
      .height(22)
      .fontSize(13)
      .textAlign(TextAlign.Center)
      .fontColor(Palette.TEXT_ON_BRAND)
      .backgroundColor(Palette.BRAND)
      .borderRadius(11)
      .position({ x: this.elW(), y: 0 })
      .markAnchor({ x: 15, y: 11 })
      .gesture(
        PanGesture({ fingers: 1, distance: 1 })
          .onActionStart(() => {
            this.startW = this.element.dotW;
            this.onSelect();
            this.onDragging(true);
          })
          .onActionUpdate((event: GestureEvent) => {
            const deltaW: number = this.toDots(event.offsetX);
            const maxW: number = WIDTH_DOTS - this.element.dotX;
            const next: number = Math.max(WIDTH_MIN,
              Math.min(maxW, Math.round(this.startW + deltaW)));
            this.element.dotW = next;
            this.onLiveEdit();
          })
          .onActionEnd(() => {
            this.onDragging(false);
            this.onCommit();
          })
          .onActionCancel(() => {
            this.onDragging(false);
            this.onCommit();
          })
      )
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.element.rendering) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(Palette.BRAND)
          .hitTestBehavior(HitTestMode.None)
          .position({ x: '50%', y: '50%' })
          .markAnchor({ x: 10, y: 10 })
      }

      if (this.selected) {
        // 操作排(置顶/置底/复制/删除)已移到画布层 —— 它要盖过所有元素,
        // 挂在元素内部会被其他元素压住。这里只保留锚在元素几何上的手柄。
        if (this.resizable()) {
          this.resizeHandle()
        } else {
          this.fontSizeHandle()
          this.widthHandle()
        }
      }
    }
    .width('100%')
    .height('100%')
    .border({
      width: 1,
      color: this.selected ? Palette.SELECT_OUTLINE : Palette.ELEMENT_HINT,
      style: this.selected ? BorderStyle.Dashed : BorderStyle.Solid,
    })
    .gesture(
      // Exclusive:谁先识别成功谁拿走。
      // 双击放在单击前面 —— 否则单击先成功,双击永远等不到第二下。
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2 })
          .onAction(() => {
            hilog.info(DOMAIN, TAG, 'DOUBLE TAP id=%{public}s', this.element.id);
            this.onSelect();
            this.onEdit();
          }),
        TapGesture({ count: 1 })
          .onAction(() => {
            hilog.info(DOMAIN, TAG, 'SINGLE TAP id=%{public}s', this.element.id);
            this.onSelect();
          }),
        PanGesture({ fingers: 1, distance: 3 })
          .onActionStart(() => {
            this.startX = this.element.dotX;
            this.startY = this.element.dotY;
            this.onSelect();
            this.onDragging(true);
          })
          .onActionUpdate((event: GestureEvent) => {
            const nextX: number = this.startX + this.toDots(event.offsetX);
            const nextY: number = this.startY + this.toDots(event.offsetY);
            // 横向夹在纸内;纵向只挡住上边,往下拖时画布会自动延长
            this.element.dotX = Math.max(0,
              Math.min(WIDTH_DOTS - this.element.dotW, Math.round(nextX)));
            this.element.dotY = Math.max(0, Math.round(nextY));
          })
          .onActionEnd(() => {
            this.onDragging(false);
            this.onCommit();
          })
          .onActionCancel(() => {
            this.onDragging(false);
            this.onCommit();
          })
      )
    )
  }
}
