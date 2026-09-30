#!/usr/bin/env node
// Typeless Switchboard —— 会话复活（让静默会话过期的账号重新可用）
//
// 背景：
//   Typeless 的 access_token 只有 **24 小时** 有效期。账号池里存的是「抓取那一刻」的
//   会话快照，隔天就过期了。而官方对 /oauth/refresh_access_token 做了 JA3/TLS 指纹
//   白名单校验（Node、curl、Chromium 一律 418 / code 1010101xx），外部进程刷不动。
//
//   **但官方桌面端自己刷得动** —— 它启动时会拿 user-data.json 里的 refresh_token
//   换一个全新的 24h access_token 并写回文件（实测启动后 5～10 秒内完成）。
//
//   所以复活的正确姿势就是「静默换号」本身：
//     写入目标账号会话 → 拉起 Typeless → 等它自己换新 token → 读回 → 验证 → 写回账号池
//
// 实测（2026-09-29）：过期 37 天的账号，复活后 /user/usage_stats 返回 200，额度 0/2000。
//
// **会重启 Typeless**：请在不用电脑时跑。脚本结束时会把你原来的活跃账号恢复回去。
//
// 用法：
//   node scripts/revive-account-sessions.js --dry-run          # 只看哪些账号能复活
//   node scripts/revive-account-sessions.js --limit 1          # 先拿 1 个试水
//   node scripts/revive-account-sessions.js                    # 全量复活
//   node scripts/revive-account-sessions.js --email a@b.c      # 只复活指定账号
//   node scripts/revive-account-sessions.js --keep-last        # 结束时不停留在原账号（留给下一个账号）
//
// 退出码：0 = 全部处理完毕（含个别失败）；1 = 前置条件不满足

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execSync, spawnSync } = require('child_process');

const engine = require(path.join(__dirname, '..', 'Sources/TypelessSwitchboard/Resources/extract-active-session.js'));

const APP_SUPPORT = path.join(os.homedir(), 'Library/Application Support');
const STORE = path.join(APP_SUPPORT, 'TypelessSwitchboard/store.json');
const UD = path.join(APP_SUPPORT, 'Typeless/user-data.json');
const TYPELESS_APP = '/Applications/Typeless.app';

const REFRESH_TIMEOUT_MS = 90000;
const POLL_INTERVAL_MS = 2000;
// 桌面端可能连续重写多次：先换 token；若发现换不动（refresh_token 也废了），
// 它会再把文件清空并退回登录页。首次检测到 mtime 变化后必须静置这么久，
// 否则会把「清空前的中间态」当成复活成功。
const SETTLE_AFTER_REFRESH_MS = 8000;

// ────────────────────────────── 基础工具 ──────────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function decodeJwtPayload(token) {
  try {
    const part = String(token).split('.')[1];
    if (!part) return null;
    return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
  } catch (_) { return null; }
}

function parseArgs(argv) {
  const out = { dryRun: false, limit: 0, email: '', keepLast: false, verbose: true };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--dry-run') out.dryRun = true;
    else if (a === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (a === '--email') out.email = String(argv[++i] || '');
    else if (a === '--keep-last') out.keepLast = true;
    else if (a === '--quiet') out.verbose = false;
  }
  return out;
}

function log(...args) { console.log(...args); }

// ─────────────────────────── Typeless 进程控制 ───────────────────────────

function typelessRunning() {
  const r = spawnSync('pgrep', ['-f', 'Typeless.app/Contents/MacOS/Typeless'], { encoding: 'utf8' });
  return r.status === 0 && String(r.stdout).trim().length > 0;
}

async function quitTypeless() {
  try {
    execSync(`osascript -e 'tell application "Typeless" to quit' >/dev/null 2>&1 &`, { shell: '/bin/zsh' });
  } catch (_) { /* 忽略 */ }
  for (let i = 0; i < 20; i += 1) {
    if (!typelessRunning()) return true;
    await sleep(1000);
  }
  try { execSync('pkill -f "Typeless.app/Contents/MacOS/Typeless"', { shell: '/bin/zsh' }); } catch (_) {}
  await sleep(3000);
  return !typelessRunning();
}

