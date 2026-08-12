
import { QringPrinter } from './src/printer.js';
import { BleTransport, DEFAULT_CHUNK, IS_MOBILE, shortUuid } from './src/transport-ble.js';
import { SerialTransport } from './src/transport-serial.js';
import { DITHER_ALGOS, loadImage, renderText, rasterize, supportsLetterSpacing } from './src/raster.js';
import { CODE_TYPES, findType, renderCode } from './src/barcode.js';
import { renderMarkdown, MD_SAMPLE } from './src/markdown.js';
import { sleep } from './src/rxbuffer.js';
import { toHex, WIDTH_DOTS } from './src/protocol.js';

/** 打印完成到查询状态之间的缓冲。ACK 回来时机器还在走纸收尾，立刻查容易没响应 */
const POST_PRINT_SETTLE_MS = 500;

const $ = id => document.getElementById(id);
const logEl = $('log');

/** 日志条数上限。打印时 RX 通知来得挺密，无限堆下去手机会越滚越卡 */
const LOG_LIMIT = 800;

function log(msg, cls = '') {
  const d = document.createElement('div');
  if (cls) d.className = cls;
  const t = new Date().toTimeString().slice(0, 8);
  d.textContent = `${t}  ${msg}`;
  logEl.appendChild(d);
  while (logEl.childElementCount > LOG_LIMIT) logEl.firstElementChild.remove();
  logEl.scrollTop = logEl.scrollHeight;
  syncLogCount();
}

/** 折叠着的时候，条数是唯一能看出「有没有新东西」的线索 */
function syncLogCount() {
  const n = logEl.childElementCount;
  $('logCount').textContent = n ? ` · ${n} 条` : '';
}

// 这两个按钮长在 summary 里，不拦住事件的话点一下会把整个日志面板折起来
$('btnClearLog').addEventListener('click', e => {
  e.preventDefault();
  e.stopPropagation();
  logEl.replaceChildren();
  syncLogCount();
});

$('btnCopyLog').addEventListener('click', async e => {
  e.preventDefault();
  e.stopPropagation();
  try {
    await navigator.clipboard.writeText(logEl.innerText);
    toast('日志已复制', 'ok');
  } catch {
    toast('复制失败（可能没有剪贴板权限），请手动选中复制', 'bad');
  }
});

/**
 * 浮在操作条上方的结果提示。
 * 日志默认是展开的，但手机上它在屏幕外，打完一张图到底成没成、多快，
 * 得滚下去才看得到 —— 关键结果在这儿再报一次，4 秒后自己消失。
 */
let toastTimer = 0;
function toast(msg, cls = '') {
  const el = $('toast');
  el.textContent = msg;
  el.className = cls ? `toast ${cls}` : 'toast';
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 4000);
}

/* ── 状态 ─────────────────────────────────────────────── */
let printer = null;
let currentTab = 'img';
let imgSource = null;       // 已解码的图片
let lastRaster = null;      // 当前 tab 待打印的光栅

/* ── 主题 ─────────────────────────────────────────────── */
// 初值已由 <head> 里那段同步脚本定好（避免首帧闪白），这里只负责切换和落盘
const THEME_KEY = 'qringprint.theme';

function applyTheme(t) {
  document.documentElement.dataset.theme = t;
  $('btnTheme').textContent = t === 'light' ? '☀️' : '🌙';
  // 手机地址栏跟着变色，否则深色页面配白色状态栏很突兀
  $('metaTheme').content = t === 'light' ? '#f4f5f8' : '#12141a';
}
applyTheme(document.documentElement.dataset.theme);

$('btnTheme').addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
  localStorage.setItem(THEME_KEY, next);
  applyTheme(next);
});

/* ── 设置浮窗 ─────────────────────────────────────────── */
const dlg = $('settings');

/** 老浏览器没有 showModal，退回普通 open —— 少块遮罩，功能照旧 */
function openSettings() {
  if (dlg.open) return;                    // 已经开着还调 showModal 会抛 InvalidStateError
  $('setMsg').hidden = true;
  if (typeof dlg.showModal === 'function') dlg.showModal();
  else dlg.setAttribute('open', '');
}

function closeSettings() {
  if (dlg.open && typeof dlg.close === 'function') dlg.close();
  else dlg.removeAttribute('open');
}

/** 浮窗里的就地反馈 —— 这会儿日志和底部提示都被它盖着，看不见 */
function setMsg(text, cls) {
  const el = $('setMsg');
  el.textContent = text;
  el.className = `hint ${cls}`;
  el.hidden = false;
}

$('btnSettings').addEventListener('click', openSettings);
$('btnSetClose').addEventListener('click', closeSettings);
// 点遮罩关掉：模态 dialog 上落在自身矩形之外的点击，target 就是 dialog 本身
dlg.addEventListener('click', e => { if (e.target === dlg) closeSettings(); });

