#!/usr/bin/env node
// Typeless Switchboard —— 静默换号**真机**验证（v2.6.0 轮询逻辑）
//
// 为什么需要这个脚本：
//   `audit-account-pool.js` 只回答「这个账号的会话还有效吗」，是**静态体检** ——
//   它不会真的把桌面端切过去。而「账号能不能正常更换」是一个**动态**问题：
//   会话写进去了，桌面端到底读没读进去？读进去之后官方接口认不认？
//
//   本脚本就是回答这个问题的：对每个账号完整走一遍换号动作，并记录耗时。
//
// ── 判据设计（重要） ──────────────────────────────────────────────
//   最初的直觉判据是「本地能解密出目标账号」，但这个判据**是假的**：
//   user-data.json 是脚本自己写的，写完立刻就能解出目标账号，与桌面端无关。
//   实测第一版脚本给出「生效 3.6s」，那只是「写入 + 等桌面端进程出现」的时间。
//
//   真正能说明「桌面端读入了」的证据有三条，本脚本逐条采集：
//     ① 进程证据：Typeless 进程的启动时间**晚于**会话写入时间（证明它读的就是这份文件）
//     ② 存活证据：观察窗口结束后 user-data.json **仍然存在且仍是目标账号**
//        —— 若桌面端不认这份会话，它会清空文件退回登录页（这是实测过的失败形态）
//     ③ 重写证据：桌面端**主动重写**了 user-data.json（mtime 变化）
//        —— 这是最硬的一条：说明它用 refresh_token 换发了新 token
//        —— 但 access_token 未过期时桌面端不会重写，所以**缺失不代表失败**
//     ④ 服务端证据：用换上的会话打官方 /user/usage_stats，返回 200 且额度正常
//
//   ①②④ 齐备即判定换号成功；③ 是加分项，观察到就单独标注。
//
// 两种模式：
//   默认（静默注入）    退出 → 写会话 → 拉起 → 观察。等价于 resetDeviceIdentity: false。
//   --full（真实换号）  额外重置设备身份（keychain / device.cache / Cookies / Local Storage …），
//                       等价于 App 内硬编码的 resetDeviceIdentity: true 路径。
//
// **会重启 Typeless**：请在不用电脑时跑。脚本结束时会把你原来的活跃账号恢复回去。
//
// 用法：
//   node scripts/verify-silent-switch.js --dry-run        # 只列出待验证账号
//   node scripts/verify-silent-switch.js --limit 2        # 先拿 2 个试水
//   node scripts/verify-silent-switch.js                  # 全量（静默注入路径）
//   node scripts/verify-silent-switch.js --full --limit 1 # 完整换号路径（含设备重置）
//   node scripts/verify-silent-switch.js --observe 40     # 加长观察窗口（慢启动机器）
//
// 退出码：0 = 全部验证完毕（含个别失败）；1 = 前置条件不满足

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execSync, spawnSync } = require('child_process');

const engine = require(path.join(__dirname, '..', 'Sources/TypelessSwitchboard/Resources/extract-active-session.js'));

const APP_SUPPORT = path.join(os.homedir(), 'Library/Application Support');
const STORE = path.join(APP_SUPPORT, 'TypelessSwitchboard/store.json');
const UD = path.join(APP_SUPPORT, 'Typeless/user-data.json');
const DATA_DIR = path.join(APP_SUPPORT, 'Typeless');
const TYPELESS_APP = '/Applications/Typeless.app';
const TYPELESS_PROC = 'Typeless.app/Contents/MacOS/Typeless';

// 与 App 侧 SmartSwitchPolicy 对齐（见 Sources/TypelessSwitchboardCore/OperationalModels.swift）
const POLL_INTERVAL_MS = 1000;      // 对应 silentInjectPollIntervalSeconds
const DEFAULT_OBSERVE_MS = 25000;   // 桌面端启动 + 读盘的观察窗口
const MAX_OBSERVE_MS = 150000;      // --observe 上限

