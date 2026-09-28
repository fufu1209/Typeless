#!/usr/bin/env node
// Typeless Switchboard —— 账号池体检（只读）
//
// 逐个账号拿它自己的 access_token 去问官方「本周还剩多少字」，用来回答三个问题：
//   ① 这个账号还活着吗（token 还有效 / 能不能刷新）
//   ② 它本周还剩多少额度（决定该不该优先用它）
//   ③ 它带不带静默会话缓存（决定能不能秒切）
//
// **只读**：不改 store.json、不写会话缓存、不切换设备身份、不打开浏览器。
//
// verdict 分类（v2.6.0 起细化）：
//   usable         静默会话有效且还有额度 —— 可直接秒切
//   exhausted      静默会话有效但本周额度已用尽
//   token-expired  access_token 已过期、refresh_token 仍有效
//                  → 静默会话不能直接秒切，需要桌面端重新登录换取（或走全自动注册）
//   dead           access_token 与 refresh_token 均已过期 → 只能重新注册
//   no-session     从未登录过 / 缓存被清 → 只能走全自动注册
//   device-limit   被服务端判为「同一设备挂太多账号」
//   unreachable    网络异常或服务端返回未归类错误
//   payload-*      本地会话缓存损坏/不完整/邮箱对不上
//
// 用法：
//   node scripts/audit-account-pool.js                # 全量体检
//   node scripts/audit-account-pool.js --json         # 输出 JSON（给脚本消费）
//   node scripts/audit-account-pool.js --limit 5      # 只查前 5 个（调试用）
//   node scripts/audit-account-pool.js --concurrency 3

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');

// 会话/额度脚本的唯一来源（优先仓库那份，回落到 App 铺好的线上副本）
function loadEngine() {
  const candidates = [
    path.join(__dirname, '..', 'Sources/TypelessSwitchboard/Resources/extract-active-session.js'),
    path.join(os.homedir(), 'Library/Application Support/TypelessSwitchboard/extract-active-session.js')
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return require(c);
  }
  throw new Error('找不到 extract-active-session.js（App 未启动过，且不在仓库目录里跑）');
}

const engine = loadEngine();

const STORE = path.join(
  os.homedir(), 'Library/Application Support/TypelessSwitchboard/store.json'
);

function decodeJwtPayload(token) {
  try {
    const part = String(token).split('.')[1];
    if (!part) return null;
    const json = Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
    return JSON.parse(json);
  } catch (_) {
    return null;
  }
}

function hoursUntil(exp, nowSec) {
  if (!exp) return null;
  return Math.round((exp - nowSec) / 3600);
}

// 已知结论：官方对 /oauth/refresh_access_token 做了 JA3/TLS 指纹白名单校验，
// Node 与 Chromium 均无法通过（418 / code 1010101xx），只有官方 Electron 客户端在名单内。
// 这里保留一次尝试，用于「服务端将来放开」或「换到别的出口」时的探测。
function refreshAccessToken(refreshToken) {
  return new Promise((resolve) => {
    const body = JSON.stringify({ refresh_token: refreshToken });
    const req = https.request({
      hostname: engine.API_HOST,
      port: 443,
      path: '/oauth/refresh_access_token',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      timeout: 8000
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        try {
          const j = JSON.parse(data);
          const payload = j && j.data ? j.data : j;
          const token = payload && (payload.access_token || (payload.user && payload.user.access_token));
          resolve(token ? { ok: true, accessToken: token } : { ok: false, status: res.statusCode, detail: data.slice(0, 160) });
        } catch (_) {
          resolve({ ok: false, status: res.statusCode, detail: String(data).slice(0, 160) });
        }
      });
    });
    req.on('error', (e) => resolve({ ok: false, detail: e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, detail: 'timeout' }); });
    req.write(body);
    req.end();
  });
}

