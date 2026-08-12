/**
 * 设计令牌 —— 全部视觉常量集中在此文件。
 *
 * 颜色是对参考图 (热敏打印机App首页.png) 的目视取样,后续微调只需改这里,
 * 不要在组件里散落硬编码色值。
 *
 * 半透明色统一用 ArkUI 的 #AARRGGBB 八位十六进制,避免 rgba() 字符串解析歧义。
 *
 * 显示模式:Palette 成员是 getter,按 ThemeState.isDark(@ObservedV2 单例)返回浅/深两套色板。
 * isDark 变化时,Index 顶层持有一份 ThemeState 引用触发重建,子页 build 重跑 getter 换色。
 */
import { getThemeState } from '../model/DisplayMode';

/** 当前是否深色模式。由 ThemeState.isDark(@ObservedV2 单例)维护 */
function isDark(): boolean {
  return getThemeState().isDark;
}

export class Palette {
  // ── 品牌(两种模式保持一致,品牌色不随主题变)──────────
  static get BRAND(): string {
    return '#7C5CE6';
  }
  static get BRAND_PRESSED(): string {
    return '#6A4BD4';
  }

  // ── 状态卡渐变 ────────────────────────────────────────
  static get CARD_GRAD_START(): string {
    return '#6E4CE8';
  }
  static get CARD_GRAD_MID(): string {
    return '#8B5CF6';
  }
  static get CARD_GRAD_END(): string {
    return '#A855F7';
  }
  static get CARD_GRAD_OFF_START(): string {
    return '#9AA0AC';
  }
  static get CARD_GRAD_OFF_END(): string {
    return '#B4B9C4';
  }

  // ── 页面与表面 ────────────────────────────────────────
  static get PAGE_BG(): string {
    return isDark() ? '#212224' : '#F2F3F5';
  }
  static get SURFACE(): string {
    return isDark() ? '#1E1E1E' : '#FFFFFF';
  }
  static get SURFACE_SUNKEN(): string {
    return isDark() ? '#2A2A2A' : '#F2F3F5';
  }
  static get PRESSED(): string {
    return isDark() ? '#383838' : '#EDEEF0';
  }

  // ── 文字与图标 ────────────────────────────────────────
  static get TEXT_PRIMARY(): string {
    return isDark() ? '#E6E6E6' : '#1A1A1A';
  }
  static get TEXT_TITLE(): string {
    return isDark() ? '#F0F0F0' : '#1F1F1F';
  }
  static get TEXT_SECONDARY(): string {
    return isDark() ? '#9AA0AC' : '#9A9AA0';
  }
  static get TEXT_ON_BRAND(): string {
    return '#FFFFFF';
  }
  static get ICON_NEUTRAL(): string {
    return isDark() ? '#B0B0B8' : '#5A5A63';
  }

  // ── 状态卡内部(叠在渐变上的半透明,两种模式一致)──────
  static get ON_CARD_TILE(): string {
    return '#38FFFFFF';
  }
  static get ON_CARD_SUBTITLE(): string {
    return '#BFFFFFFF';
  }
  static get ON_CARD_DIVIDER(): string {
    return '#2EFFFFFF';
  }
  static get ON_CARD_MUTED(): string {
    return '#73FFFFFF';
  }

  // ── 语义色 ────────────────────────────────────────────
  static get ONLINE(): string {
    return '#3DDC84';
  }
  static get OFFLINE(): string {
    return isDark() ? '#3A3A3A' : '#D8DCE3';
  }
  static get WARNING(): string {
    return '#FFB020';
  }
  static get DANGER(): string {
    return '#FF4D4F';
  }

  // ── 快速打印宫格瓷砖 ──────────────────────────────────
  static get TILE_AMBER(): string {
    return '#F7C873';
  }
  static get TILE_MINT(): string {
    return '#8FD9B6';
  }
  static get TILE_BLUE(): string {
    return '#9CC4EF';
  }
  static get TILE_LILAC(): string {
    return '#BDA8F0';
  }
  static get TILE_ICON(): string {
    return '#FFFFFF';
  }

