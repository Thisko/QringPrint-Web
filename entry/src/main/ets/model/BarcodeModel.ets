import { scanCore } from '@kit.ScanKit';

/**
 * 条码类型与输入约束。
 *
 * 码制清单严格对应 scanCore.ScanType 里实际存在的枚举值,不是凭印象列的。
 * 排除了 MULTIFUNCTIONAL_CODE(华为多功能码,内容规则不公开)和
 * ONE_D_CODE / TWO_D_CODE / ALL(这三个是扫码时用的类别掩码,不能拿来生成)。
 */

export enum CodeCategory {
  ONE_D = 0,
  TWO_D = 1,
}

export interface CodeType {
  scanType: scanCore.ScanType;
  label: string;
  category: CodeCategory;
  /** 输入限制说明,直接显示给用户 */
  hint: string;
}

export const CODE_TYPES: CodeType[] = [
  // ── 一维码 ──────────────────────────────────────────
  {
    scanType: scanCore.ScanType.EAN13_CODE,
    label: 'EAN-13',
    category: CodeCategory.ONE_D,
    hint: '13 位纯数字(含校验位);也可只输 12 位,由生成器补校验位',
  },
  {
    scanType: scanCore.ScanType.EAN8_CODE,
    label: 'EAN-8',
    category: CodeCategory.ONE_D,
    hint: '8 位纯数字(含校验位);也可只输 7 位',
  },
  {
    scanType: scanCore.ScanType.UPC_A_CODE,
    label: 'UPC-A',
    category: CodeCategory.ONE_D,
    hint: '12 位纯数字(含校验位);也可只输 11 位',
  },
  {
    scanType: scanCore.ScanType.UPC_E_CODE,
    label: 'UPC-E',
    category: CodeCategory.ONE_D,
    hint: '8 位纯数字,首位必须是 0 或 1;也可只输 6 位数据段',
  },
  {
    scanType: scanCore.ScanType.ITF14_CODE,
    label: 'ITF-14',
    category: CodeCategory.ONE_D,
    hint: '14 位纯数字。ITF 按两位一组编码,位数必须是偶数',
  },
  {
    scanType: scanCore.ScanType.CODE128_CODE,
    label: 'Code 128',
    category: CodeCategory.ONE_D,
    hint: '任意 ASCII 字符(0–127),长度不限。一维码里兼容性最好的选择',
  },
  {
    scanType: scanCore.ScanType.CODE39_CODE,
    label: 'Code 39',
    category: CodeCategory.ONE_D,
    hint: '数字、大写字母 A–Z,以及 - . $ / + % 和空格',
  },
  {
    scanType: scanCore.ScanType.CODE93_CODE,
    label: 'Code 93',
    category: CodeCategory.ONE_D,
    hint: '字符集同 Code 39,但编码更紧凑',
  },
  {
    scanType: scanCore.ScanType.CODABAR_CODE,
    label: 'Codabar',
    category: CodeCategory.ONE_D,
    hint: '数字与 - $ : / . +,首尾必须各带一个起止字符 A/B/C/D',
  },

  // ── 二维码 ──────────────────────────────────────────
  {
    scanType: scanCore.ScanType.QR_CODE,
    label: 'QR Code',
    category: CodeCategory.TWO_D,
    hint: '任意文本,最多约 2953 字节。最通用的二维码',
  },
  {
    scanType: scanCore.ScanType.DATAMATRIX_CODE,
    label: 'Data Matrix',
    category: CodeCategory.TWO_D,
    hint: '任意文本,最多约 2335 字符。小尺寸下密度高,常用于工业标签',
  },
  {
    scanType: scanCore.ScanType.PDF417_CODE,
    label: 'PDF417',
    category: CodeCategory.TWO_D,
    hint: '任意文本,最多约 1850 字符。横向长条形,常用于证件',
  },
  {
    scanType: scanCore.ScanType.AZTEC_CODE,
    label: 'Aztec',
    category: CodeCategory.TWO_D,
    hint: '任意文本,最多约 3067 字符。无需静区,常用于票务',
  },
];

export function typesOf(category: CodeCategory): CodeType[] {
  const result: CodeType[] = [];
  for (const type of CODE_TYPES) {
    if (type.category === category) {
      result.push(type);
    }
  }
  return result;
}

// ── 输入校验 ────────────────────────────────────────────

const RE_DIGITS: RegExp = new RegExp('^[0-9]+$');
const RE_CODE39: RegExp = new RegExp('^[0-9A-Z\\-. $/+%]+$');
const RE_CODABAR_BODY: RegExp = new RegExp('^[0-9\\-$:/.+]+$');
const RE_ASCII: RegExp = new RegExp('^[\\x00-\\x7F]+$');

function digitsOnly(content: string): boolean {
  return RE_DIGITS.test(content);
}

