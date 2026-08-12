import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'BtPermission';

/**
 * API 24 下 ACCESS_BLUETOOTH 是唯一需要运行时申请的蓝牙权限。
 * module.json5 里另外声明的 USE_BLUETOOTH / DISCOVER_BLUETOOTH 是 system_grant,
 * 装包时授予,不走这里。
 *
 * 注:核查过 API 24 SDK,PermissionRequestResult 与 Permissions 都已从
 * @ohos.abilityAccessCtrl 正常导出并由 @kit.AbilityKit 透传,
 * 不需要早期版本那种本地声明接口再强转的绕法。
 */
const BT_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

export enum PermissionOutcome {
  /** 已授权 */
  GRANTED = 0,
  /** 本次弹框被拒 */
  DENIED = 1,
  /** 之前已永久拒绝,系统不再弹框,只能引导去设置页 */
  NEED_SETTINGS = 2,
  /** Previewer / 模拟器等无蓝牙能力的环境 */
  UNAVAILABLE = 3,
}

/** 静默查询当前是否已授权,不弹任何 UI */
export async function hasBluetoothPermission(): Promise<boolean> {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const bundleInfo: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const status: abilityAccessCtrl.GrantStatus =
      atManager.checkAccessTokenSync(bundleInfo.appInfo.accessTokenId, BT_PERMISSION);
    return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'checkAccessToken failed: %{public}s', JSON.stringify(err));
    return false;
  }
}

/**
 * 确保拿到蓝牙权限。已授权直接返回;未授权则弹系统授权框。
 *
 * authResults[i]:0 = 授权,-1 = 拒绝,2 = 请求无效。
 * dialogShownResults[i] 为 false 说明系统压根没弹框 —— 即用户此前已永久拒绝,
 * 这种情况再调 requestPermissionsFromUser 也不会有反应,必须走设置页。
 */
export async function ensureBluetoothPermission(
  context: common.UIAbilityContext): Promise<PermissionOutcome> {
  if (await hasBluetoothPermission()) {
    return PermissionOutcome.GRANTED;
  }

  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const result: PermissionRequestResult =
      await atManager.requestPermissionsFromUser(context, [BT_PERMISSION]);

    if (result.authResults.length > 0 && result.authResults[0] === 0) {
      return PermissionOutcome.GRANTED;
    }

    const shown: Array<boolean> | undefined = result.dialogShownResults;
    if (shown !== undefined && shown.length > 0 && shown[0]) {
      return PermissionOutcome.DENIED;
    }
    return PermissionOutcome.NEED_SETTINGS;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'requestPermissionsFromUser failed: %{public}s', JSON.stringify(err));
    return PermissionOutcome.UNAVAILABLE;
  }
}

/**
 * 用户已永久拒绝时的兜底:拉起系统设置页让其手动开启。
 * 返回 true 表示回来后已授权。
 */
export async function openPermissionSettings(
  context: common.UIAbilityContext): Promise<boolean> {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const statuses: Array<abilityAccessCtrl.GrantStatus> =
      await atManager.requestPermissionOnSetting(context, [BT_PERMISSION]);
    return statuses.length > 0 && statuses[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'requestPermissionOnSetting failed: %{public}s', JSON.stringify(err));
    return false;
  }
}