/* ── 连接 ─────────────────────────────────────────────── */
function setConnected(on, label = '未连接') {
  const dot = $('dot');
  dot.classList.toggle('on', on);
  dot.classList.remove('wait');
  $('connText').textContent = label;
  // 连上只留「断开」、没连上只留「连接」——手机上这一行本来就挤，
  // 留一个变灰的按钮在那儿既占地方又没用
  $('btnConnect').hidden = on;
  $('btnConnect').disabled = on;
  $('btnDisconnect').hidden = !on;
  $('btnDisconnect').disabled = !on;
  $('meta').hidden = !on;
  $('connActs').hidden = !on;      // 刷新状态 / 读取设备信息
  $('btnFeed').disabled = !on;     // 设置里的走纸同理，没连接点了也没用
  updatePrintBtn();
}

$('btnConnect').addEventListener('click', async () => {
  const kind = $('transport').value;
  try {
    log(`正在连接（${kind === 'ble' ? 'BLE' : '串口'}）…`, 'dim');
    const t = kind === 'ble'
      ? await BleTransport.connect({ acceptAll: $('acceptAll').checked })
      : await SerialTransport.connect();
    await t.start();

    t.onDisconnect = () => {
      log('连接已断开（自动重连三次均失败）', 'bad');
      toast('连接已断开', 'bad');
      printer = null;
      setConnected(false);
    };
    t.onStateChange = s => {
      if (s === 'reconnecting') {
        $('connText').textContent = '重连中…';
        $('dot').classList.remove('on');
        $('dot').classList.add('wait');
        log('链路掉了，正在自动重连…', 'warn');
      } else {
        $('connText').textContent = t.label;
        $('dot').classList.remove('wait');
        $('dot').classList.add('on');
        log('已重连', 'ok');
      }
    };

    printer = new QringPrinter(t);
    printer.onLog = (dir, text) => log(`${dir} ${text}`, dir === 'TX' ? 'tx' : 'rx');

    if (t instanceof BleTransport) {
      // 所有通知都记日志并标出来源，旁路（FF03）压暗
      t.onNotify = (uuid, bytes, isMain) =>
        log(`RX[${shortUuid(uuid)}] ${toHex(bytes)}`, isMain ? 'rx' : 'dim');
    } else {
      t.rx.onData = bytes => log(`RX ${toHex(bytes)}`, 'rx');
    }
    applyTransportTuning();
    syncTuningUI(t);

    setConnected(true, t.label);
    log('已连接', 'ok');
    await refreshInfo();
  } catch (e) {
    log(`连接失败：${e.message}`, 'bad');
    toast(`连接失败：${e.message}`, 'bad');
    if (/Web Bluetooth/.test(e.message)) {
      log('iOS 请用 Bluefy 浏览器；Safari / Firefox 不支持。', 'dim');
    }
  }
});

$('btnDisconnect').addEventListener('click', async () => {
  try { await printer?.close(); } catch { /* ignore */ }
  printer = null;
  setConnected(false);
  syncTuningUI(null);
  log('已断开', 'dim');
});

/* ── 设备信息 ─────────────────────────────────────────── */
async function refreshInfo() {
  if (!printer) return;
  try {
    const info = await printer.info();
    $('mModel').textContent = info.model || '—';
    $('mFw').textContent    = info.fw    || '—';
    $('mBat').textContent   = info.battery == null ? '—' : `${info.battery}%`;
    log(`型号 ${info.model} / 固件 ${info.fw} / SN ${info.sn} / 电量 ${info.battery}%`, 'ok');
    await refreshStatus();
  } catch (e) {
    log(`读取信息失败：${e.message}`, 'bad');
  }
}

async function refreshStatus() {
  if (!printer) return null;
  const st = await printer.status();
  $('mStatus').textContent = st.text;
  $('mStatus').className = st.ok ? 'ok' : 'bad';
  log(`状态：${st.text}${st.raw === null ? '' : `（0x${st.raw.toString(16).padStart(2, '0').toUpperCase()}）`}`,
      st.ok ? 'ok' : 'warn');
  return st;
}

$('btnStatus').addEventListener('click', () => refreshStatus());
$('btnInfo').addEventListener('click', () => refreshInfo());

/* ── 传输参数 ─────────────────────────────────────────── */
/**
 * 这两个滑块只对 BLE 有意义。串口用自己的 1024/1ms（和 Python 一致，
 * 不受 MTU 约束），连上串口时把它们禁掉，免得拉了半天没反应。
 */
function syncTuningUI(t) {
  const isBle = !t || t instanceof BleTransport;
  $('chunk').disabled = !isBle;
  $('chunkDelay').disabled = !isBle;
  $('tuneNote').innerHTML = isBle
    ? '通道已固化：写 <code>FF00→FF02</code>，收 <code>FF00→FF01</code>，带响应写。' +
      '这套是逐条试出来的，FF02 比 ISSC 那条快一倍。'
    : '当前是串口，固定 <code>1024 字节 / 1ms</code>（与 Python 一致），' +
      '不受 MTU 约束，下面两项对它无效。';
}