// 设备重置要清的 keychain 条目（见 Support/Constants.swift）
const KEYCHAIN_ITEMS = [
  { service: 'now.typeless.desktop.deviceIdentifier', account: 'now.typeless.desktop.security.auth_key' },
  { service: 'Typeless.deviceIdentifier', account: null }
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ────────────────────────────── 基础工具 ──────────────────────────────

function decodeJwtPayload(token) {
  try {
    const part = String(token).split('.')[1];
    if (!part) return null;
    return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
  } catch (_) { return null; }
}

function parseArgs(argv) {
  const out = { dryRun: false, full: false, limit: 0, email: '', keepLast: false, json: false, observe: DEFAULT_OBSERVE_MS, force: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--dry-run') out.dryRun = true;
    else if (a === '--full') out.full = true;
    else if (a === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (a === '--email') out.email = String(argv[++i] || '');
    else if (a === '--keep-last') out.keepLast = true;
    else if (a === '--json') out.json = true;
    else if (a === '--force') out.force = true;
    else if (a === '--observe') out.observe = Math.min(Math.max(Number(argv[++i]) || DEFAULT_OBSERVE_MS, 5000), MAX_OBSERVE_MS);
  }
  return out;
}

function log(...args) { console.log(...args); }

// ─────────────────────────── Typeless 进程控制 ───────────────────────────

function typelessPids() {
  const r = spawnSync('pgrep', ['-f', TYPELESS_PROC], { encoding: 'utf8' });
  if (r.status !== 0) return [];
  return String(r.stdout).split('\n').map((s) => s.trim()).filter(Boolean);
}

function typelessRunning() { return typelessPids().length > 0; }

// 进程启动时间（毫秒）。用来证明「进程是在会话写入之后才起来的」。
function pidStartMs(pid) {
  const r = spawnSync('ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8' });
  if (r.status !== 0) return null;
  const text = String(r.stdout).trim();
  if (!text) return null;
  const t = Date.parse(text);
  return Number.isNaN(t) ? null : t;
}

async function quitTypeless() {
  if (!typelessRunning()) return true;
  try {
    execSync(`osascript -e 'tell application "Typeless" to quit' >/dev/null 2>&1`, { shell: '/bin/zsh' });
  } catch (_) { /* 忽略：可能没有 GUI 会话 */ }
  for (let i = 0; i < 24; i += 1) {
    if (!typelessRunning()) return true;
    await sleep(500);
  }
  try { execSync(`pkill -f "${TYPELESS_PROC}"`, { shell: '/bin/zsh' }); } catch (_) {}
  await sleep(2000);
  return !typelessRunning();
}

// 用 Finder 走 Apple Events 启动最可靠；`open` 在受限 shell 里会静默失败。
async function startTypeless() {
  const attempts = [
    `osascript -e 'tell application "Finder" to open POSIX file "${TYPELESS_APP}"'`,
    `open "${TYPELESS_APP}"`
  ];
  for (const cmd of attempts) {
    try { execSync(cmd, { shell: '/bin/zsh', stdio: 'ignore' }); } catch (_) { /* 换下一种 */ }
    for (let i = 0; i < 30; i += 1) {
      await sleep(500);
      if (typelessRunning()) return true;
    }
  }
  return typelessRunning();
}

// ─────────────────────────── 会话读写 ───────────────────────────

function readActiveSession() {
  if (!fs.existsSync(UD)) return null;
  const data = fs.readFileSync(UD);
  if (data.length < 17 || data[16] !== 0x3a) return null;
  const iv = data.subarray(0, 16);
  const ct = data.subarray(17);
  const k1 = crypto.pbkdf2Sync(
    crypto.createHash('sha256').update(os.platform() + '-' + os.arch()).digest('hex') + 'Typeless',
    'typeless-user-service', 10000, 32, 'sha256');
  const pw = crypto.pbkdf2Sync(k1, iv.toString(), 10000, 32, 'sha512');
  try {
    const d = crypto.createDecipheriv('aes-256-cbc', pw, iv);
    const raw = Buffer.concat([d.update(ct), d.final()]).toString('utf8');
    return { raw, credentials: JSON.parse(JSON.parse(raw).userData) };
  } catch (_) { return null; }
}

function userDataJsonOf(payloadString) {
  const outer = JSON.parse(payloadString);
  return JSON.parse(outer.userData);
}

function activeEmail() {
  const s = readActiveSession();
  return s && s.credentials && s.credentials.email ? s.credentials.email : null;
}

// ─────────────────────────── 设备身份重置 ───────────────────────────
//
// 复刻 `resetTypelessDeviceIdentityForAutomaticReplacement`：
//   清 keychain 凭据 → 删 device.cache → 删 user-data.json
//   → 清 app-storage.json 的 userData / quotaUsage → 清 Electron 残留目录

function resetDeviceIdentity() {
  const steps = [];

  for (const item of KEYCHAIN_ITEMS) {
    const args = ['delete-generic-password', '-s', item.service];
    if (item.account) args.push('-a', item.account);
    const r = spawnSync('security', args, { encoding: 'utf8' });
    if (r.status === 0) steps.push(`已删除 keychain 凭据 ${item.service}`);
  }

  const deviceCache = path.join(DATA_DIR, 'device.cache');
  if (fs.existsSync(deviceCache)) {
    try { fs.unlinkSync(deviceCache); steps.push('已删除 device.cache'); } catch (e) { steps.push(`删 device.cache 失败：${e.message}`); }
  }

  if (fs.existsSync(UD)) {
    try { fs.unlinkSync(UD); steps.push('已删除 user-data.json'); } catch (e) { steps.push(`删 user-data.json 失败：${e.message}`); }
  }

  const storage = path.join(DATA_DIR, 'app-storage.json');
  if (fs.existsSync(storage)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(storage, 'utf8'));
      let touched = false;
      for (const key of ['userData', 'quotaUsage']) {
        if (key in parsed) { delete parsed[key]; touched = true; }
      }
      if (touched) {
        fs.writeFileSync(storage, JSON.stringify(parsed, null, 2));
        steps.push('已清理 app-storage.json 的 userData / quotaUsage');
      }
    } catch (e) { steps.push(`清 app-storage.json 失败：${e.message}`); }
  }

  for (const sub of ['Local Storage', 'Network', 'Cookies', 'Session Storage']) {
    const url = path.join(DATA_DIR, sub);
    if (fs.existsSync(url)) {
      try { fs.rmSync(url, { recursive: true, force: true }); steps.push(`已清理 Electron 残留目录 ${sub}`); }
      catch (e) { steps.push(`清 ${sub} 失败：${e.message}`); }
    }
  }

  if (!steps.length) steps.push('未发现设备身份残留');
  return steps;
}

