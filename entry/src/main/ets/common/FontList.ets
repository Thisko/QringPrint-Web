import { font } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'FontList';

/** 兜底字体族。系统列表拿不到时至少还有这三个通用族可选 */
export const FALLBACK_FAMILIES: string[] = ['sans-serif', 'serif', 'monospace'];

export function familyLabel(family: string): string {
  if (family === 'sans-serif') {
    return '系统默认(无衬线)';
  }
  if (family === 'serif') {
    return '衬线';
  }
  if (family === 'monospace') {
    return '等宽';
  }
  return family;
}

export interface FontListResult {
  families: string[];
  options: SelectOption[];
}

/**
 * 枚举设备上真实存在的字体,而不是硬编一份猜测清单 ——
 * 不同机型预装字体差别很大,写死的族名在别的机器上会静默回落到默认字体。
 *
 * 两个来源合起来用:
 *   getSystemFontList() —— 只返回「已安装字体」,很多机型上这份列表很短甚至是空的
 *   getUIFontConfig()   —— 系统字体配置,信息量大得多:
 *                          generic[].family        字体集主族名
 *                          generic[].alias[].name  字重/字宽变体
 *                          fallbackGroups[]…family 各语种回退族(中日韩、泰文、emoji…)
 *
 * 注:getUIFontConfig 只在 @ohos.font 全局命名空间上,
 * UIContext.getFont() 里没有这个方法,所以这里两种调用方式并存。
 *
 * 抽成公共函数是因为文字打印页和自定义画布的文字元素都要用这份清单,
 * 而这段设备兼容逻辑不该抄两份。
 */
export function loadFontFamilies(systemFontList: string[]): FontListResult {
  const families: string[] = [];
  for (const generic of FALLBACK_FAMILIES) {
    families.push(generic);
  }

  const push: (name: string) => void = (name: string) => {
    if (name.length > 0 && families.indexOf(name) < 0) {
      families.push(name);
    }
  };

  for (const name of systemFontList) {
    push(name);
  }

  try {
    const config: font.UIFontConfig = font.getUIFontConfig();
    for (const generic of config.generic) {
      push(generic.family);
      for (const alias of generic.alias) {
        push(alias.name);
      }
    }
    for (const group of config.fallbackGroups) {
      for (const fallback of group.fallback) {
        push(fallback.family);
      }
    }
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'getUIFontConfig unavailable: %{public}s', JSON.stringify(err));
  }

  const options: SelectOption[] = [];
  for (const family of families) {
    options.push({ value: familyLabel(family) });
  }
  hilog.info(DOMAIN, TAG, 'font families: %{public}d', families.length);
  return { families: families, options: options };
}

/** 安全取族名,越界回落到通用无衬线 */
export function familyAt(families: string[], index: number): string {
  if (index >= 0 && index < families.length) {
    return families[index];
  }
  return 'sans-serif';
}
