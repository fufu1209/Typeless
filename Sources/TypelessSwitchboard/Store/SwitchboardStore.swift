import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

@MainActor
final class SwitchboardStore: ObservableObject {
    @Published var state: PersistedState
    @Published var statusMessage = "本地数据已准备好"
    @Published var moeMailEmails: [MoeMailEmail] = []
    @Published var moeMailMessages: [MoeMailMessage] = []
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var isRunningAutomaticReplacement = false
    /// 智能换号 / 静默池内切换进行中（与全自动注册共用互斥，避免双开）。
    @Published var isRunningSmartSwitch = false
    @Published var isSyncingSession = false
    @Published var syncStatusMessage = ""
    @Published var lastAutoRotateCheckAt: Date?
    @Published var lastAutoRotateDecisionReason = ""
    @Published var autoRotateMonitorStatus = "守护未开启"
    /// 最近一次静默换号失败原因（含设备用户数超限等），供 UI / 降级决策使用。
    @Published var lastSilentSwitchFailureReason = ""
    /// 最近一次同步官方会话时是否命中「设备登录用户数超限」。
    @Published var lastSyncHitDeviceUserLimit = false
    /// P0-2：账号池文件解码失败时记录原因并保留损坏备份。UI 侧栏错误条要展示这个。
    @Published var accountLoadError: String?
    /// 最近一次「本周额度」官方 API 是否拿到新鲜数值（失败时不得当成额度充足）。
    @Published var lastQuotaSyncFresh = false
    /// 最近一次成功拉到本周额度的时间。
    @Published var lastQuotaSyncAt: Date?
    /// 最近一次官方本周已用 / 上限（与 remaining 同源：week_word_usage_*）。
    @Published var lastQuotaUsedCharacters: Int?
    @Published var lastQuotaMonthlyLimit: Int?
    /// 当前官方账号剩余字数（菜单栏展示用）。
    @Published var liveRemainingCharacters: Int?
    @Published var liveAccountEmail = ""
    /// 开机自启 LaunchAgent 状态摘要（侧栏展示）。
    @Published var launchAgentStatusMessage = ""

    // MARK: - v2.5.4 周额度周期看门狗
    //
    // 原先 `reviveExpiredAccountsIfNeeded` 只在 `syncActiveAppSessionAndQuota` 里被调用，
    // 而同步本身依赖 node 脚本 + Typeless 登录态。两个后果：
    //   1. 关掉「无感守护」时，周一 00:00 之后账号不会自动复活，额度被错杀；
    //   2. 整个周末没开 App，周一打开也不会复活，要等用户手动点「同步额度」。
    // 看门狗与守护开关解耦：不管 isAutoRotateEnabled 开不开都会跑，
    // 且只在本地纯计算，不请求网络、不依赖 node。
    var quotaCycleWatchdogTask: Task<Void, Never>?
    /// 引导巡检循环（v2.5.5）：5 分钟一轮，Typeless 未运行且引导标记被重置时静默补写。
    var onboardingGuardTask: Task<Void, Never>?
    /// 各账号最近一次观测到的「本周已用」数值（v2.5.6）。
    /// 官方 `/user/usage_stats` 不返回重置时间戳，只能靠数值下降沿来识别重置 ——
    /// 这是实测周期口径（自然周 vs 滚动 7 天）的唯一办法。仅内存态，不做持久化。
    var quotaUsageSamples: [UUID: Int] = [:]
    /// 观测到的额度重置时刻（v2.5.6）。攒够样本后自动给出口径结论，不再靠猜。
    /// **跨重启累积**：启动时从 `quota-cycle-observations.json` 读回，
    /// 否则用户每天开关机的话永远攒不够样本（判定口径至少要看两三次重置 = 两三周）。
    var quotaObservedResets: [QuotaCycleEngine.ObservedReset] = []
    /// 落盘版观测记录（含邮箱，便于事后人工核对）。
    var quotaObservationRecords: [QuotaCycleObservationStore.Record] = []
    /// 最近一次自动复活的时间点（UI 展示用）。
    @Published var lastWeeklyRevivalAt: Date?
    /// 最近一次自动复活了哪些账号（UI 展示用）。
    @Published var lastWeeklyRevivalEmails: [String] = []
    /// Typeless 桌面端引导状态是否未完成（v2.5.4：启动自检后提示用户一键跳过）。
    @Published var desktopOnboardingNeedsPatch = false

    let fileURL: URL
    let runMode: SwitchboardRunMode
    var rotateMonitorTask: Task<Void, Never>?
    var isAutoRotateCheckInFlight = false
    /// 上一轮巡检得到的剩余额度，用于自适应巡检间隔。
    var lastKnownRemainingForInterval: Int?

