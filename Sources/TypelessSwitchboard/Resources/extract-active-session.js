// Typeless Switchboard —— 本地会话读取 + 官方周额度同步
//
// 这是**唯一**的会话/额度脚本实现。
//   * App 启动时由 `SwitchboardStore.ensureExtractScript()` 从 App 包内 Resources
//     复制到 `~/Library/Application Support/TypelessSwitchboard/`，再以 `node` 调用。
//   * 想改签名/接口逻辑，只改这一个文件。
//   （v2.6.0 之前这里有两份实现：仓库 scripts/ 一份、Swift 源码里内嵌字符串一份，
//     两份各自演化、最终分叉 —— 线上跑的那份和仓库里的那份已经不是同一个东西。）
//
// 被 require 时导出函数，直接执行时走 CLI：
//   node extract-active-session.js                # 解密会话 + 拉本周额度
//   node extract-active-session.js --local-only   # 只解密会话，不请求额度 API
//   node extract-active-session.js --dump-profile # 打印客户端指纹（版本/密钥来源），不发请求

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');

const APP_SUPPORT = path.join(process.env.HOME, 'Library/Application Support/Typeless');
const API_HOST = 'api.typeless.com';
const USAGE_PATH = '/user/usage_stats';

// 兜底密钥（Typeless 2.8.0 实测有效）。
// 正常情况下会被 `resolveClientProfile()` 从本机 app.asar 现场提取的值覆盖 ——
// Typeless **每次大版本升级都轮换这两把密钥**（2.4.0 → 2.7.0 → 2.8.0 各轮换过一次），
// 硬编码的写法一升级就整条额度链路失效：2.4.0 → 2.7.0 那次就是这么静默坏掉的，
// 守护连续失败两周没人发现。所以这里只是「asar 读不到时的最后一道兜底」，
// 真正生效的永远是现场提取值。
const FALLBACK_AES_KEY = '3fa18880eef69a2c05a6a48a532a36d2b386aa209b55cfca2080a00e';
const FALLBACK_HMAC_KEY = '68cea363847f8e3d02a527f9dbcdf508a58dc81558b2e7056e82e48e';
const FALLBACK_APP_VERSION = '2.8.0';

// 加密负载里那个固定键（官方代码里的字面量，不是密钥，是负载字段名）
const CONTEXT_FIELD = '3c86e26ccbb7274f752e7d868a1541ebfb7f37e7';

// ────────────────────────────── 错误分类 ──────────────────────────────

function looksLikeDeviceUserLimit(text) {
  if (!text) return false;
  const lower = String(text).toLowerCase();
  const spaced = lower.replace(/\s+/g, ' ');
  const compact = lower.replace(/\s+/g, '');
  return (
    spaced.includes('number of users logged into this device has exceeded the limit') ||
    spaced.includes('users logged into this device has exceeded') ||
    spaced.includes('device has exceeded the limit') ||
    spaced.includes('device user limit') ||
    spaced.includes('too many users on this device') ||
    compact.includes('numberofusersloggedintothisdevicehasexceededthelimit') ||
    compact.includes('usersloggedintothisdevicehasexceeded') ||
    compact.includes('devicehasexceededthelimit') ||
    compact.includes('deviceuserlimit') ||
    compact.includes('toomanyusersonthisdevice') ||
    spaced.includes('登录该设备的用户数已超过限制') ||
    spaced.includes('设备登录用户数已超') ||
    spaced.includes('设备用户数超限') ||
    spaced.includes('此设备登录的用户数已超过限制')
  );
}

/// Typeless 2.7.0 起，官方接口会拒绝「非官方客户端」的请求（HTTP 403 / code 20006）。
/// 这**不是**网络抖动，重试一万次也没用 —— 必须让上层明确报出来，
/// 而不是像 2.4.0→2.7.0 那次一样被当成「额度没刷新」静默跳过。
function looksLikeClientNotSupported(text) {
  if (!text) return false;
  const lower = String(text).toLowerCase();
  return (
    lower.includes('this client is not supported') ||
    lower.includes('please use the official typeless app') ||
    lower.includes('"code":20006') ||
    lower.includes('20006')
  );
}