// 用 Finder 走 Apple Events 启动最可靠；open 在受限 shell 里会静默失败。
async function startTypeless() {
  const attempts = [
    `osascript -e 'tell application "Finder" to open POSIX file "${TYPELESS_APP}"'`,
    `open "${TYPELESS_APP}"`
  ];
  for (const cmd of attempts) {
    try { execSync(cmd, { shell: '/bin/zsh', stdio: 'ignore' }); } catch (_) { /* 换下一种 */ }
    for (let i = 0; i < 15; i += 1) {
      await sleep(1000);
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

// ─────────────────────────── 复活主流程 ───────────────────────────

async function reviveOne(account, index, total, backupDir) {
  const label = `[${index}/${total}] ${account.email}`;
  const creds = userDataJsonOf(account.rawUserDataPayload);
  const oldExp = decodeJwtPayload(creds.access_token);
  log(`\n${label}`);
  log(`  写入时 access_token 过期于 ${oldExp && oldExp.exp ? new Date(oldExp.exp * 1000).toISOString() : '未知'}`);

  await quitTypeless();
  fs.mkdirSync(backupDir, { recursive: true });

  // 1. 写入目标会话
  const writeResult = engine.encryptSessionPayload(account.rawUserDataPayload);
  if (!writeResult || writeResult.success !== true) {
    log('  ✗ 写入会话失败');
    return { ok: false, reason: '写入会话失败' };
  }
  const beforeMtime = fs.statSync(UD).mtimeMs;

  // 2. 拉起 Typeless，等它自己换新 token
  const started = await startTypeless();
  if (!started) {
    log('  ✗ Typeless 未能启动');
    return { ok: false, reason: 'Typeless 未能启动' };
  }

  let refreshed = false;
  const deadline = Date.now() + REFRESH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_INTERVAL_MS);
    let mt = beforeMtime;
    try { mt = fs.statSync(UD).mtimeMs; } catch (_) { mt = -1; }  // 文件没了 = 桌面端清空了会话
    if (mt !== beforeMtime) { refreshed = true; break; }
  }
  if (!refreshed) {
    log(`  ✗ ${REFRESH_TIMEOUT_MS / 1000} 秒内桌面端未刷新会话`);
    return { ok: false, reason: '桌面端未刷新' };
  }

  // 3. 静置后读回新会话。
  //    ⚠️ mtime 变化 ≠ 复活成功。实测（2026-09-29）：
  //    access_token 过期太久（如 66 天）的账号，桌面端同样会
  //    +2.6s 重写文件，但随后发现自己也换不动 token，
  //    就把会话清空退回登录页。只看 mtime 会把这个过程误判成成功，
  //    所以下面每一步都必须验到底。
  await sleep(SETTLE_AFTER_REFRESH_MS);
  const revived = readActiveSession();
  if (!revived) {
    log('  ✗ 桌面端重写了文件，但会话已不可读（已退回登录态）');
    return { ok: false, reason: '桌面端退回登录态' };
  }

  const oldToken = String(creds.access_token || '');
  const newToken = String(revived.credentials.access_token || '');
  const newExp = decodeJwtPayload(newToken);
  const oldUid = String(creds.user_id || '');
  const newUid = String(revived.credentials.user_id || '');

  if (!newToken || newToken === oldToken) {
    log('  ✗ 桌面端重写了文件，但 access_token 没换新（刷新失败）');
    return { ok: false, reason: '桌面端未换发新 token' };
  }
  if (oldUid && newUid && oldUid !== newUid) {
    log(`  ✗ 换回的会话属于另一个账号（${oldUid} → ${newUid}），已中止写回`);
    return { ok: false, reason: '换回的会话账号不匹配' };
  }
  if (!newExp || !newExp.exp || newExp.exp * 1000 <= Date.now()) {
    log('  ✗ 换回的新 token 仍然是过期的');
    return { ok: false, reason: '新 token 仍过期' };
  }
  log(`  ✓ 桌面端已换发新 token，过期于 ${new Date(newExp.exp * 1000).toISOString()}`);

  // 4. 拿新 token 打官方接口验证（这一步才是真的「能用」）
  const usage = await engine.callUsageStats(revived.credentials);
  if (usage.error) {
    log(`  ✗ 新 token 调额度接口失败：${usage.error.error}`);
    return { ok: false, reason: '新 token 不可用：' + usage.error.error };
  }
  const remaining = Math.max((usage.monthlyLimit || 0) - (usage.usedCharacters || 0), 0);
  log(`  ✓ 官方接口验证通过：本周 ${usage.usedCharacters}/${usage.monthlyLimit}，剩余 ${remaining}`);

  return {
    ok: true,
    raw: revived.raw,
    used: usage.usedCharacters,
    limit: usage.monthlyLimit,
    remaining
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!fs.existsSync(STORE)) { log(`找不到账号池：${STORE}`); process.exit(1); }
  if (!fs.existsSync(TYPELESS_APP)) { log(`找不到 Typeless：${TYPELESS_APP}`); process.exit(1); }

  const store = JSON.parse(fs.readFileSync(STORE, 'utf8'));
  const accounts = store.accounts || [];
  const nowSec = Math.floor(Date.now() / 1000);

  // 候选：有静默会话 + access_token 已过期 + refresh_token 仍有效
  let candidates = accounts.filter((a) => {
    if (!a.rawUserDataPayload) return false;
    let c;
    try { c = userDataJsonOf(a.rawUserDataPayload); } catch (_) { return false; }
    if (!c.access_token || !c.refresh_token) return false;
    const at = decodeJwtPayload(c.access_token);
    const rt = decodeJwtPayload(c.refresh_token);
    const atExpired = at && at.exp ? at.exp < nowSec : false;
    const rtValid = rt && rt.exp ? rt.exp > nowSec : true;
    return atExpired && rtValid;
  });
  if (args.email) candidates = candidates.filter((a) => String(a.email).includes(args.email));
  if (args.limit > 0) candidates = candidates.slice(0, args.limit);

  log(`账号池共 ${accounts.length} 个，其中「会话过期但可复活」${candidates.length} 个`);
  if (!candidates.length) { log('没有需要复活的账号。'); return; }

  if (args.dryRun) {
    log('\n--dry-run，仅列出待复活账号：');
    for (const a of candidates) log(`  · ${a.email}`);
    return;
  }

  // 备份
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupDir = path.join(APP_SUPPORT, 'TypelessSwitchboard/Logs/revive-backups', stamp);
  fs.mkdirSync(backupDir, { recursive: true });
  fs.copyFileSync(STORE, path.join(backupDir, 'store.json.bak'));
  if (fs.existsSync(UD)) fs.copyFileSync(UD, path.join(backupDir, 'user-data.json.bak'));
  log(`已备份账号池与当前会话到 ${backupDir}`);

  const original = readActiveSession();
  const results = [];

  for (let i = 0; i < candidates.length; i += 1) {
    const account = candidates[i];
    try {
      const r = await reviveOne(account, i + 1, candidates.length, backupDir);
      results.push({ email: account.email, ...r });
      if (r.ok) {
        // 写回账号池
        const fresh = JSON.parse(fs.readFileSync(STORE, 'utf8'));
        const idx = (fresh.accounts || []).findIndex((x) => x.id === account.id);
        if (idx >= 0) {
          fresh.accounts[idx].rawUserDataPayload = r.raw;
          fresh.accounts[idx].usedCharacters = r.used;
          fresh.accounts[idx].monthlyLimit = r.limit;
          fresh.accounts[idx].lastSyncedAt = new Date().toISOString();
          fs.writeFileSync(STORE, JSON.stringify(fresh, null, 2));
          log('  ✓ 已写回账号池');
        }
      }
    } catch (err) {
      log(`  ✗ 异常：${err.message}`);
      results.push({ email: account.email, ok: false, reason: err.message });
    }
  }

  // 恢复原活跃账号
  if (!args.keepLast && original) {
    log('\n=== 恢复原来的活跃账号 ===');
    await quitTypeless();
    const ok = engine.encryptSessionPayload(original.raw);
    if (ok && ok.success) log('已恢复。');
    else log('⚠️ 恢复写入失败，请手动登录。');
    await startTypeless();
  }

  const okCount = results.filter((r) => r.ok).length;
  log('\n── 复活汇总 ──');
  for (const r of results) log(`  ${r.ok ? '✓' : '✗'} ${String(r.email).padEnd(38)} ${r.ok ? `剩余 ${r.remaining} 字` : r.reason}`);
  log(`  成功 ${okCount} / ${results.length}`);
  log(`  备份在 ${backupDir}`);
}

main().catch((err) => { console.error('复活流程异常：', err); process.exit(1); });