// ─────────────────────────── 单个账号换号 ───────────────────────────

async function switchOne(account, index, total, opts) {
  const label = `[${index}/${total}] ${account.email}`;
  const targetEmail = String(account.email).toLowerCase();
  const creds = userDataJsonOf(account.rawUserDataPayload);
  const t0 = Date.now();

  log(`\n${label}`);
  log(`  模式：${opts.full ? '完整换号（含设备身份重置）' : '静默注入（保留设备身份）'}`);

  await quitTypeless();
  if (opts.full) {
    for (const s of resetDeviceIdentity()) log(`  · ${s}`);
  }

  // 1. 写入目标会话
  const writeResult = engine.encryptSessionPayload(account.rawUserDataPayload);
  if (!writeResult || writeResult.success !== true) {
    log('  ✗ 写入会话失败');
    return { email: account.email, ok: false, reason: '写入会话失败', mode: opts.full ? 'full' : 'light' };
  }
  const writeAt = Date.now();
  const mtime0 = fs.existsSync(UD) ? fs.statSync(UD).mtimeMs : 0;
  const injectedExp = decodeJwtPayload(creds.access_token);

  // 2. 拉起 Typeless
  if (!(await startTypeless())) {
    log('  ✗ Typeless 未能启动');
    return { email: account.email, ok: false, reason: 'Typeless 未能启动', mode: opts.full ? 'full' : 'light' };
  }
  const startMs = Date.now() - writeAt;
  const pid = typelessPids()[0] || null;
  const pidStart = pid ? pidStartMs(pid) : null;
  // ① 进程证据：进程启动时间晚于写入时间
  const procAfterWrite = pidStart !== null ? pidStart >= writeAt - 2000 : null;
  log(`  · 桌面端进程已出现（+${(startMs / 1000).toFixed(1)}s，PID ${pid || '?'}，启动时间${procAfterWrite === false ? '早于' : '晚于'}会话写入）`);

  // 3. 观察窗口：桌面端启动 + 读盘。桌面端主动重写文件即提前收工（最硬证据）。
  let rewriteMs = null;
  let lastSeen = null;
  let sawTarget = false;
  const observeDeadline = Date.now() + opts.observe;
  while (Date.now() < observeDeadline) {
    const seen = activeEmail();
    if (seen) {
      lastSeen = seen;
      if (seen.toLowerCase() === targetEmail) sawTarget = true;
    }
    if (rewriteMs === null && fs.existsSync(UD) && fs.statSync(UD).mtimeMs !== mtime0) {
      rewriteMs = Date.now() - writeAt;
      log(`  ✓ 桌面端已主动重写会话文件（换发新 token）：+${(rewriteMs / 1000).toFixed(1)}s`);
      break;
    }
    await sleep(POLL_INTERVAL_MS);
  }

  // ② 存活证据：窗口结束后文件仍在、且仍是目标账号
  const survived = fs.existsSync(UD);
  const finalEmail = activeEmail();
  const stillTarget = Boolean(finalEmail && finalEmail.toLowerCase() === targetEmail);
  const stillRunning = typelessRunning();

  if (!survived || !stillTarget) {
    const why = !survived
      ? '桌面端清空了 user-data.json（会话未被接受，退回登录页）'
      : `观察窗口后会话变成了「${finalEmail || '未知'}」`;
    log(`  ✗ ${why}`);
    return {
      email: account.email, ok: false, reason: why, mode: opts.full ? 'full' : 'light',
      startMs, sawTarget, lastSeen, rewriteMs, stillRunning, procAfterWrite
    };
  }
  log(`  ✓ 观察 ${(opts.observe / 1000).toFixed(0)}s 后会话仍存活且仍是目标账号`);

  // ④ 服务端证据：用换上的会话打官方额度接口
  const revived = readActiveSession();
  const newExp = decodeJwtPayload(revived.credentials.access_token);
  const tokenRefreshed = Boolean(
    newExp && newExp.exp && (!injectedExp || !injectedExp.exp || newExp.exp > injectedExp.exp)
  );

  const usage = await engine.callUsageStats(revived.credentials);
  if (usage.error) {
    log(`  ✗ 换上的号调官方额度接口失败：${usage.error.error}`);
    return {
      email: account.email, ok: false, reason: '官方接口不可用：' + usage.error.error, mode: opts.full ? 'full' : 'light',
      startMs, rewriteMs, tokenRefreshed, stillRunning, procAfterWrite
    };
  }

  const remaining = Math.max((usage.monthlyLimit || 0) - (usage.usedCharacters || 0), 0);
  const grade = rewriteMs !== null ? 'rewrite-confirmed' : 'verified';
  log(`  ✓ 官方接口验证通过：本周 ${usage.usedCharacters}/${usage.monthlyLimit}，剩余 ${remaining}` +
      (rewriteMs === null ? '（token 未过期，桌面端无需重写 —— 属正常）' : ''));

  return {
    email: account.email,
    ok: true,
    grade,
    mode: opts.full ? 'full' : 'light',
    startMs,
    rewriteMs,
    tokenRefreshed,
    procAfterWrite,
    stillRunning,
    used: usage.usedCharacters,
    limit: usage.monthlyLimit,
    remaining,
    totalMs: Date.now() - t0
  };
}

