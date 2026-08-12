import { Metrics, Palette } from '../common/Theme';

/**
 * 快速打印宫格的单项。
 * ArkTS 严格模式禁止把对象字面量当类型用,所以先声明接口再定义数据。
 */
export interface QuickAction {
  key: string;
  title: string;
  subtitle: string;
  icon: Resource;
  tileColor: string;
}

export const QUICK_ACTIONS: QuickAction[] = [
  {
    key: 'image',
    title: '图片打印',
    subtitle: '相册/拍照',
    icon: $r('app.media.ic_image'),
    tileColor: Palette.TILE_AMBER,
  },
  {
    key: 'txt',
    title: '文字打印',
    subtitle: 'TXT文本',
    icon: $r('app.media.ic_doc'),
    tileColor: Palette.TILE_MINT,
  },
  {
    key: 'qrcode',
    title: '打印条码',
    subtitle: '条形码/二维码',
    icon: $r('app.media.ic_qrcode'),
    tileColor: Palette.TILE_BLUE,
  },
  {
    key: 'custom',
    title: '自定义打印',
    subtitle: '高级设置',
    icon: $r('app.media.ic_gear'),
    tileColor: Palette.TILE_LILAC,
  },
];

/** 宫格列数 */
export const GRID_COLUMNS: number = 2;

/**
 * Grid 放在 Scroll 里必须给显式高度,否则子项会一次性全量加载、或高度直接塌陷。
 * 高度由数据长度算出,以后加减卡片不用手改这个数。
 */
export function quickActionGridHeight(): number {
  const rows: number = Math.ceil(QUICK_ACTIONS.length / GRID_COLUMNS);
  return rows * Metrics.ACTION_CARD_HEIGHT + (rows - 1) * Metrics.GRID_GAP;
}

/** 底部导航单项 */
export interface TabItem {
  key: string;
  label: string;
  icon: Resource;
}

export const TAB_ITEMS: TabItem[] = [
  { key: 'home', label: '首页', icon: $r('app.media.ic_home') },
  { key: 'template', label: '模板', icon: $r('app.media.ic_grid') },
  { key: 'history', label: '历史', icon: $r('app.media.ic_history') },
  { key: 'mine', label: '我的', icon: $r('app.media.ic_person') },
];