function summarizeApiError(statusCode, bodyText) {
  const compact = String(bodyText || '').replace(/\s+/g, ' ').trim().slice(0, 400);
  let message = '';
  try {
    const parsed = JSON.parse(bodyText || '{}');
    message = parsed.message || parsed.error || parsed.detail || parsed.msg || '';
    if (!message && parsed.data && typeof parsed.data === 'object') {
      message = parsed.data.message || parsed.data.error || '';
    }
  } catch (_) {}
  const combined = [message, compact].filter(Boolean).join(' | ');
  if (looksLikeDeviceUserLimit(combined) || looksLikeDeviceUserLimit(bodyText)) {
    return {
      code: 'DEVICE_USER_LIMIT',
      error: `设备登录用户数已超限 (HTTP ${statusCode}): ${combined || 'The number of users logged into this device has exceeded the limit.'}`
    };
  }
  if (looksLikeClientNotSupported(combined) || looksLikeClientNotSupported(bodyText)) {
    return {
      code: 'CLIENT_NOT_SUPPORTED',
      error: `Typeless 官方拒绝本客户端 (HTTP ${statusCode})：客户端指纹已过期，需要重新从 app.asar 提取签名密钥。${combined}`
    };
  }
  return {
    code: statusCode === 200 ? 'API_PAYLOAD_MISMATCH' : 'API_HTTP_ERROR',
    error: statusCode === 200
      ? (combined ? `API 返回格式不匹配：${combined}` : 'API 返回格式不匹配')
      : `API 额度拉取失败 (HTTP ${statusCode})${combined ? ': ' + combined : ''}`
  };
}

// ─────────────────────────── 客户端指纹（版本 + 密钥） ───────────────────────────

function readTypelessAppVersion() {
  // 1) 装在 /Applications 的官方 App，Info.plist 最权威
  try {
    const plist = fs.readFileSync('/Applications/Typeless.app/Contents/Info.plist', 'utf8');
    const m = plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/);
    if (m && m[1]) return m[1].trim();
  } catch (_) {}
  // 2) 官方 App 自己写的版本文件
  try {
    const v = fs.readFileSync(path.join(APP_SUPPORT, 'last_version.txt'), 'utf8').trim();
    if (v) return v;
  } catch (_) {}
  // 3) electron-store 的迁移版本号
  for (const f of ['app-storage.json', 'app-onboarding.json']) {
    try {
      const j = JSON.parse(fs.readFileSync(path.join(APP_SUPPORT, f), 'utf8'));
      const v = j && j.__internal__ && j.__internal__.migrations && j.__internal__.migrations.version;
      if (v) return String(v);
    } catch (_) {}
  }
  return '';
}

/// 从本机 Typeless 的 app.asar 里现场提取两把 56 位十六进制密钥。
///
/// 官方把密钥放在混淆字符串表里，但**字面量本身是明文**，
/// 且整个包里符合「56 位小写十六进制」的字符串恰好只有这两把。
/// 不去解混淆表（那要复现它的轮转校验），只做「按形状捞」——
/// 换版本时形状不变，捞法就依然有效。
function extractKeysFromAsar() {
  const asarPath = '/Applications/Typeless.app/Contents/Resources/app.asar';
  let buf;
  try {
    buf = fs.readFileSync(asarPath);
  } catch (_) {
    return null;
  }
  const text = buf.toString('utf8');
  const found = new Set();
  const re = /'([0-9a-f]{56})'/g;
  let m;
  while ((m = re.exec(text)) !== null) found.add(m[1]);
  const keys = Array.from(found);
  if (keys.length !== 2) return null;
  return keys;
}

function readTimeDiff() {
  try {
    const j = JSON.parse(fs.readFileSync(path.join(APP_SUPPORT, 'app-storage.json'), 'utf8'));
    const v = Number(j.TYPELESS_TIME_DIFF);
    return Number.isFinite(v) ? v : 0;
  } catch (_) {
    return 0;
  }
}

function readDeviceId() {
  for (const f of ['app-storage.json', 'app-settings.json']) {
    try {
      const j = JSON.parse(fs.readFileSync(path.join(APP_SUPPORT, f), 'utf8'));
      if (j.TYPELESS_DEVICE_ID) return String(j.TYPELESS_DEVICE_ID);
    } catch (_) {}
  }
  return '';
}

function browserFingerprint() {
  const ua = (typeof navigator !== 'undefined' && navigator.userAgent) || '';
  const grab = (marker) => {
    const m = ua.match(new RegExp(marker.replace(/[/.]/g, '\\$&') + '/([\\d.]+)'));
    return m ? m[1] : 'unknown';
  };
  let name = 'unknown', version = 'unknown';
  if (ua.includes('Chrome')) { name = 'Chrome'; version = grab('Chrome'); }
  else if (ua.includes('Edg')) { name = 'Edge'; version = grab('Edg'); }
  else if (ua.includes('Firefox')) { name = 'Firefox'; version = grab('Firefox'); }
  else if (ua.includes('Safari')) { name = 'Safari'; version = grab('Version'); }
  return { name, version, major: (version || '').split('.')[0] || 'unknown' };
}