function applyTransportTuning() {
  if (!printer) return;
  if (printer.t instanceof BleTransport) {
    printer.t.chunk = +$('chunk').value;
    printer.t.chunkDelay = +$('chunkDelay').value;
  }
}
for (const [id, label] of [['chunk', 'ckLabel'], ['chunkDelay', 'cdLabel']]) {
  $(id).addEventListener('input', () => {
    $(label).textContent = $(id).value;
    // 超过本端实测上限就标黄 —— 再大会把打印机卡在光栅接收态
    if (id === 'chunk') $(label).className = +$(id).value > DEFAULT_CHUNK ? 'warn' : '';
    applyTransportTuning();
  });
}

/* ── 设置里那几项：存本地，别每次都重调 ───────────────── */
const SETTINGS_KEY = 'qringprint.settings';

/** id → 默认值。DEFAULT_CHUNK 是按端算出来的（手机 100 / 桌面 133） */
const SETTINGS = {
  chunk: DEFAULT_CHUNK,
  chunkDelay: 0,
  waitAck: true,
  thickness: 0,
  feedDots: 100,
};

function loadSettings() {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(SETTINGS_KEY)) || {}; }
  catch { /* 存坏了就当没存过 */ }

  for (const [id, def] of Object.entries(SETTINGS)) {
    const el = $(id);
    const v = saved[id];
    const isChk = el.type === 'checkbox';
    if (isChk) el.checked = typeof v === 'boolean' ? v : def;
    else el.value = typeof v === 'number' && Number.isFinite(v) ? v : def;
    // 借原有的 input/change 处理器把旁边的数字标签一起刷出来，省得两处维护
    el.dispatchEvent(new Event(isChk ? 'change' : 'input'));
    el.addEventListener(isChk ? 'change' : 'input', saveSettings);
  }
}

function saveSettings() {
  const out = {};
  for (const id of Object.keys(SETTINGS)) {
    const el = $(id);
    out[id] = el.type === 'checkbox' ? el.checked : +el.value;
  }
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(out)); }
  catch { /* 无痕模式下写不进去，不影响用 */ }
}

/* ── 首栏收起 / 展开 ──────────────────────────────────── */
// 连上之后通道选择和设备信息就不用一直占着屏幕了，尤其手机
const FOLD_KEY = 'qringprint.connFold';

function applyConnFold(folded) {
  $('connBody').hidden = folded;
  $('btnConnFold').textContent = folded ? '▾' : '▴';
  $('btnConnFold').setAttribute('aria-expanded', String(!folded));
}

$('btnConnFold').addEventListener('click', () => {
  const folded = !$('connBody').hidden;
  localStorage.setItem(FOLD_KEY, folded ? '1' : '');
  applyConnFold(folded);
});

/* ── Tab ──────────────────────────────────────────────── */
for (const b of document.querySelectorAll('.tabs button')) {
  b.addEventListener('click', () => {
    currentTab = b.dataset.tab;
    document.querySelectorAll('.tabs button').forEach(x => x.classList.toggle('sel', x === b));
    document.querySelectorAll('.pane').forEach(p => p.classList.toggle('sel', p.id === `pane-${currentTab}`));
    // 重算当前 tab 的光栅，否则会拿着上一个 tab 的内容去打印
    lastRaster = null;
    if (currentTab === 'img') renderImgPreview();
    else if (currentTab === 'text') renderTextPreview();
    else if (currentTab === 'code') renderCodePreview();
    else renderMdPreview();
    updatePrintBtn();
  });
}

/* ── 图片 ─────────────────────────────────────────────── */
// 抖动下拉框由算法表生成，加算法只改 raster.js 那张表
(function initDitherSelect() {
  const sel = $('dither');
  for (const a of DITHER_ALGOS) {
    const o = document.createElement('option');
    o.value = a.id;
    o.textContent = a.name;
    sel.appendChild(o);
  }
  sel.value = 'floyd';                       // 照片默认值，线稿再手动切回阈值
  updateDitherHint();
})();

function updateDitherHint() {
  const a = DITHER_ALGOS.find(x => x.id === $('dither').value);
  $('ditherHint').textContent = a?.hint ?? '';
}

async function acceptFile(f) {
  if (!f.type.startsWith('image/')) return log(`不是图片：${f.name}`, 'warn');
  try {
    imgSource = await loadImage(f);
    $('drop').classList.add('filled');
    $('pkEmpty').hidden = true;
    $('pkView').hidden = false;
    $('fileName').textContent = f.name;
    $('fileMeta').textContent = `${imgSource.width}×${imgSource.height} · 点击更换`;
    log(`已载入 ${f.name}（${imgSource.width}×${imgSource.height}）`, 'dim');
    setXfEnabled(true);
    renderImgPreview();
  } catch (err) {
    log(`图片解码失败：${err.message}`, 'bad');
  }
}

$('file').addEventListener('change', e => {
  const f = e.target.files?.[0];
  if (f) acceptFile(f);
});

