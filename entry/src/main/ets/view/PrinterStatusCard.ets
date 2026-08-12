import { Metrics, Palette, Typo } from '../common/Theme';
import {
  batteryLabel,
  connLabel,
  ConnState,
  getPrinterStatus,
  hardwareLabel,
  isHardwareUnknown,
  isPaperUnknown,
  paperLabel,
  PrinterStatus,
} from '../model/PrinterStatus';

/**
 * @Builder 参数必须收敛成单个对象。
 * 多个独立参数走的是「按值传递」,不支持动态刷新;单对象参数才是按引用,状态变化才能更新 UI。
 */
interface MetricParams {
  icon: Resource;
  label: string;
  muted: boolean;
}

/**
 * 打印机状态卡。
 *
 * 四种视觉状态都要覆盖,不是只画参考图里的「已连接」那一种:
 *   未连接 —— 灰调渐变、灰点、指标全部降级为未知
 *   连接中 —— 紫色渐变、黄点
 *   已连接 —— 紫色渐变、绿点、指标显示真值
 *   电量未知 —— 电量项显示「电量 --」并降透明度(SPP 拿不到电量,这是常态)
 */
@ComponentV2
export struct PrinterStatusCard {
  @Param status: PrinterStatus = getPrinterStatus();
  @Event onTapCard: () => void = () => {};

  /** 未连接时换灰调渐变,避免断开状态仍是高饱和紫、误导用户 */
  private cardColors(): Array<[ResourceColor, number]> {
    if (this.status.connState === ConnState.DISCONNECTED) {
      return [[Palette.CARD_GRAD_OFF_START, 0.0], [Palette.CARD_GRAD_OFF_END, 1.0]];
    }
    return [
      [Palette.CARD_GRAD_START, 0.0],
      [Palette.CARD_GRAD_MID, 0.5],
      [Palette.CARD_GRAD_END, 1.0],
    ];
  }

  private dotColor(): string {
    switch (this.status.connState) {
      case ConnState.CONNECTED:
        return Palette.ONLINE;
      case ConnState.CONNECTING:
        return Palette.WARNING;
      default:
        return Palette.OFFLINE;
    }
  }

  private titleText(): string {
    const name: string = this.status.deviceName;
    return name.length > 0 ? name : '未连接打印机';
  }

  private subtitleText(): string {
    switch (this.status.connState) {
      case ConnState.CONNECTED:
        return '蓝牙已连接';
      case ConnState.CONNECTING:
        return '正在连接…';
      default:
        return '点击选择打印机';
    }
  }

  /** 未连接时所有硬件指标一律按未知处理,不残留上次连接的读数 */
  private offline(): boolean {
    return this.status.connState !== ConnState.CONNECTED;
  }

  @Builder
  metricItem(p: MetricParams) {
    Row() {
      Image(p.icon)
        .width(Metrics.STATUS_METRIC_ICON)
        .height(Metrics.STATUS_METRIC_ICON)
        .fillColor(p.muted ? Palette.ON_CARD_MUTED : Palette.TEXT_ON_BRAND)
      Text(p.label)
        .fontSize(Typo.METRIC)
        .fontColor(p.muted ? Palette.ON_CARD_MUTED : Palette.TEXT_ON_BRAND)
        .margin({ left: 5 })
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      // ── 上半:设备信息 + 连接状态药丸 ──────────────────
      Row() {
        Stack() {
          Image($r('app.media.ic_printer'))
            .width(Metrics.STATUS_TILE_ICON)
            .height(Metrics.STATUS_TILE_ICON)
            .fillColor(Palette.TEXT_ON_BRAND)
        }
        .width(Metrics.STATUS_TILE_SIZE)
        .height(Metrics.STATUS_TILE_SIZE)
        .borderRadius(Metrics.STATUS_TILE_RADIUS)
        .backgroundColor(Palette.ON_CARD_TILE)

        Column() {
          Text(this.titleText())
            .fontSize(Typo.DEVICE_NAME)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT_ON_BRAND)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitleText())
            .fontSize(Typo.DEVICE_SUBTITLE)
            .fontColor(Palette.ON_CARD_SUBTITLE)
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)

        Row() {
          Circle()
            .width(Metrics.STATUS_DOT_SIZE)
            .height(Metrics.STATUS_DOT_SIZE)
            .fill(this.dotColor())
          Text(connLabel(this.status.connState))
            .fontSize(Typo.PILL)
            .fontColor(Palette.TEXT_ON_BRAND)
            .margin({ left: 5 })
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Palette.ON_CARD_TILE)
        .borderRadius(Metrics.STATUS_PILL_RADIUS)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(Palette.ON_CARD_DIVIDER)
        .strokeWidth(1)
        .margin({ top: 14, bottom: 12 })

      // ── 下半:三项硬件指标 ────────────────────────────
      Row() {
        this.metricItem({
          icon: $r('app.media.ic_battery'),
          label: batteryLabel(this.status.batteryPercent),
          // 电量恒为 null(SPP 无此指令),始终降级显示
          muted: this.status.batteryPercent === null,
        })
        this.metricItem({
          icon: $r('app.media.ic_paper'),
          label: this.offline() ? '纸张未知' : paperLabel(this.status.paperState),
          muted: this.offline() || isPaperUnknown(this.status.paperState),
        })
        this.metricItem({
          icon: $r('app.media.ic_thermometer'),
          label: this.offline() ? '未知' : hardwareLabel(this.status.hardwareState),
          muted: this.offline() || isHardwareUnknown(this.status.hardwareState),
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(Metrics.STATUS_CARD_HEIGHT)
    .padding(Metrics.STATUS_CARD_PADDING)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Metrics.STATUS_CARD_RADIUS)
    .linearGradient({ angle: 135, colors: this.cardColors() })
    .onClick(() => {
      this.onTapCard();
    })
  }
}
