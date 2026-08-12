/**
 * Web Bluetooth 传输层 —— 三端通用（桌面 Chrome/Edge、Android Chrome、iOS Bluefy）
 *
 * 通道拓扑经实机逐条试出来，已固化，不再暴露给界面：
 *
 *   Service 0000ff00-0000-1000-8000-00805f9b34fb
 *     0000ff02-...  [write, writeNoResp]   ← 写。比 ISSC 那条快一倍
 *     0000ff01-...  [notify]               ← 收。响应 / 打印完成 AA / 故障帧 FF xx
 *     0000ff03-...  [notify]               ← 旁路。连接时推 01 04 / 02 64 00，用途未明
 *
 *   Service 49535343-fe7d-4ae5-8fa9-9fafd205e455  (Microchip/ISSC 透传)
 *     49535343-8841-43f4-a8d4-ecbe34729bb3        ← 也能写，但慢一倍，只作兜底
 *     49535343-1e4d-4bd9-ba61-23c647249616        ← 实测从不发东西，别订
 *
 * 两个反直觉的点，都是踩出来的：
 *
 * 1. **写和收跨 service**（用 ISSC 写时）。所以早期只订 ISSC 自带的 notify
 *    特征，等到天荒地老也收不到响应。
 *
 * 2. **FF03 必须和 FF01 分开存**。连接瞬间 FF03 会推两帧，混进 FF01 的响应流
 *    会污染第一次查询 —— 型号 "X1" 被解码成 "dX1"（0x64 就是字母 d）。
 */

import { RxBuffer, sleep } from './rxbuffer.js';

export const SVC_DATA   = '0000ff00-0000-1000-8000-00805f9b34fb';
export const CHR_WRITE  = '0000ff02-0000-1000-8000-00805f9b34fb';
export const CHR_NOTIFY = '0000ff01-0000-1000-8000-00805f9b34fb';
export const CHR_AUX    = '0000ff03-0000-1000-8000-00805f9b34fb';

/** 兜底：万一某批固件没有 FF02，退回 ISSC 透传写特征（慢，但能用） */
const SVC_ISSC = '49535343-fe7d-4ae5-8fa9-9fafd205e455';
const CHR_ISSC_WRITE = '49535343-8841-43f4-a8d4-ecbe34729bb3';

const OPTIONAL_SERVICES = [SVC_DATA, SVC_ISSC, '0000180a-0000-1000-8000-00805f9b34fb'];

/** 默认 MTU 23 → 单包 20 字节负载，永远安全的下限 */
const MIN_CHUNK = 20;

/**
 * 分包上限由各端 BLE 栈协商出来的 MTU 决定，两边实测差得挺远：
 *   桌面 Chrome / Edge          133 能过、134 起就不行（MTU 136）
 *   手机（安卓 Chrome / iOS Bluefy）  超过 100 就卡住 —— 不出纸也不回 ACK
 * 所以默认值按端来给，别让手机去踩桌面那条线。
 */
const DESKTOP_CHUNK = 133;
const MOBILE_CHUNK = 100;

/**
 * 认错方向的代价不对称：把桌面当手机只是慢一点点，把手机当桌面会直接卡死打印机。
 * 所以这里宁可宽松 —— 任何一个信号说是手机就按手机算。
 *
 * userAgentData 是 Chrome 系最准的那个（安卓请求「桌面版网站」时 UA 串会伪装成
 * 桌面，它却仍然是 true）；没有这个字段就退回 UA 串；iPadOS 13+ 报的是桌面
 * Safari 的 UA，只能靠触点数把它认出来。
 */
function detectMobile() {
  if (typeof navigator === 'undefined') return false;
  if (navigator.userAgentData?.mobile === true) return true;
  const ua = navigator.userAgent || '';
  if (/Android|iPhone|iPod|IEMobile|Mobile/i.test(ua)) return true;
  return /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
}

export const IS_MOBILE = detectMobile();
export const DEFAULT_CHUNK = IS_MOBILE ? MOBILE_CHUNK : DESKTOP_CHUNK;
/** 界面滑块上限。留出余量给 MTU 更大的批次，不代表这台机器能吃到 */
export const MAX_CHUNK = 200;

export class BleTransport {
  chunk = DEFAULT_CHUNK;
  /**
   * 带响应写每包等 ATT 确认，本身就是流控，不需要再 sleep 限速。
   *
   * 无响应写试过，快但完全没有流控：丢了字节不会有任何提示，表现是打印机
   * 卡在光栅接收态，把后续命令当数据吃掉，既不出纸也不回 ACK。已弃用。
   */
  chunkDelay = 0;
  maxRetry = 3;

  static isSupported() {
    return typeof navigator !== 'undefined' && !!navigator.bluetooth && window.isSecureContext;
  }