// 拖放。label 包着 input，点任意位置都能唤起选择器，拖放另走这条路。
const dropEl = $('drop');
for (const ev of ['dragenter', 'dragover']) {
  dropEl.addEventListener(ev, e => { e.preventDefault(); dropEl.classList.add('over'); });
}
for (const ev of ['dragleave', 'dragend', 'drop']) {
  dropEl.addEventListener(ev, e => { e.preventDefault(); dropEl.classList.remove('over'); });
}
dropEl.addEventListener('drop', e => {
  const f = e.dataTransfer?.files?.[0];
  if (f) acceptFile(f);
});

function renderImgPreview() {
  if (!imgSource) return;
  const r = rasterize(imgSource, {
    threshold: +$('threshold').value,
    dither: $('dither').value,
    invert: $('invert').checked,
    contrast: +$('contrast').value,
    sharpen: +$('sharpen').value,
  });
  $('pvImg').replaceChildren(r.preview);
  if (currentTab === 'img') lastRaster = r;
  updatePrintBtn();
}

// 三个滑块都是「改数字 → 刷标签 → 重算预览」，凑一块注册
for (const [id, label] of [['threshold', 'thLabel'], ['contrast', 'ctLabel'], ['sharpen', 'shLabel']]) {
  $(id).addEventListener('input', () => {
    $(label).textContent = $(id).value;
    syncImgSum();
    renderImgPreview();
  });
}

/** 折叠状态下摘要要能看出当前设了多少，否则收起来就成了黑盒 */
function syncImgSum() {
  $('imgSum').textContent =
    `阈值 ${$('threshold').value} · 对比 ${$('contrast').value} · 锐度 ${$('sharpen').value}`;
}
$('dither').addEventListener('change', () => { updateDitherHint(); renderImgPreview(); });
$('invert').addEventListener('change', renderImgPreview);

// 只还原这四项调节。旋转翻转是直接改图源的，撤不回来，重新选一次图就是了
$('imgReset').addEventListener('click', () => {
  for (const [id, v, label] of [['threshold', 128, 'thLabel'], ['contrast', 0, 'ctLabel'],
                                ['sharpen', 0, 'shLabel']]) {
    $(id).value = v;
    $(label).textContent = v;
  }
  $('invert').checked = false;
  syncImgSum();
  renderImgPreview();
});

/* ── 旋转 / 翻转 ──────────────────────────────────────── */
const XF_BTNS = ['rotL', 'rotR', 'flipH', 'flipV'];
const setXfEnabled = on => { for (const id of XF_BTNS) $(id).disabled = !on; };

/**
 * 变换直接作用在已解码的图源上，一次次叠加 —— 连点两下右旋就是 180°，符合直觉。
 *
 * 90° 旋转和翻转都只是像素搬家，不缩放，所以反复点也不会掉画质
 * （imageSmoothingEnabled 关掉，杜绝边缘插值）。真正的缩放只在 rasterize
 * 里对着原图做一次，始终是 384 点宽。
 * 想还原就重新选一次图 —— 换文件会整个替掉图源，变换自然清零。
 */
function transformSource(kind) {
  if (!imgSource) return;
  const turn = kind === 'rotL' || kind === 'rotR';   // 转 90° 要交换宽高
  const cv = document.createElement('canvas');
  cv.width  = turn ? imgSource.height : imgSource.width;
  cv.height = turn ? imgSource.width  : imgSource.height;

  const ctx = cv.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  if (kind === 'rotL')       { ctx.translate(0, cv.height); ctx.rotate(-Math.PI / 2); }
  else if (kind === 'rotR')  { ctx.translate(cv.width, 0);  ctx.rotate(Math.PI / 2); }
  else if (kind === 'flipH') { ctx.translate(cv.width, 0);  ctx.scale(-1, 1); }
  else                       { ctx.translate(0, cv.height); ctx.scale(1, -1); }
  ctx.drawImage(imgSource, 0, 0);

  // ImageBitmap 占的是解码后的位图内存，换掉之前主动放掉，别攒着
  imgSource.close?.();
  imgSource = cv;

  $('fileMeta').textContent = `${cv.width}×${cv.height} · 点击更换`;
  renderImgPreview();
}

for (const id of XF_BTNS) $(id).addEventListener('click', () => transformSource(id));

/* ── 文字 ─────────────────────────────────────────────── */
/**
 * 字体清单。Web 上没有可靠的字体枚举 API（queryLocalFonts 只有桌面 Chrome
 * 且要授权），所以给一份常见字体栈 —— 装没装得上不用猜，预览就是最终点阵，
 * 落没落到备选字体一眼就看出来了。
 */
const FONT_CHOICES = [
  ['系统默认',  '"PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif'],
  ['无衬线',    'system-ui, sans-serif'],
  ['宋体 / 衬线', '"Songti SC", SimSun, "Noto Serif CJK SC", serif'],
  ['黑体',      '"Heiti SC", SimHei, "Microsoft YaHei", sans-serif'],
  ['楷体',      '"Kaiti SC", KaiTi, STKaiti, "Noto Serif CJK SC", serif'],
  ['仿宋',      'FangSong, STFangsong, "Fangsong SC", serif'],
  ['圆体',      '"Yuanti SC", YouYuan, "Hiragino Maru Gothic ProN", sans-serif'],
  ['等宽',      'ui-monospace, Consolas, "Noto Sans Mono CJK SC", monospace'],
];