    var dataFileURL: URL {
        fileURL
    }

    /// 任一换号路径进行中时禁用主按钮。
    var isSwitchBusy: Bool {
        isRunningAutomaticReplacement || isRunningSmartSwitch || isSyncingSession
    }

    init(runMode: SwitchboardRunMode = .gui) {
        self.runMode = runMode
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        self.fileURL = folder.appendingPathComponent("store.json")

        // P0-2：解码失败不能静默吞错 + 落盘成空 state，否则 Keychain 里的密码永久找不到。
        // 先把损坏文件备份到 store.json.corrupted-<时间戳>，再置空，让用户从 UI 看到错误。
        switch StoreRecovery.load(from: fileURL, decode: { try JSONDecoder.appDecoder.decode(PersistedState.self, from: $0) }) {
        case .success(let loaded):
            state = loaded
        case .failure(let recovery):
            accountLoadError = recovery.message
            state = .empty
        }
        migrateDefaultsIfNeeded()
        // v2.5.5：周期时区必须在**所有运行模式**下生效，不能只挂在 GUI 的 AppDelegate 上。
        // LaunchAgent 守护（--daemon-check）是独立进程，它也要按同一个时区算周界，
        // 否则会出现「App 里显示该复活了，插件巡检却认为还没到点」。
        applyQuotaCycleTimeZone()
        // 必须在任何同步之前把历史观测读回来，否则恰好跨周重启会漏掉最关键的那条证据。
        loadQuotaCycleObservations()
        ensureExtractScript()
        refreshLaunchAgentStatus()

        // GUI 才常驻循环监控；daemon 单次巡检由 CLI 入口触发，避免无界面进程挂后台。
        if runMode == .gui, state.settings.isAutoRotateEnabled {
            startRotateMonitor()
            autoRotateMonitorStatus = "无感守护已开启，等待首次巡检（也可装开机轻量插件，不必开着本窗口）"
        } else if runMode == .gui {
            autoRotateMonitorStatus = "App 内循环守护已关闭（推荐用开机轻量插件）"
        } else {
            autoRotateMonitorStatus = "daemon 单次巡检模式"
        }
    }

    func migrateDefaultsIfNeeded() {
        if state.settings.typelessLoginURL == oldTypelessLoginURL ||
            state.settings.typelessLoginURL == typelessOfficialURL {
            state.settings.typelessLoginURL = typelessDefaultLoginURL
        }

        // 一次性迁移到「无感守护」默认：开启监测、池空自动注册、关窗后台、阈值 200、热备 1、常规 1 分钟巡检。
        let seamlessMigrationKey = "didApplySeamlessGuardianDefaults_v1"
        if !UserDefaults.standard.bool(forKey: seamlessMigrationKey) {
            state.settings.isAutoRotateEnabled = true
            state.settings.autoCreateWhenPoolEmpty = true
            state.settings.keepRunningInBackground = true
            state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.defaultRemainingThreshold
            state.settings.autoRotateCheckIntervalMinutes = SmartSwitchPolicy.defaultCheckIntervalMinutes
            state.settings.hotSpareTargetCount = max(
                state.settings.hotSpareTargetCount,
                SmartSwitchPolicy.defaultHotSpareTarget
            )
            UserDefaults.standard.set(true, forKey: seamlessMigrationKey)
        }

        // v2：默认不再要求 GUI 常驻；额度守护交给 LaunchAgent 轻量插件（定时 --daemon-check）。
        let noResidentGUIKey = "didApplyLaunchAgentPreferredDefaults_v2"
        if !UserDefaults.standard.bool(forKey: noResidentGUIKey) {
            state.settings.keepRunningInBackground = false
            state.settings.isAutoRotateEnabled = false
            UserDefaults.standard.set(true, forKey: noResidentGUIKey)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.appEncoder.encode(state) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }

        if state.settings.autoRotateCheckIntervalMinutes <= 0 {
            state.settings.autoRotateCheckIntervalMinutes = SmartSwitchPolicy.defaultCheckIntervalMinutes
        }
        if state.settings.autoRotateRemainingThreshold <= 0 {
            state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.defaultRemainingThreshold
        }
        state.settings.autoRotateCheckIntervalMinutes = SmartSwitchPolicy.normalizeCheckIntervalMinutes(
            state.settings.autoRotateCheckIntervalMinutes
        )
        state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.normalizeThreshold(
            state.settings.autoRotateRemainingThreshold
        )
        state.settings.hotSpareTargetCount = SmartSwitchPolicy.normalizeHotSpareTarget(
            state.settings.hotSpareTargetCount
        )
        for index in state.settings.checklist.indices {
            if state.settings.checklist[index].title == "打开对应邮箱，手动处理必要验证码" {
                state.settings.checklist[index].title = "自动轮询对应邮箱验证码，必要时手动兜底"
            }
        }
    }

