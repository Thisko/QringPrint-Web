/**
 * Qring 打印机驱动 —— 传输无关。
 *
 * 职责边界：
 *   本类        —— 分包收发、查询时序、ACK 等待、打印流程编排
 *   protocol.js —— 纯协议，拼字节 / 解析位
 *   raster.js   —— 图像与文本 → 光栅字节
 *   transport-* —— 只管把字节送出去、把字节收回来
 */

import {
  ACK_PRINT_DONE, CMD_BATTERY, CMD_BT_NAME, CMD_BT_VER, CMD_ENABLE, CMD_ENABLE2,
  CMD_FW, CMD_MODEL, CMD_SN, CMD_STATUS, CMD_STOP, CMD_WAKEUP,
  cmdFeed, cmdRasterHeader, cmdThickness, decodeText, findFault, parseStatus,
  stripFaultFrames, toHex,
} from './protocol.js';
import { sleep } from './rxbuffer.js';

/** 发命令后等打印机准备响应的时间，照搬 SDK 的固定套路 */
const QUERY_SETTLE_MS = 150;
const QUERY_TIMEOUT_MS = 1500;
const ACK_TIMEOUT_MS = 120000;

/**
 * 按行数估算等 ACK 的上限。热敏头大约 400 行/秒，25ms/行 留了十倍余量。
 * Python 用的是固定 120s —— 命令行下无所谓，界面上干等两分钟没法交代。
 */
const ackTimeout = rows => Math.min(ACK_TIMEOUT_MS, Math.max(15000, rows * 25));

/** 打印前后走纸点行，对应 Python 的 feed_before / feed_after */
const FEED_BEFORE = 10;
const FEED_AFTER = 100;

export class QringPrinter {
  /**
   * @param {{rx:import('./rxbuffer.js').RxBuffer, write:(u8:Uint8Array)=>Promise<any>,
   *          chunk:number, chunkDelay:number, label:string, connected:boolean}} transport
   */
  constructor(transport) {
    this.t = transport;
    this.onLog = null;        // (dir:'TX'|'RX'|'INFO', text:string) => void
    this.busy = false;
  }

  get connected() { return this.t.connected; }
  get label()     { return this.t.label; }

  // ── 底层 ────────────────────────────────────────────────

  /** 按传输层的包长分包，包间留出间隔 */
  async _send(data, onProgress) {
    this.onLog?.('TX', data.length <= 24
      ? toHex(data)
      : `${data.length} 字节 (${toHex(data.subarray(0, 12))} …)`);

    // 每轮重新读 chunk —— 传输层可能在发送途中把包长降下来（超 MTU 自动对半拆），
    // 一开始就解构出来的话，剩下的包会一直用旧的大尺寸，白白多走一遍拆包重试。
    let off = 0;
    while (off < data.length) {
      const n = Math.max(1, this.t.chunk);
      await this.t.write(data.subarray(off, off + n));
      off += n;
      if (this.t.chunkDelay) await sleep(this.t.chunkDelay);
      onProgress?.(Math.min(off, data.length), data.length);
    }
  }

  /** 清空输入 → 发命令 → 等 150ms → 收一帧 */
  async _query(cmd, { timeout = QUERY_TIMEOUT_MS } = {}) {
    this.t.rx.clear();
    await this._send(cmd);
    await sleep(QUERY_SETTLE_MS);
    return this.t.rx.collect({ timeout });
  }

  async _queryStr(cmd) {
    const r = await this._query(cmd);
    if (!r.length) return null;
    return decodeText(stripFaultFrames(r));
  }

  // ── 查询 ────────────────────────────────────────────────

  /** @returns {{ok:boolean, problems:string[], text:string, raw:number|null}} */
  async status() {
    const r = await this._query(CMD_STATUS);
    if (!r.length) return { ok: false, problems: ['无响应'], text: '无响应', raw: null };
    return { ...parseStatus(r[0]), raw: r[0] };
  }

  /** 第 2 字节才是百分比 */
  async battery() {
    const r = await this._query(CMD_BATTERY);
    return r.length >= 2 ? r[1] : null;
  }

