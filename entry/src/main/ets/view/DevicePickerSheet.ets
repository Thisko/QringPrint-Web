import { common } from '@kit.AbilityKit';
import { Metrics, Palette, Typo } from '../common/Theme';
import { ConnState, getPrinterStatus, PrinterStatus } from '../model/PrinterStatus';
import {
  ensureBluetoothPermission,
  openPermissionSettings,
  PermissionOutcome,
} from '../bluetooth/BtPermission';
import { PrinterConnection } from '../bluetooth/PrinterConnection';
import {
  BtDevice,
  DEVICE_NAME_PREFIX,
  DiscoverySession,
  isBluetoothEnabled,
  listPairedDevices,
  watchBluetoothState,
} from '../bluetooth/PrinterDiscovery';

/**
 * @Builder 参数必须收敛成单个对象。多个独立参数走「按值传递」,
 * 状态变量变化不会触发 Builder 内部刷新 —— 这里的文案依赖 this.permission,
 * 用多参数会导致「本次拒绝 → 永久拒绝」时停在同一分支、文案不更新。
 */
interface HintParams {
  title: string;
  detail: string;
  actionLabel: string;
  action: () => void;
}

/**
 * 设备选择半模态。
 *
 * 参考图里没有这个入口 —— 但要接真实蓝牙就必须让用户选设备,
 * 否则连不上任何东西。入口挂在打印机状态卡的点击上。
 */
@ComponentV2
export struct DevicePickerSheet {
  @Local btEnabled: boolean = false;
  @Local permission: PermissionOutcome = PermissionOutcome.DENIED;
  @Local devices: BtDevice[] = [];
  @Local scanning: boolean = false;
  @Local connectingId: string = '';

  @Event onFinished: () => void = () => {};

  private status: PrinterStatus = getPrinterStatus();
  private session: DiscoverySession = new DiscoverySession();
  private unwatchBt: () => void = () => {};

  aboutToAppear(): void {
    this.unwatchBt = watchBluetoothState((enabled: boolean) => {
      this.btEnabled = enabled;
      if (!enabled) {
        this.stopScan();
        this.devices = [];
      } else {
        this.devices = listPairedDevices();
      }
    });
    this.bootstrap();
  }

  aboutToDisappear(): void {
    // 半模态关掉必须停扫描,否则会一直跑着耗电
    this.stopScan();
    this.unwatchBt();
  }

  private async bootstrap(): Promise<void> {
    this.btEnabled = isBluetoothEnabled();

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.permission = await ensureBluetoothPermission(context);

    if (this.permission === PermissionOutcome.GRANTED && this.btEnabled) {
      this.devices = listPairedDevices();
    }
  }

  private async grantPermission(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.permission === PermissionOutcome.NEED_SETTINGS) {
      const ok: boolean = await openPermissionSettings(context);
      this.permission = ok ? PermissionOutcome.GRANTED : PermissionOutcome.NEED_SETTINGS;
    } else {
      this.permission = await ensureBluetoothPermission(context);
    }
    if (this.permission === PermissionOutcome.GRANTED) {
      this.btEnabled = isBluetoothEnabled();
      if (this.btEnabled) {
        this.devices = listPairedDevices();
      }
    }
  }

  private startScan(): void {
    if (this.scanning) {
      return;
    }
    const started: boolean = this.session.start(listPairedDevices(), (found: BtDevice[]) => {
      this.devices = found;
    });
    this.scanning = started;
  }

  private stopScan(): void {
    this.session.stop();
    this.scanning = false;
  }

  private async pick(device: BtDevice): Promise<void> {
    if (this.connectingId.length > 0) {
      return;
    }
    this.stopScan();
    this.connectingId = device.deviceId;
    const ok: boolean = await PrinterConnection.getInstance().connect(device.deviceId);
    this.connectingId = '';
    if (ok) {
      this.onFinished();
    }
  }

  @Builder
  hintBlock(p: HintParams) {
    Column() {
      Text(p.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TEXT_PRIMARY)
      Text(p.detail)
        .fontSize(13)
        .fontColor(Palette.TEXT_SECONDARY)
        .margin({ top: 6 })
        .textAlign(TextAlign.Center)
      if (p.actionLabel.length > 0) {
        Button(p.actionLabel)
          .fontSize(14)
          .fontColor(Palette.TEXT_ON_BRAND)
          .backgroundColor(Palette.BRAND)
          .height(40)
          .margin({ top: 16 })
          .onClick(p.action)
      }
    }
    .width('100%')
    .padding({ top: 40, bottom: 40, left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  deviceRow(device: BtDevice) {
    Row() {
      Image($r('app.media.ic_printer'))
        .width(20)
        .height(20)
        .fillColor(Palette.BRAND)

      Column() {
        Text(device.name)
          .fontSize(15)
          .fontColor(Palette.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(device.paired ? `已配对 · ${device.deviceId}` : device.deviceId)
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      if (this.connectingId === device.deviceId) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(Palette.BRAND)
      } else if (this.status.deviceId === device.deviceId
        && this.status.connState === ConnState.CONNECTED) {
        Text('已连接')
          .fontSize(12)
          .fontColor(Palette.ONLINE)
      }
    }
    .width('100%')
    .height(60)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.pick(device);
    })
  }

  build() {
    Column() {
      if (!this.btEnabled) {
        this.hintBlock({
          title: '蓝牙未开启',
          detail: '请在系统设置或控制中心打开蓝牙,然后回到这里重试。',
          actionLabel: '',
          action: () => {},
        })
      } else if (this.permission !== PermissionOutcome.GRANTED) {
        this.hintBlock({
          title: '需要蓝牙权限',
          detail: this.permission === PermissionOutcome.NEED_SETTINGS
            ? '权限已被永久拒绝,需要到系统设置里手动开启。'
            : '用于扫描并连接附近的蓝牙打印机。',
          actionLabel: this.permission === PermissionOutcome.NEED_SETTINGS ? '前往设置' : '授予权限',
          action: () => {
            this.grantPermission();
          },
        })
      } else {
        Row() {
          Text(this.scanning ? '正在扫描附近设备…' : `仅显示 ${DEVICE_NAME_PREFIX} 设备`)
            .fontSize(13)
            .fontColor(Palette.TEXT_SECONDARY)
            .layoutWeight(1)

          if (this.scanning) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Palette.TEXT_SECONDARY)
              .margin({ right: 8 })
            Text('停止')
              .fontSize(13)
              .fontColor(Palette.BRAND)
              .onClick(() => {
                this.stopScan();
              })
          } else {
            Text('扫描附近设备')
              .fontSize(13)
              .fontColor(Palette.BRAND)
              .onClick(() => {
                this.startScan();
              })
          }
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)

        if (this.devices.length === 0) {
          this.hintBlock({
            title: '没有找到设备',
            detail: `列表只显示名称以「${DEVICE_NAME_PREFIX}」开头的打印机。请确认设备已开机,再点上方「扫描附近设备」。`,
            actionLabel: '',
            action: () => {},
          })
        } else {
          List() {
            ForEach(this.devices, (device: BtDevice) => {
              ListItem() {
                this.deviceRow(device)
              }
            }, (device: BtDevice) => device.deviceId)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: '#F0F1F3' })
          .scrollBar(BarState.Off)
        }

        if (this.status.lastError.length > 0) {
          Text(this.status.lastError)
            .fontSize(12)
            .fontColor(Palette.DANGER)
            .width('100%')
            .margin({ top: 8, bottom: 8 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Metrics.PAGE_PADDING, right: Metrics.PAGE_PADDING })
    .backgroundColor(Palette.SURFACE)
  }
}