    func ensureExtractScript() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        let scriptURL = folder.appendingPathComponent("extract-active-session.js")
        let writeURL = folder.appendingPathComponent("write-active-session.js")
        
        let scriptContent = #"""
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');

function getActiveSession() {
  return new Promise((resolve, reject) => {
    try {
      const platform = os.platform();
      const arch = os.arch();
      const appName = 'Typeless';
      
      const hashInput = platform + '-' + arch;
      const sha256Hex = crypto.createHash('sha256').update(hashInput).digest('hex');
      const pbkdf2Key = crypto.pbkdf2Sync(sha256Hex + appName, 'typeless-user-service', 10000, 32, 'sha256');

      const userdataPath = path.join(process.env.HOME, 'Library/Application Support/Typeless/user-data.json');
      if (!fs.existsSync(userdataPath)) {
        return resolve({ success: false, error: "未检测到 Typeless 客户端的登录缓存文件" });
      }

      const data = fs.readFileSync(userdataPath);
      if (data.length < 17 || data[16] !== 0x3a) {
        return resolve({ success: false, error: "登录缓存文件格式不正确或已损坏" });
      }

      const iv = data.slice(0, 16);
      const ciphertext = data.slice(17);
      const derivedPassword = crypto.pbkdf2Sync(pbkdf2Key, iv.toString(), 10000, 32, 'sha512');

      let credentials;
      let rawJsonString = "";
      try {
        const decipher = crypto.createDecipheriv('aes-256-cbc', derivedPassword, iv);
        let dec = decipher.update(ciphertext);
        dec = Buffer.concat([dec, decipher.final()]);
        rawJsonString = dec.toString('utf8');
        const parsed = JSON.parse(rawJsonString);
        credentials = JSON.parse(parsed.userData);
      } catch (e) {
        return resolve({ success: false, error: "本地缓存解密失败，可能是指纹不匹配或客户端已退出" });
      }

      const { access_token, user_id, email } = credentials;
      if (!access_token || !user_id) {
        return resolve({ success: false, error: "登录缓存中未包含有效的授权 Token" });
      }

      // 本地快速校验模式：只解密会话，不请求官方额度 API。
      // 用于静默换号验证等「只需要确认当前桌面账号」的场景，快且不受网络波动影响。
      if (process.argv.includes('--local-only')) {
        return resolve({
          success: true,
          email: email,
          userId: user_id,
          rawJson: rawJsonString,
          info: "本地会话校验（未请求额度 API）"
        });
      }

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
        return {
          code: statusCode === 200 ? 'API_PAYLOAD_MISMATCH' : 'API_HTTP_ERROR',
          error: statusCode === 200
            ? (combined ? `API 返回格式不匹配：${combined}` : 'API 返回格式不匹配')
            : `API 额度拉取失败 (HTTP ${statusCode})${combined ? ': ' + combined : ''}`
        };
      }

      // 获取额度使用状况
      const Qs = "7d4a8f2e6b9c3a1f5e8d2c7b4a9f6e3d1b5a2f9e6d3c0b7a4f1e8d5c2b9f6a3d";
      const yc = "9b1c67af3f7ecd1501d7da7196f281f5e0c7c292ebc2227d49ff9d20";
      
      const timestamp = Math.floor(Date.now() / 1000);
      const appVersion = "mac_2.0.0";
      const pathname = "/user/usage_stats";

      const signStr = `${timestamp}:${appVersion}:${pathname}:${user_id}`;
      const hmacKeyString = `${timestamp}:${yc}`;

      const hmac = crypto.createHmac('sha1', hmacKeyString).update(signStr).digest('hex');

      const aesKey = Buffer.from(Qs, 'hex');
      const ivAes = Buffer.alloc(16, 0);
      const cipher = crypto.createCipheriv('aes-256-cbc', aesKey, ivAes);
      let encrypted = cipher.update(hmac, 'utf8', 'base64');
      encrypted += cipher.final('base64');

      const options = {
        hostname: 'api.typeless.com',
        port: 443,
        path: pathname,
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${access_token}`,
          'X-Authorization': encrypted,
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Typeless/2.0.0 Chrome/120.0.6099.291 Electron/28.2.1 Safari/537.36',
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        timeout: 6000
      };

      const req = https.request(options, (res) => {
        let body = '';
        res.on('data', (chunk) => body += chunk);
        res.on('end', () => {
          if (res.statusCode !== 200) {
            const summarized = summarizeApiError(res.statusCode, body);
            return resolve({
              success: true,
              email: email,
              userId: user_id,
              rawJson: rawJsonString,
              errorCode: summarized.code,
              error: summarized.error
            });
          }
          try {
            const respObj = JSON.parse(body);
            if (respObj.status === 'OK' && respObj.data && respObj.data.voice_transcription) {
              const vt = respObj.data.voice_transcription;
              return resolve({
                success: true,
                email: email,
                userId: user_id,
                rawJson: rawJsonString,
                usedCharacters: vt.week_word_usage_value,
                monthlyLimit: vt.week_word_usage_limit,
                info: `总字数: ${vt.total_words}, 已用秒数: ${Math.round(vt.total_audio_seconds)}秒`
              });
            }
            const summarized = summarizeApiError(200, body);
            return resolve({
              success: true,
              email: email,
              userId: user_id,
              rawJson: rawJsonString,
              errorCode: summarized.code,
              error: summarized.error
            });
          } catch (e) {
            const summarized = summarizeApiError(200, body);
            return resolve({
              success: true,
              email: email,
              userId: user_id,
              rawJson: rawJsonString,
              errorCode: summarized.code,
              error: summarized.error || "解析 API 报文失败"
            });
          }
        });
      });

      req.on('error', (e) => {
        resolve({
          success: true,
          email: email,
          userId: user_id,
          rawJson: rawJsonString,
          error: `API 请求网络连接失败: ${e.message}`
        });
      });

      req.on('timeout', () => {
        req.destroy();
        resolve({
          success: true,
          email: email,
          userId: user_id,
          rawJson: rawJsonString,
          error: "API 请求连接超时"
        });
      });

      req.write(JSON.stringify({}));
      req.end();

    } catch (err) {
      resolve({ success: false, error: `提取过程异常: ${err.message}` });
    }
  });
}

getActiveSession().then(res => {
  console.log(JSON.stringify(res, null, 2));
});
"""#

        let writeScriptContent = #"""
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

function writeActiveSession(rawJsonString) {
  try {
    const platform = os.platform();
    const arch = os.arch();
    const appName = 'Typeless';
    
    const hashInput = platform + '-' + arch;
    const sha256Hex = crypto.createHash('sha256').update(hashInput).digest('hex');
    const pbkdf2Key = crypto.pbkdf2Sync(sha256Hex + appName, 'typeless-user-service', 10000, 32, 'sha256');

    const plaintext = Buffer.from(rawJsonString, 'utf8');
    const iv = crypto.randomBytes(16);
    const derivedPassword = crypto.pbkdf2Sync(pbkdf2Key, iv.toString(), 10000, 32, 'sha512');

    const cipher = crypto.createCipheriv('aes-256-cbc', derivedPassword, iv);
    let ciphertext = cipher.update(plaintext);
    ciphertext = Buffer.concat([ciphertext, cipher.final()]);

    const colon = Buffer.from(':');
    const totalLength = iv.length + colon.length + ciphertext.length;
    const finalBuffer = Buffer.concat([iv, colon, ciphertext], totalLength);

    const userdataPath = path.join(process.env.HOME, 'Library/Application Support/Typeless/user-data.json');
    const dir = path.dirname(userdataPath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(userdataPath, finalBuffer);
    console.log(JSON.stringify({ success: true }));
  } catch (err) {
    console.log(JSON.stringify({ success: false, error: err.message }));
  }
}

const inputJson = process.argv[2];
if (!inputJson) {
  console.log(JSON.stringify({ success: false, error: "未提供 session payload 参数" }));
  process.exit(1);
}
writeActiveSession(inputJson);
"""#

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? writeScriptContent.write(to: writeURL, atomically: true, encoding: .utf8)
    }


    /// 最近一次成功写盘的内容快照：UI 逐字符输入也会触发 save，内容未变时跳过编码与写盘。
    var lastSavedStateData: Data?

    /// 权限探测结果缓存，避免后台热备/巡检反复触发系统弹窗。
    var cachedAccessibilityTrusted: Bool?
    var cachedAutomationOK: Bool?
    var cachedAutomationDetail = ""
    var lastPermissionProbeAt: Date?
    var didAutoOpenPermissionSettingsThisSession = false
    let permissionProbeCacheTTL: TimeInterval = 30 * 60

    /// - Parameter localOnly: 只做本地解密 + 账号匹配 + 会话缓存更新，不请求官方额度 API。
    ///   静默换号验证等「只需确认当前桌面账号」的场景使用，快且不受网络波动影响。
}
