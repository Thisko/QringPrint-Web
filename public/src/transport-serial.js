/**
 * Web Serial 传输层 —— 桌面加速通道（Windows/Linux/macOS 的 Chrome / Edge）
 *
 * 走的是系统蓝牙配对后生成的虚拟串口，等价于 Python 的 SerialTransport。
 * 比 BLE 快一个量级，桌面上有就用。
 *
 * 移动端没有这个 API：Android Chrome 和 iOS Bluefy 都不实现 Web Serial，
 * 所以它只能是加分项，底座仍然是 BLE。
 *
 * 坑：Windows 配对会生成「传出」和「传入」两个 COM 口，只有传出那个能通。
 *     选错了表现为一切正常但收不到任何字节。
 */

import { RxBuffer } from './rxbuffer.js';

export class SerialTransport {
  chunk = 1024;        // 与 Python CHUNK 一致
  chunkDelay = 1;      // 包间 1ms

  static isSupported() {
    return typeof navigator !== 'undefined' && !!navigator.serial && window.isSecureContext;
  }

  static async connect({ baudRate = 115200 } = {}) {
    if (!navigator.serial) throw new Error('本浏览器没有 Web Serial（仅桌面 Chrome/Edge）');
    const port = await navigator.serial.requestPort();
    await port.open({ baudRate });
    const t = new SerialTransport(port);
    return t;
  }

  constructor(port) {
    this.port = port;
    this.rx = new RxBuffer();
    this.onDisconnect = null;
    this._closing = false;
  }

  async start() {
    this.writer = this.port.writable.getWriter();
    this.reader = this.port.readable.getReader();
    this._pump();
  }

  async _pump() {
    try {
      for (;;) {
        const { value, done } = await this.reader.read();
        if (done) break;
        if (value?.length) this.rx.push(value);
      }
    } catch {
      // 拔线 / 关闭都会走到这
    } finally {
      if (!this._closing) this.onDisconnect?.();
    }
  }

  get label()     { return '串口 · COM'; }
  get connected() { return !this._closing && !!this.writer; }

  write(u8) { return this.writer.write(u8); }

  async close() {
    this._closing = true;
    try { await this.reader?.cancel(); }  catch { /* ignore */ }
    try { this.reader?.releaseLock(); }   catch { /* ignore */ }
    try { this.writer?.releaseLock(); }   catch { /* ignore */ }
    try { await this.port.close(); }      catch { /* ignore */ }
  }
}