(function initFontSelect() {
  const sel = $('fontFamily');
  for (const [label, css] of FONT_CHOICES) {
    const o = document.createElement('option');
    o.value = css;
    o.textContent = label;
    o.style.fontFamily = css;                  // 下拉里就用该字体显示，选之前先看一眼
    sel.appendChild(o);
  }
})();

/* ── 自定义字体 ───────────────────────────────────────
 * 本地文件读成 ArrayBuffer 直接喂给 FontFace；在线的分两种：
 * 字体直链走 FontFace(url(...))，Google Fonts 那种 css 地址走 <link> 让浏览器自己拉
 * —— 后者能绕开 fetch 的跨域限制（样式表不受 CORS 管，字体文件受）。
 */
const FONT_KEY = 'qringprint.fonts';        // 只存在线地址，本地文件存不下
const FONT_SEL_KEY = 'qringprint.font';     // 上次选的字体

function fontMsg(text, cls) {
  const el = $('fontMsg');
  el.textContent = text;
  el.className = `hint ${cls}`;
  el.hidden = false;
}

/** 自定义字体单独归到一个分组里，跟内置的分开 */
function addFontOption(label, css, select = true) {
  const sel = $('fontFamily');
  let group = sel.querySelector('optgroup');
  if (!group) {
    group = document.createElement('optgroup');
    group.label = '自定义';
    sel.appendChild(group);
  }
  if ([...group.children].some(o => o.value === css)) return;
  const o = document.createElement('option');
  o.value = css;
  o.textContent = label;
  o.style.fontFamily = css;
  group.appendChild(o);
  if (select) { sel.value = css; renderTextPreview(); }
}

/**
 * document.fonts.check() 对任何族名都点头（它判断的是「回退之后有字可用」），
 * 拿它验字体到底生效了没是白搭 —— 只能量宽度：和纯 monospace 比出来不一样才算真上了。
 */
function fontApplied(family) {
  const probe = document.createElement('canvas').getContext('2d');
  const T = '错题小印 AWMil 123';
  probe.font = '32px monospace';
  const a = probe.measureText(T).width;
  probe.font = `32px "${family}", monospace`;
  return probe.measureText(T).width !== a;
}

const safeName = s => s.replace(/\.[^.]+$/, '').replace(/[^\w一-龥 -]/g, '').slice(0, 28);

async function loadLocalFont(file) {
  const name = safeName(file.name) || `本地字体${Date.now() % 1000}`;
  const face = new FontFace(name, await file.arrayBuffer());
  await face.load();                          // 文件不是字体就在这一步抛
  document.fonts.add(face);
  addFontOption(`${name}（本地）`, `"${name}"`);
  return name;
}

