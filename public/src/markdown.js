/**
 * Markdown → 光栅画布
 *
 * 不是通用 Markdown 渲染器，是「按 384 点热敏纸排版」的那种：
 * 没有颜色、没有字号自适应、没有图片，一切都要在 48mm 宽里说清楚。
 * 所以取舍是：结构性的语法（标题、列表、引用、代码、表格、分隔线）全支持，
 * 装饰性的（颜色、HTML、脚注、内联图片）一律丢掉。
 *
 * 渲染分两趟：先量出每块占多高，再建足够大的画布画。
 * 一趟做不了 —— canvas 的高度必须在画之前定死，中途改会清空内容。
 */

import { WIDTH_DOTS } from './protocol.js';

const FAMILY = '"PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif';
const MONO = 'ui-monospace, "Cascadia Mono", Consolas, "Noto Sans Mono CJK SC", monospace';

/** 标题相对正文的倍数。h4 以下不再放大，只保留加粗 */
const H_SCALE = [1.7, 1.4, 1.2, 1.05, 1, 1];

/* ══ 行内解析 ═══════════════════════════════════════════ */

/** 一段文字 → 若干带样式的片段 */
export function parseInline(text, base = {}, showUrl = true) {
  const out = [];
  let buf = '';
  const flush = () => { if (buf) { out.push({ text: buf, ...base }); buf = ''; } };

  /** 强调标记，长的排前面，否则 ** 会被 * 抢先吃掉 */
  const MARKS = [
    ['***', { bold: true, italic: true }], ['**', { bold: true }], ['__', { bold: true }],
    ['~~', { strike: true }], ['*', { italic: true }], ['_', { italic: true }],
  ];

  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);
    let done = false;

    // 转义：\* 之类原样输出
    if (text[i] === '\\' && i + 1 < text.length) { buf += text[i + 1]; i += 2; continue; }

    // 行内代码，里面不再解析
    if (text[i] === '`') {
      const end = text.indexOf('`', i + 1);
      if (end > 0) {
        flush();
        out.push({ text: text.slice(i + 1, end), ...base, code: true });
        i = end + 1; continue;
      }
    }

    // 图片印不出来，留个占位说明
    let m = /^!\[([^\]]*)\]\([^)]*\)/.exec(rest);
    if (m) {
      flush();
      out.push({ text: `[图片${m[1] ? '：' + m[1] : ''}]`, ...base, dim: true });
      i += m[0].length; continue;
    }

    // 链接：文字照印，地址跟在后面 —— 纸上点不了，不写出来这链接就等于没了
    m = /^\[([^\]]+)\]\(([^)]+)\)/.exec(rest);
    if (m) {
      flush();
      out.push(...parseInline(m[1], { ...base, underline: true }, showUrl));
      if (showUrl) out.push({ text: ` (${m[2]})`, ...base, dim: true });
      i += m[0].length; continue;
    }

    for (const [mark, style] of MARKS) {
      if (!rest.startsWith(mark)) continue;
      // 下划线在词中间不算强调，否则 snake_case_name 会被啃掉
      if (mark[0] === '_' && i > 0 && /\w/.test(text[i - 1])) continue;
      const end = text.indexOf(mark, i + mark.length);
      if (end < 0) continue;
      flush();
      out.push(...parseInline(text.slice(i + mark.length, end), { ...base, ...style }, showUrl));
      i = end + mark.length;
      done = true;
      break;
    }
    if (done) continue;

    buf += text[i];
    i++;
  }
  flush();
  return out;
}

/* ══ 块解析 ═════════════════════════════════════════════ */