  // ── 自定义画布编辑器 ──────────────────────────────────
  static get ACTION_BLUE(): string {
    return '#3A7BFF';
  }
  static get PAPER(): string {
    // 深色模式下纸张调灰,避免纯白在深色背景上太刺眼
    return isDark() ? '#2E2E2E' : '#FFFFFF';
  }
  static get TRASHCOLOR(): string {
    // 深色模式下纸张调灰,避免纯白在深色背景上太刺眼
    return isDark() ? '#FFFFFF' : '#1A1A1A';
  }
  static get PAPER_EDGE(): string {
    return isDark() ? '#3D3D3D' : '#D8DCE3';
  }
  static get SELECT_OUTLINE(): string {
    return '#7C5CE6';
  }
  static get ELEMENT_HINT(): string {
    return isDark() ? '#33FFFFFF' : '#33000000';
  }
  static get HANDLE_FILL(): string {
    return '#7C5CE6';
  }
  static get HANDLE_EDGE(): string {
    return '#FFFFFF';
  }
}

/**
 * 尺寸与间距。单位:vp(ArkUI 数值型尺寸默认 vp)。
 */
export class Metrics {
  // 页面
  static readonly PAGE_PADDING: number = 16;
  static readonly TOP_BAR_HEIGHT: number = 56;
  static readonly TAB_BAR_HEIGHT: number = 60;
  static readonly TAB_BAR_RADIUS: number = 24;

  // 顶栏
  static readonly BRAND_BADGE_SIZE: number = 40;
  static readonly BRAND_BADGE_RADIUS: number = 12;
  static readonly BRAND_BADGE_ICON: number = 22;
  static readonly TOP_ACTION_SIZE: number = 36;
  static readonly TOP_ACTION_ICON: number = 18;
  static readonly RED_DOT_SIZE: number = 7;

  // 打印机状态卡
  static readonly STATUS_CARD_HEIGHT: number = 132;
  static readonly STATUS_CARD_RADIUS: number = 20;
  static readonly STATUS_CARD_PADDING: number = 16;
  static readonly STATUS_TILE_SIZE: number = 48;
  static readonly STATUS_TILE_RADIUS: number = 12;
  static readonly STATUS_TILE_ICON: number = 24;
  static readonly STATUS_PILL_RADIUS: number = 14;
  static readonly STATUS_DOT_SIZE: number = 6;
  static readonly STATUS_METRIC_ICON: number = 14;

  // 快速打印宫格
  static readonly ACTION_CARD_HEIGHT: number = 152;
  static readonly ACTION_CARD_RADIUS: number = 16;
  static readonly GRID_GAP: number = 12;
  static readonly TILE_SIZE: number = 56;
  static readonly TILE_RADIUS: number = 16;
  static readonly TILE_ICON: number = 26;

  // 底部导航
  static readonly TAB_ICON: number = 22;

  // 自定义画布编辑器
  /** 缩放手柄的视觉大小 */
  static readonly HANDLE_SIZE: number = 14;
  /** 手柄的可点区域。比视觉大一圈,否则手指根本按不准 */
  static readonly HANDLE_TOUCH: number = 34;
  /** 工具栏按钮高度 */
  static readonly EDITOR_TOOL_HEIGHT: number = 40;
}

/**
 * 字号。单位:fp(ArkUI fontSize 数值默认 fp,跟随系统字体缩放)。
 */
export class Typo {
  static readonly APP_TITLE: number = 17;
  static readonly APP_SUBTITLE: number = 11;
  static readonly SECTION_TITLE: number = 17;

  static readonly DEVICE_NAME: number = 20;
  static readonly DEVICE_SUBTITLE: number = 13;
  static readonly PILL: number = 12;
  static readonly METRIC: number = 12;

  static readonly ACTION_TITLE: number = 15;
  static readonly ACTION_SUBTITLE: number = 12;

  static readonly TAB_LABEL: number = 10;
}