  async info() {
    return {
      model:   await this._queryStr(CMD_MODEL),
      sn:      await this._queryStr(CMD_SN),
      fw:      await this._queryStr(CMD_FW),
      btName:  await this._queryStr(CMD_BT_NAME),
      btVer:   await this._queryStr(CMD_BT_VER),
      battery: await this.battery(),
    };
  }

  // ── 打印原语 ─────────────────────────────────────────────

  async enable() {
    await this._send(CMD_ENABLE);
    await this._send(CMD_ENABLE2);
  }

  wakeup() { return this._send(CMD_WAKEUP); }
  stop()   { return this._send(CMD_STOP); }

  setThickness(level) { return this._send(cmdThickness(level)); }

  /** n 是单字节，>255 自动拆条 */
  async feed(dots) {
    let left = Math.max(0, Math.round(dots));
    while (left > 0) {
      const n = Math.min(left, 255);
      await this._send(cmdFeed(n));
      left -= n;
    }
  }

  /** 等打印完成 ACK (0xAA)，同时盯着 FF xx 故障帧 */
  async waitAck(timeout = ACK_TIMEOUT_MS) {
    const hit = await this.t.rx.waitUntil(buf => {
      const fault = findFault(buf);
      if (fault) return { ok: false, message: fault };
      if (buf.includes(ACK_PRINT_DONE)) return { ok: true, message: '打印完成' };
      return null;
    }, timeout);
    return hit ?? {
      ok: false,
      // 没等到 ACK 基本只有一种解释：光栅数据没收全，打印机还在等剩下的字节，
      // 后续命令被它当数据吃了。断电重启能恢复。
      message: '等待 ACK 超时 —— 数据可能没收全，打印机卡在光栅接收态，建议断电重启',
    };
  }

  // ── 高层 ────────────────────────────────────────────────

  /**
   * 打印一段光栅。
   * 时序照搬 Python print_image：enable → thickness → wakeup → feed → 数据 → feed → stop
   *
   * @param {{data:Uint8Array,widthBytes:number,height:number}} raster
   */
  async printRaster(raster, {
    thickness = null,
    feedBefore = FEED_BEFORE,
    feedAfter = FEED_AFTER,
    wait = true,
    onProgress = null,
  } = {}) {
    if (this.busy) return { ok: false, message: '上一个打印任务还没结束' };
    this.busy = true;
    try {
      // 打印前体检要现查，不能读缓存 —— 用户完全可能刚掀开上盖就点了打印。
      // 但查不到状态时放行而非拦截：宁可让它试一次、失败由 ACK 阶段的故障帧兜住，
      // 也不该因为一次查询超时把用户挡在门外。
      const st = await this.status();
      if (st.raw !== null && !st.ok && !(st.raw & 0x01)) {
        return { ok: false, message: `打印机${st.text}，请处理后重试` };
      }

      this.t.rx.clear();
      await this.enable();
      if (thickness !== null) await this.setThickness(thickness);
      await this.wakeup();
      await this.feed(feedBefore);
      await this._send(cmdRasterHeader(raster.widthBytes, raster.height));
      await sleep(80);                       // 让打印机进到光栅接收态再灌数据
      await this._send(raster.data, onProgress);
      await this.feed(feedAfter);
      await this.stop();

      return wait ? await this.waitAck(ackTimeout(raster.height))
                  : { ok: true, message: '已发送' };
    } catch (e) {
      // 传输中途炸了，打印机还停在光栅接收态。尽力发一条 stop 把它收回来，
      // 否则下一次打印会接着上次的残数据走，出来是一堆乱码。
      try { await this.stop(); } catch { /* 链路已经断了，没办法 */ }
      throw e;
    } finally {
      this.busy = false;
    }
  }

  /** 单独走纸（对应 CLI 的 --feed） */
  async feedPaper(dots) {
    await this.enable();
    await this.wakeup();
    await this.feed(dots);
    await this.stop();
  }

  close() { return this.t.close(); }
}