export function parseBlocks(md) {
  const lines = String(md).replace(/\r\n?/g, '\n').split('\n');
  const blocks = [];
  let para = [];

  const flushPara = () => {
    if (para.length) { blocks.push({ type: 'para', text: para.join(' ') }); para = []; }
  };

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const line = raw.trimEnd();

    // 围栏代码块：里面原样保留，不做任何解析
    const fence = /^\s*(```|~~~)(.*)$/.exec(line);
    if (fence) {
      flushPara();
      const body = [];
      const mark = fence[1];
      i++;
      while (i < lines.length && !lines[i].trimEnd().startsWith(mark)) {
        body.push(lines[i]);
        i++;
      }
      blocks.push({ type: 'code', lines: body, lang: fence[2].trim() });
      continue;
    }

    if (!line.trim()) { flushPara(); continue; }

    // 分隔线
    if (/^\s*([-*_])\s*(\1\s*){2,}$/.test(line)) { flushPara(); blocks.push({ type: 'rule' }); continue; }

    // ATX 标题
    let m = /^(#{1,6})\s+(.*)$/.exec(line.trim());
    if (m) { flushPara(); blocks.push({ type: 'heading', level: m[1].length, text: m[2] }); continue; }

    // Setext 标题：下一行是 === 或 ---
    const next = lines[i + 1]?.trim();
    if (next && /^=+$/.test(next) && line.trim()) {
      flushPara(); blocks.push({ type: 'heading', level: 1, text: line.trim() }); i++; continue;
    }
    if (next && /^-{2,}$/.test(next) && line.trim() && !/^\s*[-*+]\s/.test(line)) {
      flushPara(); blocks.push({ type: 'heading', level: 2, text: line.trim() }); i++; continue;
    }

    // 引用（支持 >> 多层）
    m = /^\s*(>+)\s?(.*)$/.exec(line);
    if (m) { flushPara(); blocks.push({ type: 'quote', depth: m[1].length, text: m[2] }); continue; }

    // 表格：当前行有 |，下一行是分隔行
    if (line.includes('|') && next && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(next) && /-/.test(next)) {
      flushPara();
      const rows = [];
      const cells = s => s.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map(c => c.trim());
      rows.push(cells(line));
      i++;                                        // 跳过分隔行
      while (i + 1 < lines.length && lines[i + 1].includes('|') && lines[i + 1].trim()) {
        rows.push(cells(lines[i + 1].trimEnd()));
        i++;
      }
      blocks.push({ type: 'table', rows });
      continue;
    }

    // 列表：按缩进算层级，两个空格一层
    m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(raw);
    if (m) {
      flushPara();
      const indent = Math.floor(m[1].replace(/\t/g, '  ').length / 2);
      const ordered = /\d/.test(m[2]);
      let text = m[3], task = null;
      const t = /^\[([ xX])\]\s+(.*)$/.exec(text);
      if (t) { task = t[1].toLowerCase() === 'x'; text = t[2]; }
      blocks.push({ type: 'item', indent, ordered, num: ordered ? parseInt(m[2], 10) : 0, task, text });
      continue;
    }

    para.push(line.trim());
  }
  flushPara();
  return blocks;
}

/* ══ 排版 ═══════════════════════════════════════════════ */

const CJK = /[⺀-鿿豈-﫿︰-﹏＀-￯　-〿]/;

/** 禁则：这些不能出现在行首，得跟着上一个字走 */
const NO_LINE_START = /[。、，．！？；：）］｝〕》」』】〗·…‥ー～]/;
/** 这些不能出现在行尾，得跟着下一个字走 */
const NO_LINE_END = /[（［｛〔《「『【〖]/;

/**
 * 切成可断行的最小单位：中日韩逐字断，拉丁按词断（空格跟着前一个词走）。
 * 顺带做最基本的禁则处理 —— 不然「…Markdown。」的句号会被挤到下一行单独占一格，
 * 看着像凭空多了个符号。
 */
function atomize(s) {
  const out = [];
  let word = '';
  let pending = '';                       // 攒着的开括号，不能留在行尾
  const push = a => { out.push(pending + a); pending = ''; };

  for (const ch of s) {
    if (CJK.test(ch)) {
      if (word) { push(word); word = ''; }
      if (NO_LINE_START.test(ch) && out.length && !pending) out[out.length - 1] += ch;
      else if (NO_LINE_END.test(ch)) pending += ch;
      else push(ch);
    } else if (ch === ' ') {
      push(word + ch);
      word = '';
    } else {
      word += ch;
    }
  }
  if (word) push(word);
  else if (pending) out.push(pending);
  return out;
}

const fontOf = (run, size) =>
  `${run.italic ? 'italic ' : ''}${run.bold ? 'bold ' : ''}${size}px ${run.code ? MONO : FAMILY}`;

/** 把片段流按宽度折行，返回每行的片段数组 */
function wrap(probe, runs, size, maxW) {
  const lines = [];
  let line = [], w = 0;

  const put = (run, text, tw) => {
    const last = line[line.length - 1];
    if (last && last.run === run) { last.text += text; last.w += tw; }
    else line.push({ run, text, w: tw });
    w += tw;
  };

  for (const run of runs) {
    probe.font = fontOf(run, size);
    for (let atom of atomize(run.text)) {
      let aw = probe.measureText(atom).width;
      // 单个「词」就超一行（长 URL、长英文），只能硬拆
      while (aw > maxW) {
        let cut = 1;
        while (cut < atom.length && probe.measureText(atom.slice(0, cut + 1)).width <= maxW) cut++;
        if (line.length) { lines.push(line); line = []; w = 0; }
        put(run, atom.slice(0, cut), probe.measureText(atom.slice(0, cut)).width);
        lines.push(line); line = []; w = 0;
        atom = atom.slice(cut);
        aw = probe.measureText(atom).width;
      }
      if (w + aw > maxW && line.length) {
        lines.push(line); line = []; w = 0;
        if (!atom.trim()) continue;                  // 行首不留空格
      }
      put(run, atom, aw);
    }
  }
  if (line.length) lines.push(line);
  return lines.length ? lines : [[]];
}

/**
 * @param {string} md
 * @param {{fontSize?:number, lineSpacing?:number, margin?:number, showUrl?:boolean}} opts
 * @returns {HTMLCanvasElement} 384 点宽
 */
export function renderMarkdown(md, {
  fontSize = 22, lineSpacing = 6, margin = 8, showUrl = true,
} = {}) {
  const blocks = parseBlocks(md);
  const probe = document.createElement('canvas').getContext('2d');
  const W = WIDTH_DOTS;
  const ops = [];
  let y = margin;

  const text = (x, yy, run, size, s) => ops.push({ t: 'text', x, y: yy, font: fontOf(run, size), s, run, size });
  const rect = (x, yy, w, h) => ops.push({ t: 'rect', x, y: yy, w, h });
  const line = (x1, y1, x2, y2, lw = 1) => ops.push({ t: 'line', x1, y1, x2, y2, lw });

  /** 画一段折好行的文字，返回占用高度 */
  const drawRuns = (runs, size, x, maxW) => {
    const rows = wrap(probe, runs, size, maxW);
    const lh = size + lineSpacing;
    for (const row of rows) {
      let cx = x;
      for (const seg of row) {
        text(cx, y, seg.run, size, seg.text);
        if (seg.run.strike) line(cx, y + size * 0.55, cx + seg.w, y + size * 0.55);
        if (seg.run.underline) line(cx, y + size * 1.02, cx + seg.w, y + size * 1.02);
        cx += seg.w;
      }
      y += lh;
    }
    return rows.length * lh;
  };

  for (const b of blocks) {
    switch (b.type) {
      case 'heading': {
        const size = Math.round(fontSize * H_SCALE[b.level - 1]);
        y += b.level <= 2 ? 10 : 6;
        drawRuns(parseInline(b.text, { bold: true }, showUrl), size, margin, W - margin * 2);
        if (b.level <= 2) {                       // 一二级标题下加一条线，层次一眼可见
          y += 2;
          line(margin, y, W - margin, y, b.level === 1 ? 2 : 1);
          y += 8;
        } else {
          y += 4;
        }
        break;
      }

      case 'para':
        drawRuns(parseInline(b.text, {}, showUrl), fontSize, margin, W - margin * 2);
        y += 6;
        break;

      case 'item': {
        const ind = margin + b.indent * 18;
        const size = fontSize;
        const markW = 22;
        const top = y;
        if (b.task !== null && b.task !== undefined) {
          // 自己画方框，比指望字体里有 ☐ / ☑ 靠谱
          const s = Math.round(size * 0.62), oy = top + Math.round(size * 0.24);
          line(ind, oy, ind + s, oy); line(ind, oy + s, ind + s, oy + s);
          line(ind, oy, ind, oy + s); line(ind + s, oy, ind + s, oy + s);
          if (b.task) {
            line(ind + s * 0.18, oy + s * 0.52, ind + s * 0.42, oy + s * 0.8, 2);
            line(ind + s * 0.42, oy + s * 0.8, ind + s * 0.85, oy + s * 0.15, 2);
          }
        } else {
          text(ind, top, {}, size, b.ordered ? `${b.num}.` : '•');
        }
        drawRuns(parseInline(b.text, {}, showUrl), size, ind + markW, W - margin - ind - markW);
        y += 2;
        break;
      }

      case 'quote': {
        const ind = margin + 6 + (b.depth - 1) * 10;
        const top = y;
        const h = drawRuns(parseInline(b.text, {}, showUrl), fontSize, ind + 10, W - margin - ind - 10);
        rect(ind, top, 3, h - lineSpacing);        // 左侧竖条
        y += 4;
        break;
      }

      case 'code': {
        const size = Math.round(fontSize * 0.85);
        const lh = size + 4;
        const top = y;
        y += 6;
        for (const src of b.lines) {
          // 代码不重排，只在超宽时硬折，缩进要保住
          const rows = wrap(probe, [{ text: src || ' ', code: true }], size, W - margin * 2 - 16);
          for (const row of rows) {
            let cx = margin + 8;
            for (const seg of row) { text(cx, y, seg.run, size, seg.text); cx += seg.w; }
            y += lh;
          }
        }
        y += 6;
        line(margin, top, W - margin, top);        // 上下两条线圈出代码区
        line(margin, y, W - margin, y);
        line(margin, top, margin, y);
        line(W - margin, top, W - margin, y);
        y += 8;
        break;
      }

      case 'rule':
        y += 6;
        line(margin, y, W - margin, y);
        y += 10;
        break;

      case 'table': {
        const cols = Math.max(...b.rows.map(r => r.length));
        const size = Math.round(fontSize * 0.85);
        const avail = W - margin * 2;
        // 按各列最宽内容分配宽度，再按总宽归一化
        const want = new Array(cols).fill(20);
        for (const row of b.rows) {
          row.forEach((c, i) => {
            probe.font = `${size}px ${FAMILY}`;
            want[i] = Math.max(want[i], probe.measureText(c).width + 10);
          });
        }
        const sum = want.reduce((a, v) => a + v, 0);
        const colW = want.map(v => Math.floor(v / sum * avail));
        const top = y;
        b.rows.forEach((row, ri) => {
          const rowTop = y;
          let maxH = 0;
          row.forEach((cell, ci) => {
            const x = margin + colW.slice(0, ci).reduce((a, v) => a + v, 0);
            const saveY = y;
            y = rowTop + 3;
            const h = drawRuns(parseInline(cell, ri === 0 ? { bold: true } : {}, showUrl),
                               size, x + 5, colW[ci] - 10);
            maxH = Math.max(maxH, h + 6);
            y = saveY;
          });
          y = rowTop + maxH;
          line(margin, y, margin + colW.reduce((a, v) => a + v, 0), y);   // 行分隔线
        });
        line(margin, top, margin + colW.reduce((a, v) => a + v, 0), top);
        let cx = margin;
        for (let i = 0; i <= cols; i++) {
          line(cx, top, cx, y);
          cx += colW[i] ?? 0;
        }
        y += 8;
        break;
      }
    }
  }

  const cv = document.createElement('canvas');
  cv.width = W;
  cv.height = Math.max(1, Math.round(y + margin));
  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, cv.width, cv.height);
  ctx.fillStyle = '#000';
  ctx.strokeStyle = '#000';
  ctx.textBaseline = 'top';

  for (const op of ops) {
    if (op.t === 'text') {
      ctx.font = op.font;
      // dim 的（链接地址、图片占位）在热敏纸上没有灰度，只能靠字号小一点区分
      ctx.fillText(op.s, op.x, op.run.dim ? op.y + 2 : op.y);
    } else if (op.t === 'rect') {
      ctx.fillRect(op.x, op.y, op.w, op.h);
    } else {
      ctx.lineWidth = op.lw ?? 1;
      ctx.beginPath();
      // +0.5 让 1px 线落在像素中心，不然会被抗锯齿摊成两行灰
      ctx.moveTo(op.x1, Math.round(op.y1) + 0.5);
      ctx.lineTo(op.x2, Math.round(op.y2) + 0.5);
      ctx.stroke();
    }
  }
  return cv;
}

export const MD_SAMPLE = `# 错题小印

**QringPrint** 支持直接打印 Markdown。

## 支持的语法

- 标题、段落、*斜体*、**粗体**、~~删除线~~
- 有序 / 无序列表，可嵌套
  - 像这样
- 任务清单
  - [x] 已完成
  - [ ] 待办

> 引用块长这样，左边有一条竖线。

行内代码 \`printer.feed(100)\`，代码块：

\`\`\`js
await printer.printRaster(raster, {
  thickness: 1,
});
\`\`\`

| 通道 | 速度 | 平台 |
| --- | --- | --- |
| BLE | 慢 | 三端 |
| 串口 | 快 | 桌面 |

---

[项目地址](https://example.com)
`;