  static async connect({ acceptAll = false } = {}) {
    if (!navigator.bluetooth) throw new Error('本浏览器没有 Web Bluetooth。iOS 请用 Bluefy。');
    if (!window.isSecureContext) throw new Error('非安全上下文，需要 https:// 或 http://localhost');

    const device = await navigator.bluetooth.requestDevice(
      acceptAll
        ? { acceptAllDevices: true, optionalServices: OPTIONAL_SERVICES }
        : { filters: [{ namePrefix: 'Qring' }], optionalServices: OPTIONAL_SERVICES },
    );
    const t = new BleTransport(device);
    await t._attach();
    return t;
  }

  constructor(device) {
    this.device = device;
    this.rx  = new RxBuffer();      // FF01：参与协议解析
    this.aux = new RxBuffer();      // FF03：只观察

    this.onDisconnect = null;
    this.onStateChange = null;
    this.onNotify = null;           // (uuid, bytes, isMain) => void，给日志用

    this._closing = false;
    this._notified = false;

    this._handleMain = e => this._route(CHR_NOTIFY, new Uint8Array(e.target.value.buffer));
    this._handleAux  = e => this._route(CHR_AUX,    new Uint8Array(e.target.value.buffer));

    this._handleGattDisconnect = () => { this._onDrop(); };
    device.addEventListener('gattserverdisconnected', this._handleGattDisconnect);
  }

  /** 连 GATT、抓固定的那几个特征。重连时也走这条路 */
  async _attach() {
    const server = await this.device.gatt.connect();
    const data = await server.getPrimaryService(SVC_DATA);

    try {
      this.writeChar = await data.getCharacteristic(CHR_WRITE);
    } catch {
      this.writeChar = await (await server.getPrimaryService(SVC_ISSC))
        .getCharacteristic(CHR_ISSC_WRITE);
    }

    this.notifyChar = await data.getCharacteristic(CHR_NOTIFY);
    this.auxChar = null;
    try { this.auxChar = await data.getCharacteristic(CHR_AUX); } catch { /* 可选 */ }
  }

  async start() {
    await this.notifyChar.startNotifications();
    this.notifyChar.addEventListener('characteristicvaluechanged', this._handleMain);
    if (this.auxChar) {
      try {
        await this.auxChar.startNotifications();
        this.auxChar.addEventListener('characteristicvaluechanged', this._handleAux);
      } catch { /* FF03 订不上不影响打印 */ }
    }
  }

  _route(uuid, bytes) {
    const isMain = uuid === CHR_NOTIFY;
    this.onNotify?.(uuid, bytes, isMain);
    (isMain ? this.rx : this.aux).push(bytes);
  }

  // ── 掉线自愈 ─────────────────────────────────────────────

  async _onDrop() {
    if (this._closing || this._reconnecting) return;
    this._reconnecting = true;
    this.onStateChange?.('reconnecting');
    try {
      for (let i = 1; i <= 3; i++) {
        await sleep(400 * i);
        if (this._closing) return;
        try {
          await this._attach();
          await this.start();
          this.onStateChange?.('connected');
          return;
        } catch { /* 下一轮 */ }
      }
      if (!this._notified) { this._notified = true; this.onDisconnect?.(); }
    } finally {
      this._reconnecting = false;
    }
  }

  get name()      { return this.device.name || '(无名)'; }
  get label()     { return `BLE · ${this.name}`; }
  get connected() { return !!this.device.gatt?.connected; }

  // ── 发送 ────────────────────────────────────────────────

  async write(u8) {
    try {
      await this.writeChar.writeValue(u8);
      return;
    } catch (e) {
      // 超 MTU 是最常见的原因，先对半拆。
      // 拆之前必须停一下 —— Windows 的 BLE 栈在一次失败后会短暂拒绝所有操作，
      // 紧接着重试仍然失败，异常就穿出去了。
      if (u8.length > MIN_CHUNK) {
        const half = Math.max(MIN_CHUNK, u8.length >> 1);
        if (half < this.chunk) this.chunk = half;     // 记住，后续直接用小包
        await sleep(150);
        for (let off = 0; off < u8.length; off += half) {
          await this.write(u8.subarray(off, off + half));
        }
        return;
      }
      for (let i = 1; i <= this.maxRetry; i++) {
        await sleep(150 * i);
        try { await this.writeChar.writeValue(u8); return; } catch { /* 继续退避 */ }
      }
      throw e;
    }
  }

  async close() {
    this._closing = true;
    this.device.removeEventListener('gattserverdisconnected', this._handleGattDisconnect);
    this.notifyChar?.removeEventListener('characteristicvaluechanged', this._handleMain);
    this.auxChar?.removeEventListener('characteristicvaluechanged', this._handleAux);
    try { await this.notifyChar?.stopNotifications(); } catch { /* 断开中 */ }
    try { await this.auxChar?.stopNotifications(); }    catch { /* 断开中 */ }
    try { this.device.gatt.disconnect(); } catch { /* 已断开 */ }
  }
}

/** 0000ff01-0000-1000-8000-00805f9b34fb → FF01，其余取前 8 位 */
export const shortUuid = uuid =>
  /^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/.test(uuid)
    ? uuid.slice(4, 8).toUpperCase()
    : uuid.slice(0, 8);
