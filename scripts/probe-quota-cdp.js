#!/usr/bin/env node
// Typeless Switchboard —— 额度直读（CDP）独立探针
//
// 为什么还要一份 JS 版（Swift 里已经有 `TypelessCDPQuotaReader`）：
//   1. 用户/排障人员不装 App、不编译也能验证「我的 Typeless 到底能不能被直读」；
//   2. 两条独立实现互相校验 —— 一条读不到、另一条读得到，就说明是实现问题而不是环境问题；
//   3. 版本升级后想快速定位「客户端 chunk / 导出名又变了」，用它可以一次看全。
//
// 原理（2026-11-17 实测，Typeless 2.12.0 / Electron 43.8.4）：
//   * `POST /user/usage_stats` 有两道门：客户端签名 + JA3/TLS 指纹白名单。
//     Node 直连必然 418（ja3_tls_code），换密钥也救不回来；
//   * Typeless 自己的渲染进程当然能过。页面上的 API 客户端是可被 `import()` 的 ES 模块，
//     按「带 post + buildUrl 的对象」这个形状就能找到它，然后请它代发请求；
//   * 前提：Typeless 以 --remote-debugging-port=PORT 启动（Electron 支持，v2.7.x 文档里
//     「启动器拒绝该参数」是误判 —— 当时环境里带着 ELECTRON_RUN_AS_NODE=1，
//     Electron 退化成 node 解释器，于是把该参数当非法选项拒了）。
//
// 用法：
//   node scripts/probe-quota-cdp.js                 # 默认端口 9333
//   node scripts/probe-quota-cdp.js --port 9333
//   node scripts/probe-quota-cdp.js --launch        # 端口没起来就先带端口拉起 Typeless
//   node scripts/probe-quota-cdp.js --json          # 只输出一行 JSON（给脚本消费）
//
// 成功 exit 0；失败 exit 1，并把原因打到 stderr。

'use strict';

const DEFAULT_PORT = 9333;
const APP_PATH = '/Applications/Typeless.app';

function parseArgs(argv) {
  const args = { port: DEFAULT_PORT, launch: false, json: false, timeoutMs: 8000 };
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (item === '--port') args.port = Number(argv[++i]) || DEFAULT_PORT;
    else if (item === '--launch') args.launch = true;
    else if (item === '--json') args.json = true;
    else if (item === '--timeout') args.timeoutMs = Number(argv[++i]) || 8000;
    else if (item === '--help' || item === '-h') {
      console.log('用法: node scripts/probe-quota-cdp.js [--port 9333] [--launch] [--json] [--timeout 8000]');
      process.exit(0);
    }
  }
  if (!(args.port >= 1024 && args.port <= 65535)) args.port = DEFAULT_PORT;
  return args;
}

