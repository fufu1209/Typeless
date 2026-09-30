#!/usr/bin/env node
// Typeless Switchboard —— 把账号池里的额度字段刷成**服务端真实值**
//
// 背景：
//   账号池里每个账号都存着 `monthlyLimit`（周额度）与 `usedCharacters`（本周已用）。
//   这两个值只在「该账号恰好是当前活跃账号」时才会被同步刷新，其余账号存的是
//   **入池那一刻的快照**，会长期偏离真实值。
//
//   实测（2026-09-29）发现的偏差：
//     clean.paper.583366  本地记 2000，服务端真实 23333（pro_trial 档）
//     calm.field.742536   本地记 2000，服务端真实 23333（pro_trial 档）
//   偏差会直接误导 UI 的「剩余额度」，也会让「该用哪个账号」的判断失准。
//
// 为什么不需要换号：
//   每个账号的会话里都有自己的 access_token，可以直接拿它去问官方额度接口。
//   `audit-account-pool.js` 就是这么干的（只读）。本脚本是它的**可写版**：
//   同样的请求，但把结果落回 store.json。
//
// 档位标注（写进 notes 之外的独立字段，不覆盖用户备注）：
//   week_word_usage_limit = 23333 → pro_trial 档（新注册 3 天试用）
//   week_word_usage_limit = 2000  → free 档
//
// 用法：
//   node scripts/sync-account-quotas.js --dry-run    # 只看会改什么，不落盘
//   node scripts/sync-account-quotas.js              # 实际写回
//   node scripts/sync-account-quotas.js --concurrency 4

const fs = require('fs');
const os = require('os');
const path = require('path');

function loadEngine() {
  const candidates = [
    path.join(__dirname, '..', 'Sources/TypelessSwitchboard/Resources/extract-active-session.js'),
    path.join(os.homedir(), 'Library/Application Support/TypelessSwitchboard/extract-active-session.js')
  ];
  for (const c of candidates) if (fs.existsSync(c)) return require(c);
  throw new Error('找不到 extract-active-session.js');
}

const engine = loadEngine();
const STORE = path.join(os.homedir(), 'Library/Application Support/TypelessSwitchboard/store.json');

// 已知档位：额度 → 档位名。未知额度原样显示数字。
const TIER_BY_LIMIT = {
  23333: 'pro_trial',
  2000: 'free',
  8000: 'free(旧)'
};

function parseArgs(argv) {
  const out = { dryRun: false, concurrency: 3, quiet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--dry-run') out.dryRun = true;
    else if (a === '--quiet') out.quiet = true;
    else if (a === '--concurrency') out.concurrency = Math.max(1, Number(argv[++i]) || 3);
  }
  return out;
}

function credentialsOf(account) {
  if (!account.rawUserDataPayload) return null;
  try {
    return JSON.parse(JSON.parse(account.rawUserDataPayload).userData);
  } catch (_) { return null; }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(STORE)) { console.error(`找不到账号池：${STORE}`); process.exit(1); }

  const store = JSON.parse(fs.readFileSync(STORE, 'utf8'));
  const accounts = store.accounts || [];
  const profile = engine.resolveClientProfile();

  if (!args.quiet) console.log(`客户端指纹：App ${profile.appVersion} · 来源 ${profile.source}\n`);

  const changes = [];
  let cursor = 0;

  async function worker() {
    while (cursor < accounts.length) {
      const idx = cursor;
      cursor += 1;
      const acc = accounts[idx];
      const creds = credentialsOf(acc);
      if (!creds || !creds.access_token) {
        if (!args.quiet) console.log(`  · ${String(acc.email).padEnd(38)} 无会话，跳过`);
        continue;
      }
      const r = await engine.callUsageStats(creds, { profile });
      if (r.error) {
        if (!args.quiet) console.log(`  ✗ ${String(acc.email).padEnd(38)} ${r.error.error}`);
        changes.push({ email: acc.email, ok: false, error: r.error.error });
        await new Promise((res) => setTimeout(res, 350));
        continue;
      }
      const beforeLimit = acc.monthlyLimit;
      const beforeUsed = acc.usedCharacters;
      const changed = beforeLimit !== r.monthlyLimit || beforeUsed !== r.usedCharacters;
      if (changed) {
        acc.monthlyLimit = r.monthlyLimit;
        acc.usedCharacters = r.usedCharacters;
        // v2.6.6：删掉了 `acc.lastSyncedAt = ...`。`Account` 模型里没有这个字段，
        // 写进去会被 GUI 解码忽略、落盘抹掉 —— 是幽灵字段（每账号的同步时刻
        // 由状态级的 `store.lastQuotaSyncAt` 统一表达，那个字段现在真的持久化了）。
      }
      changes.push({
        email: acc.email, ok: true, changed,
        beforeLimit, beforeUsed,
        limit: r.monthlyLimit, used: r.usedCharacters,
        tier: TIER_BY_LIMIT[r.monthlyLimit] || String(r.monthlyLimit)
      });
      if (!args.quiet) {
        const mark = changed ? '✓' : '·';
        const delta = changed ? `  (原 ${beforeLimit}/${beforeUsed})` : '';
        console.log(`  ${mark} ${String(acc.email).padEnd(38)} ${r.usedCharacters}/${r.monthlyLimit} [${TIER_BY_LIMIT[r.monthlyLimit] || '?'}]${delta}`);
      }
      await new Promise((res) => setTimeout(res, 350));
    }
  }

  await Promise.all(Array.from({ length: Math.min(args.concurrency, accounts.length) }, worker));

  const updated = changes.filter((c) => c.ok && c.changed);
  const failed = changes.filter((c) => !c.ok);

  console.log(`\n── 汇总 ──`);
  console.log(`  查询成功 ${changes.filter((c) => c.ok).length} / ${changes.length}`);
  console.log(`  需要更新 ${updated.length} 个`);
  for (const c of updated) {
    console.log(`    ${String(c.email).padEnd(38)} ${c.beforeLimit}/${c.beforeUsed} → ${c.limit}/${c.used} [${c.tier}]`);
  }
  if (failed.length) {
    console.log(`  失败 ${failed.length} 个：`);
    for (const f of failed) console.log(`    ${String(f.email).padEnd(38)} ${f.error}`);
  }

  if (args.dryRun) { console.log('\n--dry-run，未写盘。'); return; }
  if (!updated.length) { console.log('\n没有需要更新的账号，未写盘。'); return; }

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupDir = path.join(os.homedir(), 'Library/Application Support/TypelessSwitchboard/Logs/quota-sync-backups');
  fs.mkdirSync(backupDir, { recursive: true });
  fs.copyFileSync(STORE, path.join(backupDir, `store.json.${stamp}.bak`));

  // v2.6.6：这个键以前写进去会被静默丢弃 —— `PersistedState` 里没有它，
  // GUI 解码时忽略、下一次落盘又抹掉，界面因此永远显示「—」。
  // 现在它是真的持久化字段了，且 GUI 落盘时会与内存值取较新者（谁晚谁准）。
  store.lastQuotaSyncAt = new Date().toISOString();
  fs.writeFileSync(STORE, JSON.stringify(store, null, 2));
  console.log(`\n✓ 已写回账号池（备份在 ${backupDir}）`);
}

main().catch((err) => { console.error('同步失败：', err.message); process.exit(1); });
