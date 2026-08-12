import { AppStorageV2 } from '@kit.ArkUI';
import { QringStatus } from '../bluetooth/QringProtocol';

/** SPP 连接状态机 */
export enum ConnState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
}

/**
 * 纸张状态。
 * Qring 状态字节只给「缺纸」这一个二值位,没有标准 ESC/POS 那种「纸将尽」,
 * 所以这里只有三态。
 */
export enum PaperState {
  UNKNOWN = 0,
  OK = 1,
  EMPTY = 2,
}

/** 机器状态,来自 10 FF 40 状态字节的各个位 */
export enum HardwareState {
  UNKNOWN = 0,
  NORMAL = 1,
  COVER_OPEN = 2,
  OVERHEAT = 3,
  LOW_BATTERY = 4,
}

/**
 * 打印机全局状态。单一数据源:
 *   写方 —— bluetooth/PrinterConnection.ets
 *   读方 —— view/PrinterStatusCard.ets、各打印页
 * UI 层与蓝牙层不直接互相引用,只通过这个对象通信。
 */
@ObservedV2
export class PrinterStatus {
  @Trace deviceName: string = '';
  @Trace deviceId: string = '';
  @Trace connState: ConnState = ConnState.DISCONNECTED;

  /**
   * 电量百分比,来自 Qring 私有指令 10 FF 50 F1(响应第 2 字节)。
   *
   * 注:标准 ESC/POS 指令集确实没有电量查询,但这台机器走的是 Qring 私有协议,
   * 协议里有独立的电量命令 —— 所以参考图那个「电量 85%」是拿得到的真实数据。
   * null 表示尚未查询到(未连接 / 打印机没回包)。
   */
  @Trace batteryPercent: number | null = null;

  @Trace paperState: PaperState = PaperState.UNKNOWN;
  @Trace hardwareState: HardwareState = HardwareState.UNKNOWN;

  /** 打印机正在出纸 */
  @Trace printing: boolean = false;

  /** 最近一次错误信息,供设备选择半模态和打印页展示 */
  @Trace lastError: string = '';

  /** 型号 / 固件,连接后查一次,用于「自定义打印」页展示 */
  @Trace model: string = '';
  @Trace firmware: string = '';
}

/**
 * 取全局单例。AppStorageV2 只在内存中共享,不落盘;
 * 需要跨启动保留的只有 deviceId,由 PrinterConnection 用 preferences 单独持久化。
 */
export function getPrinterStatus(): PrinterStatus {
  return AppStorageV2.connect(PrinterStatus, 'printerStatus', () => new PrinterStatus())!;
}

/** 把协议层解析出的状态位映射进 UI 模型 */
export function applyQringStatus(target: PrinterStatus, status: QringStatus): void {
  target.printing = status.printing;
  target.paperState = status.noPaper ? PaperState.EMPTY : PaperState.OK;

  // 按严重程度取最该让用户知道的那一条
  if (status.coverOpen) {
    target.hardwareState = HardwareState.COVER_OPEN;
  } else if (status.overheat) {
    target.hardwareState = HardwareState.OVERHEAT;
  } else if (status.lowBattery) {
    target.hardwareState = HardwareState.LOW_BATTERY;
  } else {
    target.hardwareState = HardwareState.NORMAL;
  }
}

// ── 展示文案映射 ──────────────────────────────────────────

export function connLabel(state: ConnState): string {
  switch (state) {
    case ConnState.CONNECTED:
      return '已连接';
    case ConnState.CONNECTING:
      return '连接中';
    default:
      return '未连接';
  }
}

export function paperLabel(state: PaperState): string {
  switch (state) {
    case PaperState.OK:
      return '纸张充足';
    case PaperState.EMPTY:
      return '缺纸';
    default:
      return '纸张未知';
  }
}

export function hardwareLabel(state: HardwareState): string {
  switch (state) {
    case HardwareState.NORMAL:
      return '正常';
    case HardwareState.COVER_OPEN:
      return '开盖';
    case HardwareState.OVERHEAT:
      return '过热';
    case HardwareState.LOW_BATTERY:
      return '低电量';
    default:
      return '未知';
  }
}

/** 电量文案 —— 拿不到真值时显示占位符,不编造数字 */
export function batteryLabel(percent: number | null): string {
  return percent === null ? '电量 --' : `电量 ${percent}%`;
}

/** 指标是否为「未知」态,决定是否降低透明度显示 */
export function isPaperUnknown(state: PaperState): boolean {
  return state === PaperState.UNKNOWN;
}

export function isHardwareUnknown(state: HardwareState): boolean {
  return state === HardwareState.UNKNOWN;
}