async function fetchJSON(url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function portReady(port, timeoutMs) {
  try {
    const version = await fetchJSON(`http://127.0.0.1:${port}/json/version`, timeoutMs);
    return version && typeof version['User-Agent'] === 'string' ? version : null;
  } catch {
    return null;
  }
}

async function launchWithDebugPort(port) {
  const { spawn } = require('node:child_process');
  const fs = require('node:fs');
  if (!fs.existsSync(APP_PATH)) {
    throw new Error(`未找到 ${APP_PATH}`);
  }
  // 关键：Electron 的 RunAsNode fuse 是开着的，环境里只要有 ELECTRON_RUN_AS_NODE=1，
  // 它就会把自己当 node 跑，--remote-debugging-port 随即被当成非法选项。
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  const child = spawn(
    `${APP_PATH}/Contents/MacOS/Typeless`,
    [`--remote-debugging-port=${port}`],
    { detached: true, stdio: 'ignore', env }
  );
  child.unref();
}

// 在渲染进程里找「App 自己的 API 客户端」并发一次 usage_stats。
// 返回 JSON 字符串（不是对象），避免 DevTools 序列化时带上 React 内部结构。
const PROBE_EXPRESSION = String.raw`(async () => {
  const out = { ok: false, error: 'no-client', tried: 0 };
  try {
    const urls = Array.from(new Set([
      ...Array.from(document.querySelectorAll('link[rel="modulepreload"]')).map((l) => l.href),
      ...Array.from(document.querySelectorAll('script[src]')).map((s) => s.src)
    ])).filter((u) => typeof u === 'string' && u.startsWith('file:') && u.includes('app.asar')
              && /\.(js|mjs)$/.test(u) && !u.includes('/static/locales/'));

    for (const url of urls) {
      out.tried += 1;
      let mod;
      try { mod = await import(url); } catch { continue; }
      for (const key of Object.keys(mod)) {
        const client = mod[key];
        if (!client || typeof client !== 'object') continue;
        if (typeof client.post !== 'function' || typeof client.buildUrl !== 'function') continue;
        try {
          const resp = await client.post('/user/usage_stats', { params: {} });
          const quota = resp && resp.success && resp.data && resp.data.data && resp.data.data.voice_transcription;
          if (!quota) { out.error = 'no-quota'; continue; }
          let auth = null;
          try { auth = await window.ipcRenderer.invoke('auth:get-current'); } catch { auth = null; }
          return JSON.stringify({
            ok: true,
            used: Number(quota.week_word_usage_value || 0),
            limit: Number(quota.week_word_usage_limit || 0),
            wpm: typeof quota.avg_wpm === 'number' ? quota.avg_wpm : null,
            minsSaved: typeof quota.mins_saved === 'number' ? quota.mins_saved : null,
            email: (auth && typeof auth.email === 'string') ? auth.email : null,
            userId: (auth && typeof auth.user_id === 'string') ? auth.user_id : null,
            chunk: url.split('/').pop(),
            tried: out.tried
          });
        } catch (error) {
          out.error = String((error && error.message) || error).slice(0, 160);
        }
      }
    }
  } catch (error) {
    out.error = String((error && error.message) || error).slice(0, 160);
  }
  return JSON.stringify(out);
})()`;

function pickTarget(targets) {
  const pages = (targets || []).filter(
    (t) => t.type === 'page' && typeof t.url === 'string' && t.url.includes('app.asar') && t.webSocketDebuggerUrl
  );
  if (!pages.length) return null;
  const rank = (t) => (t.url.includes('floating-bar') ? 0 : t.url.includes('hub.html') ? 1 : 2);
  pages.sort((a, b) => rank(a) - rank(b));
  return pages[0];
}

async function evaluate(wsUrl, expression, timeoutMs) {
  const socket = new WebSocket(wsUrl);
  const pending = new Map();
  let nextId = 1;
  let timer = null;
  const cleanup = () => {
    if (timer) clearTimeout(timer);
    try { socket.close(); } catch { /* ignore */ }
  };
  socket.onmessage = (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.id && pending.has(message.id)) {
      const resolve = pending.get(message.id);
      pending.delete(message.id);
      resolve(message);
    }
  };
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error('WebSocket 连接失败'));
    timer = setTimeout(() => reject(new Error('WebSocket 连接超时')), timeoutMs);
  });
  try {
    const response = await new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, resolve);
      socket.send(JSON.stringify({
        id,
        method: 'Runtime.evaluate',
        params: { expression, awaitPromise: true, returnByValue: true, userGesture: true }
      }));
      setTimeout(() => reject(new Error('Runtime.evaluate 超时')), timeoutMs);
    });
    if (response.error) throw new Error(response.error.message || 'Runtime.evaluate 失败');
    const result = response.result || {};
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.text || 'JS 异常');
    }
    return result.result && result.result.value;
  } finally {
    cleanup();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let version = await portReady(args.port, 2000);
  if (!version && args.launch) {
    await launchWithDebugPort(args.port);
    for (let i = 0; i < 15 && !version; i += 1) {
      await sleep(1000);
      version = await portReady(args.port, 1000);
    }
  }
  if (!version) {
    throw new Error(
      `端口 ${args.port} 没有 DevTools：Typeless 不是带 --remote-debugging-port=${args.port} 启动的` +
      `（可加 --launch 自动带端口拉起；注意环境里不能有 ELECTRON_RUN_AS_NODE=1）`
    );
  }
  const userAgent = version['User-Agent'] || '';
  if (!userAgent.includes('Typeless') && !userAgent.includes('Electron')) {
    throw new Error(`端口 ${args.port} 上不是 Typeless（UA: ${userAgent.slice(0, 80)}）`);
  }

  const targets = await fetchJSON(`http://127.0.0.1:${args.port}/json/list`, args.timeoutMs);
  const target = pickTarget(targets);
  if (!target) throw new Error('没有找到 Typeless 的渲染页面（App 可能刚启动，稍等重试）');

  const raw = await evaluate(target.webSocketDebuggerUrl, PROBE_EXPRESSION, args.timeoutMs);
  let probe;
  try { probe = JSON.parse(raw); } catch { throw new Error(`探针返回的不是 JSON：${String(raw).slice(0, 200)}`); }
  if (!probe.ok) throw new Error(`直读失败：${probe.error}（试了 ${probe.tried} 个 chunk，页面 ${target.url.split('/').pop()}）`);

  const result = {
    email: probe.email,
    userId: probe.userId,
    usedCharacters: probe.used,
    weeklyLimit: probe.limit,
    remainingCharacters: Math.max(probe.limit - probe.used, 0),
    averageWordsPerMinute: probe.wpm,
    minutesSaved: probe.minsSaved,
    clientChunk: probe.chunk,
    page: target.url.split('/').pop(),
    port: args.port
  };

  if (args.json) {
    console.log(JSON.stringify(result));
  } else {
    console.log('Typeless 额度直读成功：');
    console.log(JSON.stringify(result, null, 2));
    console.log(`—— 本周已用 ${result.usedCharacters}/${result.weeklyLimit}，剩余 ${result.remainingCharacters}`);
  }
}

main().then(() => process.exit(0)).catch((error) => {
  console.error(`✗ ${error.message}`);
  process.exit(1);
});