async function loadUrlFont(url) {
  // Google Fonts 给的是样式表而不是字体文件，交给 <link>，族名从 family= 里取
  if (/fonts\.googleapis\.com\/css/i.test(url)) {
    const fam = new URL(url).searchParams.get('family')?.split(':')[0]?.replace(/\+/g, ' ');
    if (!fam) throw new Error('这个 css 地址里读不出 family 参数');
    await new Promise((res, rej) => {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = url;
      link.onload = res;
      link.onerror = () => rej(new Error('样式表加载失败，检查地址和网络'));
      document.head.appendChild(link);
    });
    await document.fonts.load(`32px "${fam}"`);
    // <link> 加载成功不代表族名对得上，得实测一下
    if (!fontApplied(fam)) throw new Error(`样式表加载了，但「${fam}」没生效，核对一下 family 名`);
    addFontOption(`${fam}（在线）`, `"${fam}"`);
    return `"${fam}"`;
  }
  const name = safeName(url.split(/[/?#]/).filter(Boolean).pop() ?? '') || '在线字体';
  const face = new FontFace(name, `url("${url.replace(/"/g, '%22')}")`);
  await face.load();                          // 跨域字体对方不给 CORS 头就在这挂
  document.fonts.add(face);
  addFontOption(`${name}（在线）`, `"${name}"`);
  return `"${name}"`;
}

const savedFonts = () => {
  try { return JSON.parse(localStorage.getItem(FONT_KEY)) || []; } catch { return []; }
};

$('fontFile').addEventListener('change', async e => {
  const files = [...(e.target.files ?? [])];
  e.target.value = '';                        // 清掉才能再选同一个文件
  const done = [];
  for (const f of files) {
    try { done.push(await loadLocalFont(f)); }
    catch (err) { fontMsg(`${f.name} 加载失败：${err.message}`, 'bad'); return; }
  }
  if (done.length) {
    fontMsg(`已载入 ${done.join('、')}（刷新后需重新选择）`, 'ok');
    log(`已载入本地字体 ${done.join('、')}`, 'dim');
  }
});

$('fontUrlAdd').addEventListener('click', async () => {
  const url = $('fontUrl').value.trim();
  if (!url) return fontMsg('先填一个地址', 'bad');
  if (!/^https?:\/\//i.test(url)) return fontMsg('要以 http:// 或 https:// 开头', 'bad');
  fontMsg('正在加载…', '');
  try {
    const css = await loadUrlFont(url);
    const list = savedFonts().filter(x => x.url !== url);
    list.push({ url, css });
    localStorage.setItem(FONT_KEY, JSON.stringify(list));
    fontMsg('已载入并记住，下次自动加载', 'ok');
    log(`已载入在线字体 ${url}`, 'dim');
  } catch (e) {
    // 十有八九是对方没给跨域头 —— 字体文件受 CORS 管，不像图片那样能随便引
    fontMsg(`加载失败：${e.message}。字体文件必须允许跨域（Access-Control-Allow-Origin）`, 'bad');
  }
});

$('fontClear').addEventListener('click', () => {
  $('fontFamily').querySelector('optgroup')?.remove();
  localStorage.removeItem(FONT_KEY);
  localStorage.removeItem(FONT_SEL_KEY);
  $('fontFamily').value = FONT_CHOICES[0][1];
  fontMsg('已清除自定义字体（已加载的会在刷新后消失）', 'ok');
  renderTextPreview();
});

/** 开机把记住的在线字体重新拉一遍，失败的直接丢掉，别让它一直报错 */
async function restoreFonts() {
  const list = savedFonts();
  const keep = [];
  for (const item of list) {
    try { await loadUrlFont(item.url); keep.push(item); }
    catch (e) { log(`在线字体 ${item.url} 恢复失败，已移除：${e.message}`, 'warn'); }
  }
  if (keep.length !== list.length) localStorage.setItem(FONT_KEY, JSON.stringify(keep));

  // 恢复上次选的字体，选项还在才应用（本地字体刷新后就没了）
  const want = localStorage.getItem(FONT_SEL_KEY);
  if (want && [...$('fontFamily').options].some(o => o.value === want)) {
    $('fontFamily').value = want;
  }
  renderTextPreview();
}

/** B / I / U 三个开关。状态存在 aria-pressed 上，样式和取值都读它，只有一份真值 */
const isOn = id => $(id).getAttribute('aria-pressed') === 'true';
const setOn = (id, on) => $(id).setAttribute('aria-pressed', String(on));

for (const id of ['italic', 'underline']) {
  $(id).addEventListener('click', () => { setOn(id, !isOn(id)); renderTextPreview(); });
}
// 粗体不是独立开关，就是「字重 ≥ 700」的快捷方式 —— 两处共用一个值，
// 免得滑块说 300、按钮说粗体，谁也不知道最后到底按哪个来
$('bold').addEventListener('click', () => {
  $('fontWeight').value = isOn('bold') ? 400 : 700;
  $('fontWeight').dispatchEvent(new Event('input'));
});

let textTimer = 0;
function renderTextPreview() {
  const txt = $('text').value;
  const box = $('pvText');
  if (!txt.trim()) {
    box.classList.add('empty');
    box.textContent = '输入文字后自动预览';
    if (currentTab === 'text') lastRaster = null;
    updatePrintBtn();
    return;
  }
  const cv = renderText(txt, {
    fontSize: +$('fontSize').value,
    fontFamily: $('fontFamily').value,
    weight: +$('fontWeight').value,
    italic: isOn('italic'),
    underline: isOn('underline'),
    letterSpacing: +$('letterSpacing').value,
    align: $('align').value,
    lineSpacing: +$('lineSpacing').value,
  });
  const r = rasterize(cv, { threshold: 212 });    // 文字用 212，与 Python 一致
  box.classList.remove('empty');
  box.replaceChildren(r.preview);
  if (currentTab === 'text') lastRaster = r;
  updatePrintBtn();
}
const debouncedText = () => { clearTimeout(textTimer); textTimer = setTimeout(renderTextPreview, 180); };

$('text').addEventListener('input', debouncedText);
for (const id of ['align', 'fontFamily']) $(id).addEventListener('change', renderTextPreview);
// 选中的字体单独存 —— SETTINGS 那套只处理数字和勾选框
$('fontFamily').addEventListener('change',
  () => localStorage.setItem(FONT_SEL_KEY, $('fontFamily').value));

// 四个滑块统一注册：刷标签 → 刷摘要 → 重算预览
for (const [id, label] of [['fontSize', 'fsLabel'], ['fontWeight', 'fwLabel'],
                           ['letterSpacing', 'lspLabel'], ['lineSpacing', 'lsLabel']]) {
  $(id).addEventListener('input', () => {
    $(label).textContent = $(id).value;
    if (id === 'fontWeight') setOn('bold', +$(id).value >= 700);
    syncTextSum();
    debouncedText();
  });
}

function syncTextSum() {
  $('textSum').textContent =
    `字号 ${$('fontSize').value} · 粗细 ${$('fontWeight').value} · ` +
    `字距 ${$('letterSpacing').value} · 行距 ${$('lineSpacing').value}`;
}

/* ── 条码 ─────────────────────────────────────────────── */
// 码制下拉由 barcode.js 的清单生成，加码制只改那张表
(function initCodeSelect() {
  const sel = $('codeType');
  for (const t of CODE_TYPES) {
    const o = document.createElement('option');
    o.value = t.id;
    o.textContent = `${t.label}　${t.kind === '2d' ? '二维' : '一维'}`;
    sel.appendChild(o);
  }
  sel.value = 'qr';
})();

/** 二维码要选纠错等级，一维码要选高度 —— 两组控件按码制切换 */
function syncCodeUI() {
  const t = findType($('codeType').value);
  $('codeHint').textContent = t.hint;
  $('codeEcl').hidden = t.kind !== '2d';
  $('codeHeightField').hidden = t.kind !== '1d';
}

let codeTimer = 0;
function renderCodePreview() {
  const box = $('pvCode');
  const content = $('codeText').value.trim();
  $('codeErr').hidden = true;

  if (!content) {
    box.classList.add('empty');
    box.textContent = '输入内容后自动预览';
    if (currentTab === 'code') lastRaster = null;
    updatePrintBtn();
    return;
  }
  try {
    const cv = renderCode($('codeType').value, content, {
      ecl: $('codeEcl').value,
      height: +$('codeHeight').value,
      showText: $('codeShowText').checked,
    });
    // 画布本来就是 384 宽、纯黑白，阈值只影响下面那行说明文字
    const r = rasterize(cv, { threshold: 212 });
    box.classList.remove('empty');
    box.replaceChildren(r.preview);
    if (currentTab === 'code') lastRaster = r;
  } catch (e) {
    // 校验不过 / 内容装不下，就地说清楚哪里不对，别只留个空预览
    $('codeErr').textContent = e.message;
    $('codeErr').hidden = false;
    box.classList.add('empty');
    box.textContent = '按上面的提示改一下内容';
    if (currentTab === 'code') lastRaster = null;
  }
  updatePrintBtn();
}
const debouncedCode = () => { clearTimeout(codeTimer); codeTimer = setTimeout(renderCodePreview, 180); };

$('codeType').addEventListener('change', () => { syncCodeUI(); renderCodePreview(); });
$('codeText').addEventListener('input', debouncedCode);
$('codeEcl').addEventListener('change', renderCodePreview);
$('codeShowText').addEventListener('change', renderCodePreview);
$('codeHeight').addEventListener('input', () => {
  $('chLabel').textContent = $('codeHeight').value;
  debouncedCode();
});
$('codeSample').addEventListener('click', () => {
  $('codeText').value = findType($('codeType').value).sample;
  renderCodePreview();
});

/* ── Markdown ─────────────────────────────────────────── */
let mdTimer = 0;
function renderMdPreview() {
  const box = $('pvMd');
  const src = $('mdText').value;
  if (!src.trim()) {
    box.classList.add('empty');
    box.textContent = '输入内容后自动预览';
    if (currentTab === 'md') lastRaster = null;
    updatePrintBtn();
    return;
  }
  const cv = renderMarkdown(src, {
    fontSize: +$('mdFontSize').value,
    lineSpacing: +$('mdLineSpacing').value,
    showUrl: $('mdShowUrl').checked,
  });
  const r = rasterize(cv, { threshold: 212 });   // 与文字模式同一档，笔画不会掉
  box.classList.remove('empty');
  box.replaceChildren(r.preview);
  if (currentTab === 'md') lastRaster = r;
  updatePrintBtn();
}
const debouncedMd = () => { clearTimeout(mdTimer); mdTimer = setTimeout(renderMdPreview, 220); };

$('mdText').addEventListener('input', debouncedMd);
$('mdShowUrl').addEventListener('change', renderMdPreview);
$('mdFontSize').addEventListener('input', () => { $('mdFsLabel').textContent = $('mdFontSize').value; debouncedMd(); });
$('mdLineSpacing').addEventListener('input', () => { $('mdLsLabel').textContent = $('mdLineSpacing').value; debouncedMd(); });
$('mdSample').addEventListener('click', () => { $('mdText').value = MD_SAMPLE; renderMdPreview(); });

$('mdFile').addEventListener('change', async e => {
  const f = e.target.files?.[0];
  if (!f) return;
  try {
    $('mdText').value = await f.text();          // .md 就是纯文本，直接读
    log(`已导入 ${f.name}（${(f.size / 1024).toFixed(1)} KB）`, 'dim');
    renderMdPreview();
  } catch (err) {
    log(`读取失败：${err.message}`, 'bad');
  }
  e.target.value = '';                           // 清掉才能再选同一个文件
});

/* ── 走纸（设置浮窗里）─────────────────────────────────── */
$('thickness').addEventListener('input', () => {
  const v = +$('thickness').value;
  $('thkLabel').textContent = v === 0 ? '默认' : v;
});

$('btnFeed').addEventListener('click', async () => {
  if (!printer) return setMsg('未连接', 'bad');
  const dots = Math.max(1, +$('feedDots').value || 100);
  try {
    await printer.feedPaper(dots);
    log(`已走纸 ${dots} 点行`, 'ok');
    setMsg(`已走纸 ${dots} 点行`, 'ok');
  } catch (e) {
    log(`走纸失败：${e.message}`, 'bad');
    setMsg(`走纸失败：${e.message}`, 'bad');
  }
});

/* ── 打印 ─────────────────────────────────────────────── */
function updatePrintBtn() {
  const has = !!lastRaster;
  $('btnPrint').disabled = !printer || !has;
  $('btnPrint').textContent = has
    ? `打印（${WIDTH_DOTS}×${lastRaster.height} 点，${(lastRaster.data.length / 1024).toFixed(1)} KB）`
    : '打印';
}

$('btnPrint').addEventListener('click', async () => {
  if (!printer || !lastRaster) return;
  const btn = $('btnPrint');
  const thk = +$('thickness').value;
  btn.disabled = true;
  const t0 = performance.now();
  try {
    log(`开始打印：${WIDTH_DOTS}×${lastRaster.height}，${lastRaster.data.length} 字节`, 'dim');
    const res = await printer.printRaster(lastRaster, {
      thickness: thk === 0 ? null : thk,
      wait: $('waitAck').checked,
      onProgress: (sent, total) => {
        const pct = sent / total * 100;
        $('prog').style.width = `${pct}%`;
        // 进度条只有 3px 高，按钮上再报一个数字，隔着一米也看得见
        btn.textContent = `打印中… ${Math.round(pct)}%`;
      },
    });
    const secs = (performance.now() - t0) / 1000;
    const kbps = (lastRaster.data.length / 1024 / secs).toFixed(1);
    log(`${res.ok ? '[OK]' : '[FAIL]'} ${res.message}（${secs.toFixed(1)}s，${kbps} KB/s，` +
        `包长 ${printer.t.chunk}）`, res.ok ? 'ok' : 'bad');
    toast(res.ok ? `${res.message} · ${secs.toFixed(1)}s · ${kbps} KB/s` : res.message,
          res.ok ? 'ok' : 'bad');

    // 打完刷一次状态。失败时尤其有用 —— 能看出到底是缺纸还是开盖。
    // 只在等过 ACK 时才刷：没等 ACK 的话打印还在进行，查询字节会混进数据流。
    // 收到 ACK 后机器还在收尾（走纸、马达停转），立刻查容易没响应，缓一下再问。
    if ($('waitAck').checked) {
      await sleep(POST_PRINT_SETTLE_MS);
      await refreshStatus();
    }
  } catch (e) {
    log(`打印出错：${e.message}`, 'bad');
    toast(`打印出错：${e.message}`, 'bad');
  } finally {
    $('prog').style.width = '0';
    btn.disabled = false;
    updatePrintBtn();
  }
});

/* ── 启动 ─────────────────────────────────────────────── */
// 页面卸载时主动断开：BLE 外设被连着时不广播，残留的连接会让下次扫描
// 直接「找不到兼容的设备」。刷新前必须放手。
addEventListener('pagehide', () => { try { printer?.t?.close(); } catch { /* 来不及了 */ } });

(function boot() {
  log(`WebBluetooth ${BleTransport.isSupported() ? '可用' : '不可用'} · ` +
      `WebSerial ${SerialTransport.isSupported() ? '可用' : '不可用'}`, 'dim');
  if (!window.isSecureContext) {
    log('当前不是安全上下文，蓝牙/串口 API 全部禁用。', 'bad');
    log('请用 https:// 或 http://localhost 打开，file:// 不行。', 'dim');
  }
  if (!SerialTransport.isSupported()) {
    $('transport').querySelector('option[value=serial]').disabled = true;
  }
  // 分包上限两端不一样，提示语和默认值都跟着当前这一端走
  $('ckNote').textContent = IS_MOBILE
    ? '手机上超过 100 就会卡住，默认按 100 给'
    : '桌面实测上限 133（MTU 136），再大会卡死';
  log(`当前按${IS_MOBILE ? '手机' : '桌面'}端取默认分包 ${DEFAULT_CHUNK} 字节`, 'dim');

  loadSettings();
  syncCodeUI();
  // 字间距靠 ctx.letterSpacing，老 WebKit（iOS Bluefy）没有 —— 与其拖了没反应，
  // 不如直接锁掉并说清楚
  if (!supportsLetterSpacing()) {
    $('letterSpacing').disabled = true;
    $('lspNote').textContent = '本浏览器不支持，iOS 上用不了';
  }
  applyConnFold(localStorage.getItem(FOLD_KEY) === '1');
  syncImgSum();
  syncTextSum();
  setConnected(false);
  restoreFonts();          // 异步，慢了也不挡界面出来
})();