function parseArgs(argv) {
  const out = { json: false, limit: 0, concurrency: 3, quiet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--quiet') out.quiet = true;
    else if (a === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (a === '--concurrency') out.concurrency = Math.max(1, Number(argv[++i]) || 3);
  }
  return out;
}

function fmtAge(exp, nowSec) {
  const h = hoursUntil(exp, nowSec);
  if (h === null) return '未知';
  if (h < 0) return `已过期 ${Math.abs(Math.round(h / 24))} 天`;
  if (h < 48) return `剩 ${h} 小时`;
  return `剩 ${Math.round(h / 24)} 天`;
}

async function inspect(account, profile) {
  const row = {
    id: account.id,
    email: account.email,
    status: account.status,
    reviewState: account.reviewState,
    storedLimit: account.monthlyLimit,
    storedUsed: account.usedCharacters,
    hasSilentPayload: typeof account.rawUserDataPayload === 'string' && account.rawUserDataPayload.length > 0,
    verdict: 'unknown',
    detail: ''
  };

  if (!row.hasSilentPayload) {
    row.verdict = 'no-session';
    row.detail = '无静默会话缓存（从未登录过 / 缓存被清），只能走全自动注册换号';
    return row;
  }

  let credentials;
  try {
    const parsed = JSON.parse(account.rawUserDataPayload);
    credentials = JSON.parse(parsed.userData);
  } catch (err) {
    row.verdict = 'payload-corrupt';
    row.detail = `会话缓存解析失败：${err.message}`;
    return row;
  }

  if (!credentials.user_id || !credentials.access_token) {
    row.verdict = 'payload-incomplete';
    row.detail = '会话缓存缺 user_id / access_token';
    return row;
  }

  // 会话里的邮箱与账号池记录是否一致（不一致说明当初写错了号）
  if (credentials.email && account.email &&
      credentials.email.toLowerCase() !== account.email.toLowerCase()) {
    row.verdict = 'email-mismatch';
    row.detail = `会话邮箱 ${credentials.email} ≠ 池内邮箱 ${account.email}`;
    return row;
  }

  const accessPayload = decodeJwtPayload(credentials.access_token);
  const refreshPayload = decodeJwtPayload(credentials.refresh_token);
  const nowSec = Math.floor(Date.now() / 1000);
  row.accessTokenExpired = accessPayload && accessPayload.exp ? accessPayload.exp < nowSec : null;
  row.refreshTokenExpired = refreshPayload && refreshPayload.exp ? refreshPayload.exp < nowSec : null;
  row.accessTokenAge = accessPayload && accessPayload.exp ? fmtAge(accessPayload.exp, nowSec) : '未知';
  row.refreshTokenAge = refreshPayload && refreshPayload.exp ? fmtAge(refreshPayload.exp, nowSec) : '未知';

  // 本地就能判死的：refresh_token 也过期了，神仙难救，直接给结论，不打接口
  if (row.refreshTokenExpired === true) {
    row.verdict = 'dead';
    row.detail = `access_token(${row.accessTokenAge}) 与 refresh_token(${row.refreshTokenAge}) 均已过期，只能重新注册`;
    return row;
  }

  let result = await engine.callUsageStats(credentials, { profile });
  let authFailed = false;

  if (result.error) {
    authFailed = /HTTP 401|HTTP 403/.test(result.error.error || '') ||
                 result.error.code === 'CLIENT_NOT_SUPPORTED';
    // 会话失效时尝试刷新（已知会被 JA3 拦，保留作为探测）
    if (authFailed && credentials.refresh_token) {
      const refreshed = await refreshAccessToken(credentials.refresh_token);
      if (refreshed.ok) {
        const retryCreds = { ...credentials, access_token: refreshed.accessToken };
        result = await engine.callUsageStats(retryCreds, { profile });
        row.refreshed = true;
      } else {
        row.refreshed = false;
        row.refreshBlockedBy = refreshed.status === 418 ? 'JA3 指纹白名单' : (refreshed.status || refreshed.detail);
      }
    }
  }

  if (result.error) {
    if (result.error.code === 'DEVICE_USER_LIMIT') {
      row.verdict = 'device-limit';
    } else if (authFailed && row.accessTokenExpired) {
      // 关键分类：静默会话的 access_token 过期了，但 refresh_token 还有效
      row.verdict = 'token-expired';
      row.detail = `access_token ${row.accessTokenAge}；refresh_token 仍有效（${row.refreshTokenAge}）` +
        `；刷新接口被${row.refreshBlockedBy ? ' ' + row.refreshBlockedBy + ' 拦截' : '拒'}，需桌面端重新登录换取`;
    } else {
      row.verdict = 'unreachable';
    }
    row.errorCode = result.error.code;
    row.error = result.error.error;
    if (!row.detail) row.detail = result.error.error;
    return row;
  }

  row.used = result.usedCharacters;
  row.limit = result.monthlyLimit;
  row.remaining = Math.max((result.monthlyLimit || 0) - (result.usedCharacters || 0), 0);
  row.verdict = row.remaining > 0 ? 'usable' : 'exhausted';
  row.detail = `本周 ${row.used}/${row.limit}，剩余 ${row.remaining}`;
  return row;
}

const VERDICT_LABEL = {
  usable: '可直接秒切',
  exhausted: '额度已用尽',
  'token-expired': '静默会话过期（可重新登录复活）',
  dead: '会话彻底失效（需重新注册）',
  'no-session': '无静默会话（需注册/登录）',
  'device-limit': '设备数超限',
  unreachable: '网络/未归类异常',
  'payload-corrupt': '会话缓存损坏',
  'payload-incomplete': '会话缓存不完整',
  'email-mismatch': '会话与池内邮箱不符'
};

async function run() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(STORE)) {
    console.error(`找不到账号池：${STORE}`);
    process.exit(1);
  }
  const store = JSON.parse(fs.readFileSync(STORE, 'utf8'));
  let accounts = store.accounts || [];
  if (args.limit > 0) accounts = accounts.slice(0, args.limit);

  const profile = engine.resolveClientProfile();
  if (!args.quiet && !args.json) {
    console.log(`客户端指纹：App ${profile.appVersion} · 密钥来源 ${profile.source} · 角色交换 ${profile.swapped}`);
    console.log(`账号池：${accounts.length} 个\n`);
  }

  const rows = [];
  let cursor = 0;
  async function worker() {
    while (cursor < accounts.length) {
      const index = cursor;
      cursor += 1;
      rows[index] = await inspect(accounts[index], profile);
      if (!args.quiet && !args.json) {
        const r = rows[index];
        const mark = r.verdict === 'usable' ? '✓' : (r.verdict === 'exhausted' ? '·' : '✗');
        console.log(`${mark} ${String(index + 1).padStart(2)}. ${String(r.email).padEnd(38)} [${r.verdict}]  ${r.detail}`);
      }
      await new Promise((res) => setTimeout(res, 350)); // 温和限速，别把接口打急
    }
  }
  await Promise.all(Array.from({ length: Math.min(args.concurrency, accounts.length) }, worker));

  const summary = rows.reduce((acc, r) => {
    acc[r.verdict] = (acc[r.verdict] || 0) + 1;
    return acc;
  }, {});

  if (args.json) {
    console.log(JSON.stringify({
      generatedAt: new Date().toISOString(),
      profile: { appVersion: profile.appVersion, source: profile.source },
      total: rows.length,
      summary,
      rows
    }, null, 2));
    return;
  }

  console.log('\n── 汇总 ──');
  for (const [k, v] of Object.entries(summary).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${k.padEnd(18)} ${String(v).padStart(2)} 个   ${VERDICT_LABEL[k] || ''}`);
  }
  const usable = rows.filter((r) => r.verdict === 'usable');
  const totalRemaining = usable.reduce((s, r) => s + (r.remaining || 0), 0);
  console.log(`  可用账号合计剩余：${totalRemaining} 字`);
  const revivable = rows.filter((r) => r.verdict === 'token-expired');
  if (revivable.length) {
    console.log(`  ↳ 另有 ${revivable.length} 个账号静默会话过期但 refresh_token 仍有效，可经桌面端重新登录复活`);
  }
}

run().catch((err) => {
  console.error('体检失败：', err.message);
  process.exit(1);
});