function profileCachePath() {
  const dir = path.join(process.env.HOME, 'Library/Application Support/TypelessSwitchboard');
  return path.join(dir, 'client-profile.json');
}

function readProfileCache() {
  try {
    return JSON.parse(fs.readFileSync(profileCachePath(), 'utf8'));
  } catch (_) {
    return null;
  }
}

function writeProfileCache(profile) {
  try {
    const p = profileCachePath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify(profile, null, 2));
  } catch (_) {}
}

/// 解析出本次要用的客户端指纹。
///
/// 顺序：缓存（版本一致才用）→ 现场从 app.asar 提取 → 兜底常量。
/// 密钥角色（哪把是 AES 口令、哪把是 HMAC 密钥）无法从字符串本身判断，
/// 由 `callUsageStats` 在收到 20006 时交换一次重试来定，定完写回缓存。
function resolveClientProfile(options = {}) {
  const version = readTypelessAppVersion() || FALLBACK_APP_VERSION;
  const forceRefresh = options.forceRefresh === true;
  const cache = readProfileCache();

  if (!forceRefresh && cache && cache.appVersion === version && cache.aesKey && cache.hmacKey) {
    return {
      appVersion: version,
      aesKey: cache.aesKey,
      hmacKey: cache.hmacKey,
      source: 'cache',
      swapped: cache.swapped === true
    };
  }

  const extracted = extractKeysFromAsar();
  if (extracted && extracted.length === 2) {
    // 顺序未知，先按 asar 里的字面顺序试；失败会自动交换。
    const profile = {
      appVersion: version,
      aesKey: extracted[0],
      hmacKey: extracted[1],
      source: 'asar',
      swapped: false
    };
    writeProfileCache(profile);
    return profile;
  }

  return {
    appVersion: version,
    aesKey: FALLBACK_AES_KEY,
    hmacKey: FALLBACK_HMAC_KEY,
    source: 'fallback',
    swapped: false
  };
}

function swappedProfile(profile) {
  const next = {
    appVersion: profile.appVersion,
    aesKey: profile.hmacKey,
    hmacKey: profile.aesKey,
    source: profile.source,
    swapped: profile.swapped !== true
  };
  writeProfileCache(next);
  return next;
}

// ─────────────────────────────── 会话解密 ───────────────────────────────

function sessionDerivedPassword(iv) {
  const sha256Hex = crypto.createHash('sha256').update(os.platform() + '-' + os.arch()).digest('hex');
  const pbkdf2Key = crypto.pbkdf2Sync(sha256Hex + 'Typeless', 'typeless-user-service', 10000, 32, 'sha256');
  return crypto.pbkdf2Sync(pbkdf2Key, iv.toString(), 10000, 32, 'sha512');
}

function decryptActiveSession() {
  const userdataPath = path.join(APP_SUPPORT, 'user-data.json');
  if (!fs.existsSync(userdataPath)) {
    return { success: false, error: '未检测到 Typeless 客户端的登录缓存文件' };
  }
  const data = fs.readFileSync(userdataPath);
  if (data.length < 17 || data[16] !== 0x3a) {
    return { success: false, error: '登录缓存文件格式不正确或已损坏' };
  }
  const iv = data.subarray(0, 16);
  const ciphertext = data.subarray(17);
  let rawJsonString = '';
  let credentials;
  try {
    const decipher = crypto.createDecipheriv('aes-256-cbc', sessionDerivedPassword(iv), iv);
    const dec = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    rawJsonString = dec.toString('utf8');
    credentials = JSON.parse(JSON.parse(rawJsonString).userData);
  } catch (_) {
    return { success: false, error: '本地缓存解密失败，可能是指纹不匹配或客户端已退出' };
  }
  if (!credentials.access_token || !credentials.user_id) {
    return { success: false, error: '登录缓存中未包含有效的授权 Token' };
  }
  return { success: true, credentials, rawJson: rawJsonString };
}