/**
 * 生成前的本地校验。返回错误信息,null 表示可以生成。
 *
 * 这一层是为了给出人话提示 —— 直接把不合法内容丢给 createBarcode,
 * 拿回来的只是一个错误码,用户看不懂哪里错了。
 * 但它**不替代** SDK 的校验:长度/字符集之外还有校验位算法等规则,
 * 最终以生成结果为准,生成失败时仍会把 SDK 的错误显示出来。
 */
export function validateContent(type: CodeType, content: string): string | null {
  if (content.length === 0) {
    return '请输入要生成的内容';
  }

  switch (type.scanType) {
    case scanCore.ScanType.EAN13_CODE:
      if (!digitsOnly(content)) {
        return 'EAN-13 只能是纯数字';
      }
      if (content.length !== 12 && content.length !== 13) {
        return `EAN-13 需要 12 或 13 位数字,当前 ${content.length} 位`;
      }
      return null;

    case scanCore.ScanType.EAN8_CODE:
      if (!digitsOnly(content)) {
        return 'EAN-8 只能是纯数字';
      }
      if (content.length !== 7 && content.length !== 8) {
        return `EAN-8 需要 7 或 8 位数字,当前 ${content.length} 位`;
      }
      return null;

    case scanCore.ScanType.UPC_A_CODE:
      if (!digitsOnly(content)) {
        return 'UPC-A 只能是纯数字';
      }
      if (content.length !== 11 && content.length !== 12) {
        return `UPC-A 需要 11 或 12 位数字,当前 ${content.length} 位`;
      }
      return null;

    case scanCore.ScanType.UPC_E_CODE:
      if (!digitsOnly(content)) {
        return 'UPC-E 只能是纯数字';
      }
      if (content.length !== 6 && content.length !== 8) {
        return `UPC-E 需要 6 或 8 位数字,当前 ${content.length} 位`;
      }
      if (content.length === 8 && content.charAt(0) !== '0' && content.charAt(0) !== '1') {
        return 'UPC-E 的 8 位形式首位必须是 0 或 1';
      }
      return null;

    case scanCore.ScanType.ITF14_CODE:
      if (!digitsOnly(content)) {
        return 'ITF-14 只能是纯数字';
      }
      if (content.length % 2 !== 0) {
        return `ITF 按两位一组编码,位数必须是偶数,当前 ${content.length} 位`;
      }
      if (content.length !== 14) {
        return `ITF-14 需要 14 位数字,当前 ${content.length} 位`;
      }
      return null;

    case scanCore.ScanType.CODE39_CODE:
    case scanCore.ScanType.CODE93_CODE:
      if (!RE_CODE39.test(content)) {
        return '只能包含数字、大写字母 A–Z,以及 - . $ / + % 和空格';
      }
      return null;

    case scanCore.ScanType.CODABAR_CODE: {
      if (content.length < 3) {
        return 'Codabar 至少需要「起始字符 + 数据 + 结束字符」三位';
      }
      const head: string = content.charAt(0).toUpperCase();
      const tail: string = content.charAt(content.length - 1).toUpperCase();
      const valid: string = 'ABCD';
      if (valid.indexOf(head) < 0 || valid.indexOf(tail) < 0) {
        return 'Codabar 首尾必须各带一个起止字符 A/B/C/D,例如 A1234A';
      }
      if (!RE_CODABAR_BODY.test(content.substring(1, content.length - 1))) {
        return 'Codabar 中间部分只能是数字与 - $ : / . +';
      }
      return null;
    }

    case scanCore.ScanType.CODE128_CODE:
      if (!RE_ASCII.test(content)) {
        return 'Code 128 只支持 ASCII 字符(0–127),不能含中文';
      }
      return null;

    case scanCore.ScanType.QR_CODE:
      return null;

    case scanCore.ScanType.DATAMATRIX_CODE:
      if (content.length > 2335) {
        return `Data Matrix 最多约 2335 字符,当前 ${content.length}`;
      }
      return null;

    case scanCore.ScanType.PDF417_CODE:
      if (content.length > 1850) {
        return `PDF417 最多约 1850 字符,当前 ${content.length}`;
      }
      return null;

    case scanCore.ScanType.AZTEC_CODE:
      if (content.length > 3067) {
        return `Aztec 最多约 3067 字符,当前 ${content.length}`;
      }
      return null;

    default:
      return null;
  }
}

/** 示例内容,方便快速试打 */
export function sampleContent(type: CodeType): string {
  switch (type.scanType) {
    case scanCore.ScanType.EAN13_CODE:
      return '6901234567892';
    case scanCore.ScanType.EAN8_CODE:
      return '6901234';
    case scanCore.ScanType.UPC_A_CODE:
      return '012345678905';
    case scanCore.ScanType.UPC_E_CODE:
      return '01234565';
    case scanCore.ScanType.ITF14_CODE:
      return '06901234567892';
    case scanCore.ScanType.CODABAR_CODE:
      return 'A12345A';
    case scanCore.ScanType.CODE39_CODE:
    case scanCore.ScanType.CODE93_CODE:
      return 'QRING-001';
    default:
      return 'https://example.com';
  }
}
