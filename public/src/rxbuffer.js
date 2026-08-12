/**
 * 接收缓冲。
 *
 * 响应长度不定，还会随时插入 FF xx 主动上报帧，所以不能按「读 N 字节」建模，
 * 而是滚动缓冲 + 静默期收口：等到有数据进来、且安静了 quiet 毫秒，才算一帧收完。
 */
export class RxBuffer {
  constructor(limit = 8192) {
    this.bytes = [];
    this.limit = limit;
    this.onData = null;          // (chunk: Uint8Array) => void，用于日志
  }

  push(u8) {
    for (const b of u8) this.bytes.push(b);
    if (this.bytes.length > this.limit) {
      this.bytes.splice(0, this.bytes.length - this.limit);
    }
    this.onData?.(u8);
  }

  clear()    { this.bytes.length = 0; }
  snapshot() { return Uint8Array.from(this.bytes); }
  get length() { return this.bytes.length; }

  /** 等一帧：有数据 → 安静 quiet ms → 返回；或到 timeout 返回已有的（可能为空） */
  async collect({ quiet = 90, timeout = 1500 } = {}) {
    const t0 = performance.now();
    let lastLen = this.bytes.length;
    let lastChange = t0;
    for (;;) {
      await sleep(15);
      const now = performance.now();
      if (this.bytes.length !== lastLen) {
        lastLen = this.bytes.length;
        lastChange = now;
      } else if (lastLen > 0 && now - lastChange >= quiet) {
        break;
      }
      if (now - t0 >= timeout) break;
    }
    return this.snapshot();
  }

  /** 轮询等待条件成立，用于等 ACK / 故障帧 */
  async waitUntil(predicate, timeout) {
    const t0 = performance.now();
    for (;;) {
      const hit = predicate(this.snapshot());
      if (hit) return hit;
      if (performance.now() - t0 >= timeout) return null;
      await sleep(60);
    }
  }
}

export const sleep = ms => new Promise(r => setTimeout(r, ms));
