/**
 * 系统安全区高度(单位 vp)。
 *
 * 开了 setWindowLayoutFullScreen(true) 之后,系统栏不再替页面占位 ——
 * 内容会直接铺到状态栏底下。页面得自己补出这段 padding,否则顶栏会被状态栏压住。
 *
 * 做成 @ObservedV2 单例(与 PrinterStatus 同一套路)是因为这个值不是常量:
 * 折叠屏展开、分屏、转屏都会变,@Trace 能驱动页面重新排版。
 */
@ObservedV2
export class SafeArea {
  /** 状态栏高度 */
  @Trace top: number = 0;
  /** 底部手势指示条高度 */
  @Trace bottom: number = 0;
}

const INSTANCE: SafeArea = new SafeArea();

export function getSafeArea(): SafeArea {
  return INSTANCE;
}
