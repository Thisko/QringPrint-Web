import { preferences } from '@kit.ArkData';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { AppStorageV2, window } from '@kit.ArkUI';

/**
 * 全局主题状态。AppStorageV2 共享,isDark @Trace 变化驱动所有引用它的组件重渲。
 * Palette getter 读它的 isDark 决定返回浅/深色。
 */
@ObservedV2
export class ThemeState {
  @Trace isDark: boolean = false;
}

const THEME_KEY: string = 'themeState';

/** 全局主题单例,首次调用时创建 */
export function getThemeState(): ThemeState {
  return AppStorageV2.connect(ThemeState, THEME_KEY, () => new ThemeState())!;
}

/** 设置深色标志(驱动 app 配色) */
export function setDark(dark: boolean): void {
  getThemeState().isDark = dark;
}

/**
 * 显示模式(白天/黑夜/跟随系统)。
 *
 * 作用范围:**仅系统级** —— 通过 setColorMode 影响系统组件(状态栏、键盘、系统弹窗)。
 * app 自身的页面配色是硬编码浅色 Palette,不随此切换(见计划确认)。
 *
 * 持久化到 preferences,启动时(EntryAbility)应用上次选择。
 */

export enum DisplayMode {
  /** 跟随系统 */
  FOLLOW = 0,
  /** 白天(浅色) */
  LIGHT = 1,
  /** 黑夜(深色) */
  DARK = 2,
}

const STORE_NAME: string = 'qring_settings';
const KEY_MODE: string = 'display_mode';

export async function loadDisplayMode(ctx: common.UIAbilityContext): Promise<number> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const v: preferences.ValueType = await store.get(KEY_MODE, DisplayMode.FOLLOW);
    return Number(v);
  } catch (err) {
    return DisplayMode.FOLLOW;
  }
}

export async function saveDisplayMode(ctx: common.UIAbilityContext, mode: DisplayMode): Promise<void> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    await store.put(KEY_MODE, mode);
    await store.flush();
  } catch (err) {
    throw err as Error;
  }
}

/**
 * 应用显示模式。
 *  - 显式浅/深:设置 isDark 标志驱动 app 配色,并 setColorMode 驱动系统组件。
 *  - 跟随系统:setColorMode(NOT_SET),isDark 标志由 EntryAbility.onConfigurationUpdate 同步。
 */
export function applyDisplayMode(ctx: common.UIAbilityContext, mode: DisplayMode): void {
  try {
    let cm: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === DisplayMode.LIGHT) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      setDark(false);
      syncStatusBarContent(ctx, false);
    } else if (mode === DisplayMode.DARK) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      setDark(true);
      syncStatusBarContent(ctx, true);
    }
    ctx.getApplicationContext().setColorMode(cm);
  } catch (err) {
    // setColorMode 失败不阻断
  }
}

/** 状态栏/导航栏图标颜色随主题。深色 → 白图标;浅色 → 深图标 */
export function syncStatusBarContent(ctx: common.UIAbilityContext, dark: boolean): void {
  window.getLastWindow(ctx).then((win: window.Window) => {
    const contentColor: string = dark ? '#FFFFFF' : '#000000';
    win.setWindowSystemBarProperties({
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor,
    });
  }).catch(() => {
    // 窗口未就绪时忽略,EntryAbility.applySystemBarStyle 会兜底
  });
}

/** 由 EntryAbility 在配置变化时调用,同步跟随系统模式下的深色标志 */
export function syncDarkFromSystem(dark: boolean): void {
  setDark(dark);
}
