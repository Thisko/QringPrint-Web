import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { getSafeArea, SafeArea } from '../common/SafeArea';
import { applyDisplayMode, getThemeState, loadDisplayMode, syncDarkFromSystem, syncStatusBarContent } from '../model/DisplayMode';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 启动时应用用户上次选择的显示模式(白天/黑夜/跟随系统)。
    // app 自身页面配色是硬编码浅色,此切换只影响系统组件(状态栏/键盘/系统弹窗)。
    loadDisplayMode(this.context).then((mode: number) => {
      applyDisplayMode(this.context, mode as number);
    }).catch(() => {
      // 读取失败保持默认(跟随系统)
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      this.applySystemBarStyle(windowStage);
    });
  }

  /**
   * 沉浸式系统栏。
   *
   * setWindowLayoutFullScreen(true) 让内容铺满整屏(含状态栏/导航栏区域),
   * 状态栏本身设成透明,由页面自己的背景透上来 —— 这才是「沉浸」。
   *
   * 代价是系统栏不再自动占位,页面必须自己补 padding,
   * 所以这里把避让区高度量出来存进 SafeArea 单例,由各页取用。
   */
  private applySystemBarStyle(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);

      // 状态栏图标颜色随主题:
      //  深色模式 → 图标白色(顶栏深色,白图标才看得清)
      //  浅色模式 → 图标深色(顶栏浅色,深图标)
      const dark: boolean = getThemeState().isDark;
      const contentColor: string = dark ? '#FFFFFF' : '#000000';
      const barProps: window.SystemBarProperties = {
        // 全透明:状态栏区域显示的就是页面顶栏的颜色
        statusBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarColor: '#00000000',
        navigationBarContentColor: contentColor,
      };
      mainWindow.setWindowSystemBarProperties(barProps);

      this.updateSafeArea(mainWindow);
      // 折叠/分屏/转屏都会改避让区,跟着更新,否则展开后顶栏高度就不对了
      mainWindow.on('avoidAreaChange', () => {
        this.updateSafeArea(mainWindow);
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set system bar style. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /** 把避让区从 px 换算成 vp 存进单例 —— ArkUI 的尺寸数值都按 vp 走 */
  private updateSafeArea(mainWindow: window.Window): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      if (density <= 0) {
        return;
      }
      const system = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const safeArea: SafeArea = getSafeArea();
      safeArea.top = system.topRect.height / density;
      safeArea.bottom = Math.max(system.bottomRect.height, indicator.bottomRect.height) / density;
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to read avoid area. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统颜色模式变化时同步:
    //  跟随系统模式 → app 配色 + 状态栏图标色都跟着变
    //  显式浅/深模式 → setColorMode 已锁定,colorMode 不变,这里无害
    const dark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    syncDarkFromSystem(dark);
    syncStatusBarContent(this.context, dark);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onConfigurationUpdate');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}