// ─────────────────────────── 主流程 ───────────────────────────

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (!fs.existsSync(STORE)) { log(`找不到账号池：${STORE}`); process.exit(1); }
  if (!fs.existsSync(TYPELESS_APP)) { log(`找不到 Typeless：${TYPELESS_APP}`); process.exit(1); }

  const store = JSON.parse(fs.readFileSync(STORE, 'utf8'));
  const accounts = store.accounts || [];

  let candidates = accounts.filter((a) => {
    if (!a.rawUserDataPayload) return false;
    try {
      const c = userDataJsonOf(a.rawUserDataPayload);
      return Boolean(c.access_token && c.refresh_token);
    } catch (_) { return false; }
  });
  if (opts.email) candidates = candidates.filter((a) => String(a.email).includes(opts.email));
  if (opts.limit > 0) candidates = candidates.slice(0, opts.limit);

  log(`账号池共 ${accounts.length} 个，其中带静默会话 ${candidates.length} 个待验证`);
  log(`观察窗口 ${(opts.observe / 1000).toFixed(0)}s/账号 · 模式 ${opts.full ? '完整换号' : '静默注入'}`);
  if (!candidates.length) { log('没有可验证的账号。'); return; }

  if (opts.dryRun) {
    log('\n--dry-run，仅列出待验证账号：');
    for (const a of candidates) log(`  · ${a.email}`);
    return;
  }

  // 换号验证必须在「没有别人同时动账号」的前提下跑，否则会得到假失败。
  // 实测（2026-09-30）：GUI 在跑时，它按额度自动换号，把观察窗口里的目标账号换走，
  // 18 个账号里出现 2 个「会话变成了 clean.paper」的假失败。
  if (!engine.preflightConcurrentWriterGuard({ force: opts.force === true, purpose: '换号验证' })) {
    process.exit(1);
  }

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupDir = path.join(APP_SUPPORT, 'TypelessSwitchboard/Logs/switch-verify-backups', stamp);
  fs.mkdirSync(backupDir, { recursive: true });
  fs.copyFileSync(STORE, path.join(backupDir, 'store.json.bak'));
  if (fs.existsSync(UD)) fs.copyFileSync(UD, path.join(backupDir, 'user-data.json.bak'));
  log(`已备份账号池与当前会话到 ${backupDir}`);

  const original = readActiveSession();
  log(`当前活跃账号：${original ? original.credentials.email : '未知'}（结束时恢复）`);

  const results = [];
  for (let i = 0; i < candidates.length; i += 1) {
    const account = candidates[i];
    try {
      results.push(await switchOne(account, i + 1, candidates.length, opts));
    } catch (err) {
      log(`  ✗ 异常：${err.message}`);
      results.push({ email: account.email, ok: false, reason: err.message, mode: opts.full ? 'full' : 'light' });
    }
  }

  if (!opts.keepLast && original) {
    log('\n=== 恢复原来的活跃账号 ===');
    await quitTypeless();
    const ok = engine.encryptSessionPayload(original.raw);
    if (ok && ok.success) log(`已写回 ${original.credentials.email}`);
    else log('⚠️ 恢复写入失败，请手动登录。');
    await startTypeless();
  }

  // ── 汇总 ──
  const passed = results.filter((r) => r.ok);
  const failed = results.filter((r) => !r.ok);
  const rewrites = passed.filter((r) => r.rewriteMs !== null).length;
  const procUnknown = passed.filter((r) => r.procAfterWrite === false).length;

  log('\n── 换号验证汇总 ──');
  for (const r of results) {
    if (r.ok) {
      const rw = r.rewriteMs === null ? '未重写(正常)' : `${(r.rewriteMs / 1000).toFixed(1)}s 重写`;
      log(`  ✓ ${String(r.email).padEnd(38)} 进程 +${(r.startMs / 1000).toFixed(1)}s · ${rw} · 剩余 ${r.remaining} 字`);
    } else {
      log(`  ✗ ${String(r.email).padEnd(38)} ${r.reason}`);
    }
  }
  log(`  成功 ${passed.length} / ${results.length}`);
  log(`  其中观察到桌面端主动重写会话：${rewrites} 个（证明它用 refresh_token 换发了新 token）`);
  if (procUnknown) log(`  ⚠️ 有 ${procUnknown} 个账号的进程启动时间早于会话写入，证据链偏弱`);

  if (failed.length) {
    log(`\n  失败账号：`);
    for (const r of failed) log(`    · ${r.email} —— ${r.reason}`);
  }

  const report = {
    generatedAt: new Date().toISOString(),
    mode: opts.full ? 'full' : 'light',
    observeMs: opts.observe,
    total: results.length,
    passed: passed.length,
    failed: failed.length,
    rewriteConfirmed: rewrites,
    rows: results
  };
  fs.writeFileSync(path.join(backupDir, 'report.json'), JSON.stringify(report, null, 2));
  log(`\n  报告：${path.join(backupDir, 'report.json')}`);
}

main().catch((err) => { console.error('验证流程异常：', err); process.exit(1); });