/// 把一份 userData JSON 写回 Typeless 的本地会话缓存（静默换号用）。
function encryptSessionPayload(rawJsonString) {
  const plaintext = Buffer.from(rawJsonString, 'utf8');
  const iv = crypto.randomBytes(16);
  const derivedPassword = sessionDerivedPassword(iv);
  const cipher = crypto.createCipheriv('aes-256-cbc', derivedPassword, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const out = Buffer.concat([iv, Buffer.from(':'), ciphertext]);
  const userdataPath = path.join(APP_SUPPORT, 'user-data.json');
  fs.mkdirSync(path.dirname(userdataPath), { recursive: true });
  fs.writeFileSync(userdataPath, out);
  return { success: true };
}

// ──────────────────── 请求签名（2.7.0 起，2.8.0 实测协议一致）────────────────────
//
// 2.4.0 及以前：X-Authorization = AES( HMAC-SHA1(sign_str, `${t}:${secret}`) )，
//              sign_str 用秒级时间戳，版本串 mac_2.0.0，密钥 yc 写死在脚本里。
// 2.7.0 起：  时间戳改成毫秒 + 官方客户端的时差校正；
//             版本串跟真实 App 版本；HMAC 密钥轮换；
//             X-Authorization 变成「整包加密的 JSON 负载」，而不是单独一个摘要。

function aesEncryptOpenSSL(plaintext, passphrase) {
  // 复刻 crypto-js `AES.encrypt(msg, passphrase).toString()`：
  // OpenSSL 兼容格式 —— 8 字节随机 salt，EVP_BytesToKey(MD5) 派生 key/iv，AES-256-CBC，
  // 输出 "Salted__" + salt + ciphertext 的 base64。
  const salt = crypto.randomBytes(8);
  let derived = Buffer.alloc(0);
  let block = Buffer.alloc(0);
  while (derived.length < 48) {
    block = crypto.createHash('md5').update(Buffer.concat([block, Buffer.from(passphrase, 'utf8'), salt])).digest();
    derived = Buffer.concat([derived, block]);
  }
  const key = derived.subarray(0, 32);
  const iv = derived.subarray(32, 48);
  const cipher = crypto.createCipheriv('aes-256-cbc', key, iv);
  const ct = Buffer.concat([cipher.update(Buffer.from(plaintext, 'utf8')), cipher.final()]);
  return Buffer.concat([Buffer.from('Salted__', 'utf8'), salt, ct]).toString('base64');
}

function buildSignedHeaders(credentials, profile, pathname, nowMs) {
  const reqTime = (nowMs !== undefined ? nowMs : Date.now()) + readTimeDiff();
  const appVersion = 'mac_' + String(profile.appVersion).split('-')[0];
  const userId = credentials.user_id;
  const signStr = `${reqTime}:${appVersion}:${pathname}:${userId}`;
  const secretKey = `${reqTime}:${profile.hmacKey}`;
  const hash = crypto.createHmac('sha1', secretKey).update(signStr).digest('hex');
  const b = browserFingerprint();
  const random = String(Math.floor(100000 + Math.random() * 900000));
  const payload = {
    'X-Env': 'prod',
    'X-Client-Domain': '',
    'X-Client-Path': '',
    'X-Random': random,
    't': reqTime,
    'p': hash,
    'd': readDeviceId() || 'UNKNOWN',
    [CONTEXT_FIELD]: { a: '' }
  };
  return {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'Authorization': 'Bearer ' + credentials.access_token,
    'X-Browser-Name': b.name,
    'X-Browser-Version': b.version,
    'X-Browser-Major': b.major,
    'X-App-Version': appVersion,
    'X-Client-Domain': '',
    'X-Client-Path': '',
    'X-Random': random,
    'X-Env': 'prod',
    'X-Authorization': aesEncryptOpenSSL(JSON.stringify(payload), profile.aesKey),
    'User-Agent': `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Typeless/${profile.appVersion} Chrome/130.0.6723.137 Electron/33.4.11 Safari/537.36`
  };
}

function requestUsageStats(credentials, headers) {
  return new Promise((resolve) => {
    const req = https.request({
      hostname: API_HOST,
      port: 443,
      path: USAGE_PATH,
      method: 'POST',
      headers,
      timeout: 8000
    }, (res) => {
      let body = '';
      res.on('data', (c) => body += c);
      res.on('end', () => resolve({ statusCode: res.statusCode, body }));
    });
    req.on('error', (e) => resolve({ statusCode: 0, body: 'ERR ' + e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ statusCode: 0, body: 'TIMEOUT' }); });
    req.write(JSON.stringify({}));
    req.end();
  });
}

function parseUsageBody(statusCode, body) {
  if (statusCode !== 200) return { error: summarizeApiError(statusCode, body) };
  try {
    const respObj = JSON.parse(body);
    if (respObj.status === 'OK' && respObj.data && respObj.data.voice_transcription) {
      const vt = respObj.data.voice_transcription;
      return {
        usedCharacters: vt.week_word_usage_value,
        monthlyLimit: vt.week_word_usage_limit,
        info: `总字数: ${vt.total_words}, 已用秒数: ${Math.round(vt.total_audio_seconds)}秒`
      };
    }
  } catch (_) {}
  return { error: summarizeApiError(200, body) };
}

