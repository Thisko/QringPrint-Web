/**
 * 零依赖静态服务器 —— node serve.js [端口]
 *
 * 存在的理由：ES 模块在 file:// 下会被 CORS 拦掉，
 * Web Bluetooth / Web Serial 也要求安全上下文，
 * 所以这个项目必须经 http://localhost 或 https:// 打开。
 *
 * 绑 0.0.0.0，同局域网的手机可以直接连（会打印出局域网地址）。
 */

import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('./public/', import.meta.url));
const PORT = Number(process.argv[2]) || 3000;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.ico':  'image/x-icon',
};

const server = createServer(async (req, res) => {
  let rel = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (rel.endsWith('/')) rel += 'index.html';

  // 目录穿越防护：规范化后必须仍在 ROOT 内
  const path = normalize(join(ROOT, rel));
  if (!path.startsWith(ROOT.endsWith(sep) ? ROOT : ROOT + sep)) {
    res.writeHead(403).end('403');
    return;
  }

  try {
    const st = await stat(path);
    if (st.isDirectory()) throw new Error('dir');
    res.writeHead(200, {
      'Content-Type': MIME[extname(path).toLowerCase()] ?? 'application/octet-stream',
      'Content-Length': st.size,
      'Cache-Control': 'no-store',        // 改完刷新就生效，不用清缓存
    });
    createReadStream(path).pipe(res);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('404 ' + rel);
  }
});

server.listen(PORT, '0.0.0.0', () => {
  const lan = Object.values(networkInterfaces()).flat()
    .filter(i => i && i.family === 'IPv4' && !i.internal)
    .map(i => i.address);

  console.log(`\n  QringPrint 本地服务已启动\n`);
  console.log(`  电脑:  http://localhost:${PORT}/`);
  for (const ip of lan) console.log(`  局域网: http://${ip}:${PORT}/`);
  console.log(`\n  探针:  http://localhost:${PORT}/ble-probe.html`);
  console.log(`\n  注意: 局域网地址是 http，手机上 Web Bluetooth 会被拦。`);
  console.log(`        安卓可在 chrome://flags/#unsafely-treat-insecure-origin-as-secure`);
  console.log(`        里把上面的局域网地址加白名单；iOS Bluefy 必须 https。\n`);
  console.log(`  Ctrl+C 停止\n`);
});