/// 拉一次官方周额度。收到 20006（客户端不受支持）时按**递进阶梯**重试。
///
/// 20006 只有两个成因，且外观完全一样：
///   a) 两把密钥的**角色**猜反了（哪把当 AES 口令、哪把当 HMAC 密钥）；
///   b) 官方**轮换了密钥**，本地缓存/兜底值已经作废。
///
/// 旧实现「只重试一次」覆盖不全：缓存来源的指纹遇到 (a)+(b) 同时发生时，
/// 第一次强制重提后角色仍然猜反，就直接判失败了。
/// 现在按来源排出一条四段阶梯，逐段升级到「重新提取 + 交换角色」。
async function callUsageStats(credentials, options = {}) {
  let profile = options.profile || resolveClientProfile();

  const refresh = () => resolveClientProfile({ forceRefresh: true });
  const ladder = profile.source === 'asar'
    // 现场提取的密钥是对的 ⇒ 只可能是角色猜反，先换角色再考虑重新提取
    ? [() => swappedProfile(profile), () => refresh(), () => swappedProfile(refresh())]
    // 缓存/兜底 ⇒ 先重新提取（多半是版本升级导致轮换），再考虑角色
    : [() => refresh(), () => swappedProfile(refresh()), () => swappedProfile(profile)];

  for (let step = 0; step <= ladder.length; step += 1) {
    const headers = buildSignedHeaders(credentials, profile, USAGE_PATH);
    const res = await requestUsageStats(credentials, headers);
    const parsed = parseUsageBody(res.statusCode, res.body);
    if (!parsed.error || parsed.error.code !== 'CLIENT_NOT_SUPPORTED') {
      return { ...parsed, profile };
    }
    if (step < ladder.length) profile = ladder[step]();
  }
  return { error: { code: 'CLIENT_NOT_SUPPORTED', error: '客户端指纹重试后仍被拒绝' }, profile };
}

// ─────────────────────────────── CLI ───────────────────────────────

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--dump-profile')) {
    const p = resolveClientProfile({ forceRefresh: argv.includes('--refresh') });
    console.log(JSON.stringify({
      success: true,
      appVersion: p.appVersion,
      source: p.source,
      swapped: p.swapped,
      aesKeyFingerprint: crypto.createHash('sha256').update(p.aesKey).digest('hex').slice(0, 16),
      hmacKeyFingerprint: crypto.createHash('sha256').update(p.hmacKey).digest('hex').slice(0, 16),
      timeDiffMs: readTimeDiff(),
      deviceIdPresent: readDeviceId() !== ''
    }, null, 2));
    return;
  }

  const session = decryptActiveSession();
  if (!session.success) {
    console.log(JSON.stringify(session));
    return;
  }
  const { credentials, rawJson } = session;

  if (argv.includes('--local-only')) {
    console.log(JSON.stringify({
      success: true,
      email: credentials.email,
      userId: credentials.user_id,
      rawJson,
      info: '本地会话校验（未请求额度 API）'
    }));
    return;
  }

  const result = await callUsageStats(credentials);
  const out = {
    success: true,
    email: credentials.email,
    userId: credentials.user_id,
    rawJson,
    profileSource: result.profile ? result.profile.source : undefined,
    profileAppVersion: result.profile ? result.profile.appVersion : undefined
  };
  if (result.error) {
    out.errorCode = result.error.code;
    out.error = result.error.error;
  } else {
    out.usedCharacters = result.usedCharacters;
    out.monthlyLimit = result.monthlyLimit;
    out.info = result.info;
  }
  console.log(JSON.stringify(out, null, 2));
}

module.exports = {
  decryptActiveSession,
  encryptSessionPayload,
  resolveClientProfile,
  buildSignedHeaders,
  callUsageStats,
  parseUsageBody,
  summarizeApiError,
  looksLikeDeviceUserLimit,
  looksLikeClientNotSupported,
  extractKeysFromAsar,
  readTypelessAppVersion,
  sessionDerivedPassword,
  aesEncryptOpenSSL,
  API_HOST,
  USAGE_PATH
};

if (require.main === module) {
  main().catch((err) => {
    console.log(JSON.stringify({ success: false, error: `提取过程异常: ${err.message}` }));
  });
}
