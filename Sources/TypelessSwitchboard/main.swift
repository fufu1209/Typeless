import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

private let defaultDomains = [
    "8888891.xyz",
    "xiefucai1209.com",
    "fucai.edu.kg",
    "fucaixie.xyz",
    "cnmlgb.de",
    "zhooo.amyjaneofficial.ccwu.ccorg",
    "coolkid.icu",
    "zhooo.ggff.net",
    "coolkidsa.ggff.net",
    "20030416.xyz",
    "amyjaneofficial.ccwu.cc"
]

private let typelessOfficialURL = "https://www.typeless.com/"
private let typelessDefaultLoginURL = "https://www.typeless.com/login"
private let oldTypelessLoginURL = "https://app.typeless.com"
private let typelessCredentialTarget = "now.typeless.desktop.deviceIdentifier"
private let typelessCredentialAccount = "now.typeless.desktop.security.auth_key"
private let typelessLegacyCredentialTarget = "Typeless.deviceIdentifier"
private let typelessAutomationPasswordEnvironmentKey = "TYPELESS_AUTOMATION_PASSWORD"
private let typelessAppQuitGraceSeconds: TimeInterval = 2.5
private let chromeSessionJavaScriptDelaySeconds = 1

enum AccountStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case available
    case nearlySpent
    case exhausted
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .available: "可用"
        case .nearlySpent: "快用完"
        case .exhausted: "本月已用完"
        case .paused: "暂停"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .nearlySpent: .orange
        case .exhausted: .red
        case .paused: .secondary
        }
    }
}

enum ReviewState: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case approved
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "待兜底确认"
        case .approved: "已确认"
        case .rejected: "已退回"
        }
    }

    var color: Color {
        switch self {
        case .pending: .orange
        case .approved: .green
        case .rejected: .red
        }
    }
}

enum AccountListFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case pending
    case exhausted
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .available: "可用"
        case .pending: "待确认"
        case .exhausted: "用完"
        case .paused: "暂停"
        }
    }
}

struct Account: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var moeMailEmailID: String?
    var typelessUsername: String?
    var passwordHint: String?
    var reviewState: ReviewState?
    var reviewedAt: Date?
    var name: String
    var email: String
    var domain: String
    var role: String
    var monthlyLimit: Int
    var usedCharacters: Int
    var status: AccountStatus
    var typelessURL: String
    var inboxURL: String
    var notes: String
    var createdAt: Date
    var lastResetAt: Date
    var rawUserDataPayload: String?

    var remainingCharacters: Int {
        max(monthlyLimit - usedCharacters, 0)
    }

    var usageRatio: Double {
        guard monthlyLimit > 0 else { return 0 }
        return min(Double(usedCharacters) / Double(monthlyLimit), 1)
    }

    var isUsable: Bool {
        (status == .available || status == .nearlySpent) && (reviewState ?? .approved) == .approved
    }

    var effectiveReviewState: ReviewState {
        reviewState ?? .approved
    }

    static func blank(settings: AppSettings) -> Account {
        Account(
            id: UUID(),
            moeMailEmailID: nil,
            typelessUsername: nil,
            passwordHint: nil,
            reviewState: .approved,
            reviewedAt: Date(),
            name: "新账号",
            email: "",
            domain: settings.domains.first ?? "",
            role: "平民",
            monthlyLimit: 8000,
            usedCharacters: 0,
            status: .available,
            typelessURL: settings.typelessLoginURL,
            inboxURL: settings.moeMailBaseURL,
            notes: "",
            createdAt: Date(),
            lastResetAt: Date(),
            rawUserDataPayload: nil
        )
    }
}

struct MoeMailEmail: Identifiable, Equatable {
    var id: String
    var address: String
    var name: String
    var domain: String
    var expiresAt: Date?
    var rawSummary: String

    var displayName: String {
        if !name.isEmpty { return name }
        return address.isEmpty ? id : address
    }
}

struct MoeMailMessage: Identifiable, Equatable {
    var id: String
    var subject: String
    var sender: String
    var receivedAt: String
    var preview: String
}

enum DiagnosticLevel: String {
    case ok
    case warning
    case error

    var title: String {
        switch self {
        case .ok: "正常"
        case .warning: "注意"
        case .error: "需要处理"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct DiagnosticItem: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    var level: DiagnosticLevel
}

struct AppSettings: Codable, Equatable, Sendable {
    var typelessLoginURL: String
    var moeMailBaseURL: String
    var domains: [String]
    var checklist: [SwitchTask]
    /// 后台无感额度守护：打开后定时同步官方额度，低额度时自动静默换号。
    var isAutoRotateEnabled: Bool
    /// 常规巡检间隔（分钟），1–120；额度接近阈值时会自动加速到约 20 秒。
    var autoRotateCheckIntervalMinutes: Int
    /// 剩余字数低于该阈值时触发自动换号（默认 200）。
    var autoRotateRemainingThreshold: Int
    /// 监测到低额度且池内没有可静默切换账号时，是否自动走全自动注册换号。
    var autoCreateWhenPoolEmpty: Bool
    /// 热备池目标数量：始终尽量保有这么多可静默注入的备用号。
    var hotSpareTargetCount: Int
    /// 关主窗口时是否继续后台守护（菜单栏常驻）。
    var keepRunningInBackground: Bool

    static let defaults = AppSettings(
        typelessLoginURL: typelessDefaultLoginURL,
        moeMailBaseURL: "https://mail.8888891.xyz",
        domains: defaultDomains,
        checklist: [
            SwitchTask(title: "确认当前账号本月额度已经用完", isRequired: true),
            SwitchTask(title: "在 Typeless 内正常退出当前账号", isRequired: true),
            SwitchTask(title: "选择下一个仍有额度的账号", isRequired: true),
            SwitchTask(title: "自动轮询对应邮箱验证码，必要时手动兜底", isRequired: true),
            SwitchTask(title: "登录完成后更新本工具里的已用字数", isRequired: false)
        ],
        isAutoRotateEnabled: true,
        autoRotateCheckIntervalMinutes: SmartSwitchPolicy.defaultCheckIntervalMinutes,
        autoRotateRemainingThreshold: SmartSwitchPolicy.defaultRemainingThreshold,
        autoCreateWhenPoolEmpty: true,
        hotSpareTargetCount: SmartSwitchPolicy.defaultHotSpareTarget,
        keepRunningInBackground: true
    )

    enum CodingKeys: String, CodingKey {
        case typelessLoginURL
        case moeMailBaseURL
        case domains
        case checklist
        case isAutoRotateEnabled
        case autoRotateCheckIntervalMinutes
        case autoRotateRemainingThreshold
        case autoCreateWhenPoolEmpty
        case hotSpareTargetCount
        case keepRunningInBackground
    }

    init(
        typelessLoginURL: String,
        moeMailBaseURL: String,
        domains: [String],
        checklist: [SwitchTask],
        isAutoRotateEnabled: Bool,
        autoRotateCheckIntervalMinutes: Int,
        autoRotateRemainingThreshold: Int,
        autoCreateWhenPoolEmpty: Bool,
        hotSpareTargetCount: Int,
        keepRunningInBackground: Bool
    ) {
        self.typelessLoginURL = typelessLoginURL
        self.moeMailBaseURL = moeMailBaseURL
        self.domains = domains
        self.checklist = checklist
        self.isAutoRotateEnabled = isAutoRotateEnabled
        self.autoRotateCheckIntervalMinutes = autoRotateCheckIntervalMinutes
        self.autoRotateRemainingThreshold = autoRotateRemainingThreshold
        self.autoCreateWhenPoolEmpty = autoCreateWhenPoolEmpty
        self.hotSpareTargetCount = hotSpareTargetCount
        self.keepRunningInBackground = keepRunningInBackground
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.defaults
        typelessLoginURL = try container.decodeIfPresent(String.self, forKey: .typelessLoginURL) ?? fallback.typelessLoginURL
        moeMailBaseURL = try container.decodeIfPresent(String.self, forKey: .moeMailBaseURL) ?? fallback.moeMailBaseURL
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? fallback.domains
        checklist = try container.decodeIfPresent([SwitchTask].self, forKey: .checklist) ?? fallback.checklist
        // 旧版默认是关；新版无感守护默认开。若 JSON 里明确写了 false 仍尊重用户选择。
        isAutoRotateEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoRotateEnabled) ?? true
        autoRotateCheckIntervalMinutes = SmartSwitchPolicy.normalizeCheckIntervalMinutes(
            try container.decodeIfPresent(Int.self, forKey: .autoRotateCheckIntervalMinutes)
                ?? fallback.autoRotateCheckIntervalMinutes
        )
        autoRotateRemainingThreshold = SmartSwitchPolicy.normalizeThreshold(
            try container.decodeIfPresent(Int.self, forKey: .autoRotateRemainingThreshold)
                ?? fallback.autoRotateRemainingThreshold
        )
        autoCreateWhenPoolEmpty = try container.decodeIfPresent(Bool.self, forKey: .autoCreateWhenPoolEmpty)
            ?? fallback.autoCreateWhenPoolEmpty
        hotSpareTargetCount = SmartSwitchPolicy.normalizeHotSpareTarget(
            try container.decodeIfPresent(Int.self, forKey: .hotSpareTargetCount)
                ?? fallback.hotSpareTargetCount
        )
        keepRunningInBackground = try container.decodeIfPresent(Bool.self, forKey: .keepRunningInBackground)
            ?? fallback.keepRunningInBackground
    }
}

struct SwitchTask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isRequired: Bool
    var isDone: Bool

    init(id: UUID = UUID(), title: String, isRequired: Bool, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isRequired = isRequired
        self.isDone = isDone
    }
}

struct PersistedState: Codable, Equatable, Sendable {
    var accounts: [Account]
    var settings: AppSettings
    var tokenSummaries: [TokenSummary]?
    var loginSnapshots: [LoginSnapshotManifest]?
    var registrationPlans: [RegistrationPreparationPlan]?
    var deviceReport: DeviceInfoReport?
    var lastAutomationResult: RegistrationAutomationResult?

    static let empty = PersistedState(
        accounts: [],
        settings: .defaults,
        tokenSummaries: [],
        loginSnapshots: [],
        registrationPlans: [],
        deviceReport: nil,
        lastAutomationResult: nil
    )
}

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
    /// 当前官方账号剩余字数（菜单栏展示用）。
    @Published var liveRemainingCharacters: Int?
    @Published var liveAccountEmail = ""

    private let fileURL: URL
    private var rotateMonitorTask: Task<Void, Never>?
    private var isAutoRotateCheckInFlight = false
    /// 上一轮巡检得到的剩余额度，用于自适应巡检间隔。
    private var lastKnownRemainingForInterval: Int?

    var dataFileURL: URL {
        fileURL
    }

    /// 任一换号路径进行中时禁用主按钮。
    var isSwitchBusy: Bool {
        isRunningAutomaticReplacement || isRunningSmartSwitch || isSyncingSession
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        self.fileURL = folder.appendingPathComponent("store.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.appDecoder.decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = .empty
        }
        migrateDefaultsIfNeeded()
        ensureExtractScript()
        
        // 无感守护：默认开启；旧用户若未写字段也默认开。
        if state.settings.isAutoRotateEnabled {
            startRotateMonitor()
            autoRotateMonitorStatus = "无感守护已开启，等待首次巡检"
        } else {
            autoRotateMonitorStatus = "无感守护已关闭"
        }
    }

    private func migrateDefaultsIfNeeded() {
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

    private func ensureExtractScript() {
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


    func syncActiveAppSessionAndQuota() async -> UUID? {
        isSyncingSession = true
        lastSyncHitDeviceUserLimit = false
        syncStatusMessage = "正在读取本地 Typeless 登录状态并向云端同步额度..."
        statusMessage = syncStatusMessage
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        let scriptURL = folder.appendingPathComponent("extract-active-session.js")
        
        let result = await Task.detached(priority: .userInitiated) {
            return SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
        }.value
        
        isSyncingSession = false
        
        guard result.status == 0 else {
            syncStatusMessage = "同步进程失败：\(result.output)"
            statusMessage = syncStatusMessage
            noteDeviceUserLimitIfPresent(in: result.output)
            return nil
        }
        
        guard let data = result.output.data(using: .utf8) else {
            syncStatusMessage = "读取进程输出失败"
            statusMessage = syncStatusMessage
            return nil
        }
        
        struct ActiveSessionResult: Codable {
            let success: Bool
            let email: String?
            let userId: String?
            let usedCharacters: Int?
            let monthlyLimit: Int?
            let info: String?
            let error: String?
            let errorCode: String?
            let rawJson: String?
        }
        
        do {
            let res = try JSONDecoder().decode(ActiveSessionResult.self, from: data)
            if !res.success {
                syncStatusMessage = "同步失败：\(res.error ?? "未知错误")"
                statusMessage = syncStatusMessage
                noteDeviceUserLimitIfPresent(in: res.error)
                noteDeviceUserLimitIfPresent(in: res.errorCode)
                return nil
            }
            
            guard let email = res.email else {
                syncStatusMessage = "解密成功但未找到邮箱"
                statusMessage = syncStatusMessage
                return nil
            }

            if res.errorCode == "DEVICE_USER_LIMIT" || SmartSwitchPolicy.isDeviceUserLimitError(res.error) {
                lastSyncHitDeviceUserLimit = true
            }
            
            var matchedID: UUID? = nil
            for i in 0..<state.accounts.count {
                if state.accounts[i].email.lowercased() == email.lowercased() {
                    matchedID = state.accounts[i].id
                    if let used = res.usedCharacters {
                        state.accounts[i].usedCharacters = used
                    }
                    if let limit = res.monthlyLimit {
                        state.accounts[i].monthlyLimit = limit
                    }
                    if let info = res.info {
                        state.accounts[i].notes = "已同步：\(info)"
                    }
                    // 额度 API 正常时才刷新静默会话缓存；设备超限/API 错误时保留旧 payload，避免把半残会话写回账号池。
                    if res.error == nil, let rawJson = res.rawJson, !rawJson.isEmpty {
                        state.accounts[i].rawUserDataPayload = rawJson
                    }
                    break
                }
            }
            
            if let matchedID = matchedID {
                if let errorMsg = res.error {
                    if lastSyncHitDeviceUserLimit {
                        syncStatusMessage = "已读到账号「\(email)」，但设备登录用户数已超限：\(errorMsg)"
                    } else {
                        syncStatusMessage = "已同步账号「\(email)」，但 API 拉取有错：\(errorMsg)"
                    }
                } else {
                    syncStatusMessage = "已成功更新当前官方账号「\(email)」的字数额度！"
                }
                save()
                statusMessage = syncStatusMessage
                // 设备超限时桌面会话不可信：返回 nil，让上层优先走 resetDevice + 全自动换号。
                if lastSyncHitDeviceUserLimit {
                    return nil
                }
                return matchedID
            } else {
                // 新建账号
                var newAcc = Account.blank(settings: state.settings)
                newAcc.email = email
                newAcc.usedCharacters = res.usedCharacters ?? 0
                newAcc.monthlyLimit = res.monthlyLimit ?? 8000
                newAcc.notes = "从官方 App 自动导入（\(res.info ?? "")）"
                if res.error == nil {
                    newAcc.rawUserDataPayload = res.rawJson
                }
                state.accounts.append(newAcc)
                save()
                if lastSyncHitDeviceUserLimit {
                    syncStatusMessage = "发现账号「\(email)」，但设备登录用户数已超限，未采用当前桌面会话"
                    statusMessage = syncStatusMessage
                    return nil
                }
                syncStatusMessage = "发现新账号「\(email)」，已自动导入并切换！"
                statusMessage = syncStatusMessage
                return newAcc.id
            }
            
        } catch {
            syncStatusMessage = "解析同步结果失败：\(error.localizedDescription)"
            statusMessage = syncStatusMessage
            noteDeviceUserLimitIfPresent(in: result.output)
            return nil
        }
    }

    private func noteDeviceUserLimitIfPresent(in message: String?) {
        if SmartSwitchPolicy.isDeviceUserLimitError(message) {
            lastSyncHitDeviceUserLimit = true
        }
    }


    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.appEncoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
            
            if state.settings.isAutoRotateEnabled {
                startRotateMonitor()
            } else {
                stopRotateMonitor()
            }
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 智能换号 / 账号池自动轮切与额度监控

    /// 启动或重启无感守护循环。`kickImmediately` 用于休眠唤醒 / 菜单「立即巡检」后的续跑。
    func startRotateMonitor(kickImmediately: Bool = false) {
        if rotateMonitorTask != nil {
            if kickImmediately {
                // 已在跑：额外触发一轮，不拆掉现有循环。
                Task { [weak self] in
                    _ = await self?.performAutoRotateCheck()
                }
            }
            return
        }
        let threshold = SmartSwitchPolicy.normalizeThreshold(state.settings.autoRotateRemainingThreshold)
        autoRotateMonitorStatus = kickImmediately
            ? "无感守护运行中：立即巡检…"
            : "无感守护运行中：约 \(SmartSwitchPolicy.defaultStartupDelaySeconds) 秒后首次读额度（阈值 \(threshold)）"
        rotateMonitorTask = Task { [weak self] in
            if !kickImmediately {
                do {
                    try await Task.sleep(nanoseconds: SmartSwitchPolicy.defaultStartupDelaySeconds * 1_000_000_000)
                } catch {
                    return
                }
            }

            while !Task.isCancelled {
                guard let self = self else { break }
                if self.state.settings.isAutoRotateEnabled {
                    _ = await self.performAutoRotateCheck()
                } else {
                    break
                }

                let delay = SmartSwitchPolicy.nextCheckDelaySeconds(
                    remaining: self.lastKnownRemainingForInterval,
                    threshold: self.state.settings.autoRotateRemainingThreshold,
                    intervalMinutes: self.state.settings.autoRotateCheckIntervalMinutes
                )
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } catch {
                    break
                }
            }
            await MainActor.run {
                self?.autoRotateMonitorStatus = self?.state.settings.isAutoRotateEnabled == true
                    ? "无感守护已暂停（可点菜单「立即巡检额度」恢复）"
                    : "无感守护已关闭"
            }
        }
    }

    func stopRotateMonitor() {
        rotateMonitorTask?.cancel()
        rotateMonitorTask = nil
        if !state.settings.isAutoRotateEnabled {
            autoRotateMonitorStatus = "无感守护已关闭"
        }
    }

    /// 休眠唤醒 / 用户点菜单时调用：确保守护循环在跑，并立刻同步一轮额度。
    func resumeRotateMonitorAfterWakeOrManualKick() {
        guard state.settings.isAutoRotateEnabled else {
            autoRotateMonitorStatus = "无感守护已关闭"
            return
        }
        if rotateMonitorTask == nil {
            startRotateMonitor(kickImmediately: true)
        } else {
            Task { [weak self] in
                _ = await self?.performAutoRotateCheck()
            }
        }
    }

    /// 用户主入口：点一下即可。优先池内静默切换，没有可注入会话时再全自动注册。
    func runSmartSwitch(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        from currentID: UUID?,
        forceSwitch: Bool = true
    ) async -> UUID? {
        guard !isRunningSmartSwitch, !isRunningAutomaticReplacement else {
            statusMessage = "换号正在进行中，请稍候"
            return currentID
        }

        isRunningSmartSwitch = true
        defer { isRunningSmartSwitch = false }

        statusMessage = forceSwitch ? "正在智能换号…" : "正在根据额度自动换号…"
        let syncedID = await syncActiveAppSessionAndQuota()
        // 设备用户数超限：静默池切换只会复用旧 deviceId，直接走全自动 resetDevice。
        if lastSyncHitDeviceUserLimit {
            lastAutoRotateDecisionReason = "检测到设备登录用户数超限，跳过静默切换并全自动重置设备身份"
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "设备登录用户数已超限，且未配置 MoeMail API Key，无法自动注册新号。请配置后重试，或手动全自动换号。"
                return currentID
            }
            statusMessage = "设备登录用户数已超限，正在重置设备身份并全自动注册换号…"
            return await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: expiryTime,
                from: syncedID ?? currentID,
                interactive: forceSwitch
            )
        }

        let resolvedCurrentID = syncedID ?? currentID
        let currentRemaining: Int? = {
            guard let id = resolvedCurrentID, let index = accountIndex(id: id) else { return nil }
            return state.accounts[index].remainingCharacters
        }()
        if let currentRemaining {
            lastKnownRemainingForInterval = currentRemaining
            liveRemainingCharacters = currentRemaining
        }

        let candidates = smartSwitchCandidates(excluding: resolvedCurrentID)
        let decision = SmartSwitchPolicy.decide(
            currentRemaining: currentRemaining,
            threshold: state.settings.autoRotateRemainingThreshold,
            forceSwitch: forceSwitch,
            candidates: candidates,
            allowFullAutomaticReplacement: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        lastAutoRotateDecisionReason = decision.reason

        switch decision.path {
        case .none:
            statusMessage = decision.reason
            return resolvedCurrentID

        case .silentPoolSwitch:
            guard let targetID = decision.targetAccountID else {
                statusMessage = "智能换号决策异常：缺少目标账号"
                return resolvedCurrentID
            }
            if isRunningAutomaticReplacement {
                statusMessage = "全自动换号进行中，智能换号已跳过"
                return resolvedCurrentID
            }
            statusMessage = decision.reason
            let success = await switchActiveAccountSilently(
                to: targetID,
                markPreviousExhausted: resolvedCurrentID,
                activateTypeless: forceSwitch
            )
            if success {
                statusMessage = "已静默切换到「\(decision.targetEmail ?? "")」（已轮换设备身份）"
                // 换走当前号后补热备，用户无感。
                Task { await self.ensureHotSpareIfNeeded(apiKey: apiKey, domain: domain) }
                return targetID
            }
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "静默切换失败：\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))；且未配置 MoeMail API Key，无法自动注册新号"
                return resolvedCurrentID
            }
            let limitHint = SmartSwitchPolicy.isDeviceUserLimitError(lastSilentSwitchFailureReason)
                || lastSyncHitDeviceUserLimit
            statusMessage = limitHint
                ? "静默切换命中设备用户数限制，正在降级为全自动重置设备并注册换号…"
                : "静默切换失败，正在降级为全自动注册换号…"
            return await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: expiryTime,
                from: resolvedCurrentID,
                interactive: forceSwitch
            )

        case .fullAutomaticReplacement:
            statusMessage = decision.reason
            return await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: expiryTime,
                from: resolvedCurrentID,
                interactive: forceSwitch
            )
        }
    }

    @discardableResult
    func performAutoRotateCheck(apiKey: String? = nil) async -> UUID? {
        guard !isAutoRotateCheckInFlight else {
            autoRotateMonitorStatus = "巡检进行中（跳过重叠触发）"
            return nil
        }
        guard !isRunningAutomaticReplacement, !isRunningSmartSwitch else {
            autoRotateMonitorStatus = "换号进行中，本轮巡检跳过"
            return nil
        }

        isAutoRotateCheckInFlight = true
        defer { isAutoRotateCheckInFlight = false }

        lastAutoRotateCheckAt = Date()
        autoRotateMonitorStatus = "正在同步额度…"

        let key = (apiKey ?? KeychainStore.readAPIKey()).trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = state.settings.domains.first ?? ""
        let allowCreate = state.settings.autoCreateWhenPoolEmpty && !key.isEmpty

        let syncedID = await syncActiveAppSessionAndQuota()
        if lastSyncHitDeviceUserLimit {
            lastAutoRotateDecisionReason = "检测到设备登录用户数超限，跳过静默切换并全自动重置设备身份"
            guard allowCreate else {
                autoRotateMonitorStatus = "巡检完成：设备用户数超限，但未允许自动创建新号"
                statusMessage = "设备登录用户数已超限；请配置 MoeMail API Key 并开启「池空时自动注册新号」"
                return nil
            }
            if isRunningAutomaticReplacement || isRunningSmartSwitch {
                autoRotateMonitorStatus = "巡检完成：设备超限但其它换号进行中"
                return nil
            }
            autoRotateMonitorStatus = "设备用户数超限，自动重置设备并注册中…"
            isRunningSmartSwitch = true
            defer { isRunningSmartSwitch = false }
            let newID = await runOneClickAutomaticReplacement(
                apiKey: key,
                domain: domain,
                expiryTime: 0,
                from: syncedID
            )
            autoRotateMonitorStatus = newID != nil ? "守护中：已因设备超限完成重置换号" : "巡检完成：设备超限后的自动注册失败"
            return newID
        }

        guard let currentID = syncedID else {
            lastAutoRotateDecisionReason = "无法读取官方 App 登录态，本轮巡检跳过"
            autoRotateMonitorStatus = "巡检完成：未读到登录态（请保持 Typeless 已登录）"
            return nil
        }
        guard let currentIndex = accountIndex(id: currentID) else {
            autoRotateMonitorStatus = "巡检完成：账号未入库"
            return nil
        }

        let remaining = state.accounts[currentIndex].remainingCharacters
        lastKnownRemainingForInterval = remaining
        liveRemainingCharacters = remaining
        liveAccountEmail = state.accounts[currentIndex].email

        let threshold = SmartSwitchPolicy.normalizeThreshold(state.settings.autoRotateRemainingThreshold)
        let candidates = smartSwitchCandidates(excluding: currentID)
        let decision = SmartSwitchPolicy.decide(
            currentRemaining: remaining,
            threshold: threshold,
            forceSwitch: false,
            candidates: candidates,
            allowFullAutomaticReplacement: allowCreate
        )
        lastAutoRotateDecisionReason = decision.reason

        var resultID: UUID? = currentID

        switch decision.path {
        case .none:
            // 额度 ≥ 阈值：只监控、不换号；同时后台补热备，保证真到阈值时能秒切。
            autoRotateMonitorStatus = SmartSwitchPolicy.monitorIdleStatus(remaining: remaining, threshold: threshold)
            if allowCreate {
                await ensureHotSpareIfNeeded(apiKey: key, domain: domain)
            }

        case .silentPoolSwitch:
            guard let targetID = decision.targetAccountID else {
                autoRotateMonitorStatus = "巡检完成：决策缺少目标账号"
                break
            }
            if isRunningAutomaticReplacement || isRunningSmartSwitch {
                autoRotateMonitorStatus = "巡检完成：其它换号进行中，跳过静默切换"
                break
            }
            autoRotateMonitorStatus = "剩余 \(remaining) < \(threshold)，正在静默换号（含设备身份轮换）…"
            let success = await switchActiveAccountSilently(
                to: targetID,
                markPreviousExhausted: currentID,
                activateTypeless: false
            )
            if success {
                statusMessage = "无感换号完成 → \(decision.targetEmail ?? "")"
                autoRotateMonitorStatus = "守护中：已静默切换并轮换设备身份，继续监测"
                resultID = targetID
                if allowCreate {
                    await ensureHotSpareIfNeeded(apiKey: key, domain: domain)
                }
            } else if allowCreate {
                autoRotateMonitorStatus = SmartSwitchPolicy.isDeviceUserLimitError(lastSilentSwitchFailureReason)
                    ? "静默命中设备限制，自动注册中…"
                    : "静默失败，自动注册中…"
                isRunningSmartSwitch = true
                defer { isRunningSmartSwitch = false }
                let newID = await runOneClickAutomaticReplacement(
                    apiKey: key,
                    domain: domain,
                    expiryTime: 0,
                    from: currentID
                )
                autoRotateMonitorStatus = newID != nil ? "守护中：已注册并切换" : "巡检完成：自动注册失败"
                resultID = newID ?? currentID
            } else {
                statusMessage = "自动静默换号失败：\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))；请配置 MoeMail API Key 或手动补号"
                autoRotateMonitorStatus = "巡检完成：静默切换失败"
            }

        case .fullAutomaticReplacement:
            autoRotateMonitorStatus = "剩余 \(remaining) < \(threshold) 且无备用会话，自动注册中…"
            isRunningSmartSwitch = true
            defer { isRunningSmartSwitch = false }
            let newID = await runOneClickAutomaticReplacement(
                apiKey: key,
                domain: domain,
                expiryTime: 0,
                from: currentID
            )
            autoRotateMonitorStatus = (newID != nil && newID != currentID)
                ? "守护中：已注册并切换"
                : "巡检完成：自动注册未完成"
            resultID = newID ?? currentID
            if allowCreate, newID != nil {
                await ensureHotSpareIfNeeded(apiKey: key, domain: domain)
            }
        }

        return resultID
    }

    /// 后台补齐热备：额度充足时静默注册 1 个可注入会话的备用号，不切换当前使用号。
    private func ensureHotSpareIfNeeded(apiKey: String, domain: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isRunningAutomaticReplacement else { return }

        let target = SmartSwitchPolicy.normalizeHotSpareTarget(state.settings.hotSpareTargetCount)
        guard target > 0 else { return }

        let activeID = liveAccountEmail.isEmpty
            ? nil
            : state.accounts.first { $0.email.lowercased() == liveAccountEmail.lowercased() }?.id
        let candidates = smartSwitchCandidates(excluding: activeID)
        guard SmartSwitchPolicy.needsHotSpare(candidates: candidates, target: target) else { return }

        autoRotateMonitorStatus = "守护中：补齐热备账号…"
        // 热备只走 Playwright 独立 profile，不碰桌面登录态。
        let spareID = await runOneClickAutomaticReplacement(
            apiKey: apiKey,
            domain: domain,
            expiryTime: 0,
            from: nil,
            preserveCurrentAccount: true
        )
        if let spareID, let index = accountIndex(id: spareID) {
            let hasPayload = !(state.accounts[index].rawUserDataPayload?.isEmpty ?? true)
            autoRotateMonitorStatus = hasPayload
                ? "守护中：热备已就绪（\(state.accounts[index].email)）"
                : "守护中：热备已注册但会话缓存未固化（下次可再同步）"
        } else {
            autoRotateMonitorStatus = "守护中：热备补齐未完成（下次巡检再试）"
        }
    }

    private func smartSwitchCandidates(excluding currentID: UUID?) -> [SmartSwitchCandidate] {
        state.accounts.compactMap { account in
            guard account.id != currentID else { return nil }
            guard account.isUsable, account.remainingCharacters > 0 else { return nil }
            let payload = account.rawUserDataPayload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SmartSwitchCandidate(
                id: account.id,
                email: account.email.ifEmpty(account.name),
                remainingCharacters: account.remainingCharacters,
                hasSilentSessionPayload: !payload.isEmpty
            )
        }
    }

    func switchActiveAccountSilently(
        to accountID: UUID,
        markPreviousExhausted previousID: UUID? = nil,
        activateTypeless: Bool = false
    ) async -> Bool {
        lastSilentSwitchFailureReason = ""
        lastSyncHitDeviceUserLimit = false

        guard let index = accountIndex(id: accountID) else {
            lastSilentSwitchFailureReason = "目标账号不存在"
            return false
        }
        let targetAccount = state.accounts[index]
        guard let payload = targetAccount.rawUserDataPayload, !payload.isEmpty else {
            lastSilentSwitchFailureReason = "目标账号缺少可注入的桌面会话缓存"
            return false
        }

        // 静默换号也必须轮换设备身份，否则同一 deviceId 会不断挂新 user，最终触发服务端设备用户数上限。
        let injectOK = await reinjectSessionPayload(
            payload,
            activateTypeless: activateTypeless,
            resetDeviceIdentity: true
        )
        guard injectOK else {
            if lastSilentSwitchFailureReason.isEmpty {
                lastSilentSwitchFailureReason = "写入桌面会话或重置设备身份失败"
            }
            return false
        }

        var verified = false
        for attempt in 0..<SmartSwitchPolicy.silentSwitchVerifyAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: SmartSwitchPolicy.silentSwitchVerifyDelaySeconds * 1_000_000_000)
            }
            if lastSyncHitDeviceUserLimit {
                lastSilentSwitchFailureReason = "设备登录用户数已超限，静默会话不可用"
                return false
            }
            if let synced = await syncActiveAppSessionAndQuota(),
               let syncedIndex = accountIndex(id: synced),
               state.accounts[syncedIndex].email.lowercased() == targetAccount.email.lowercased() {
                liveAccountEmail = state.accounts[syncedIndex].email
                liveRemainingCharacters = state.accounts[syncedIndex].remainingCharacters
                lastKnownRemainingForInterval = liveRemainingCharacters
                verified = true
                break
            }
            if lastSyncHitDeviceUserLimit {
                lastSilentSwitchFailureReason = syncStatusMessage.ifEmpty("设备登录用户数已超限，静默会话不可用")
                return false
            }
        }

        guard verified else {
            if lastSilentSwitchFailureReason.isEmpty {
                lastSilentSwitchFailureReason = lastSyncHitDeviceUserLimit
                    ? "设备登录用户数已超限，静默会话不可用"
                    : "静默注入后未能确认目标账号「\(targetAccount.email)」已生效"
            }
            return false
        }

        if let previousID,
           let previousIndex = accountIndex(id: previousID),
           previousID != accountID {
            state.accounts[previousIndex].status = .exhausted
            state.accounts[previousIndex].usedCharacters = state.accounts[previousIndex].monthlyLimit
            state.accounts[previousIndex].notes = "已由无感换号切换到：\(targetAccount.email.ifEmpty(targetAccount.name))"
        }

        for idx in state.settings.checklist.indices {
            state.settings.checklist[idx].isDone = false
        }

        liveAccountEmail = targetAccount.email
        if liveRemainingCharacters == nil {
            liveRemainingCharacters = targetAccount.remainingCharacters
        }
        save()
        return true
    }

    /// 退出 Typeless →（可选）重置设备身份 → 写入加密会话 → 后台重开（默认不抢前台）。
    /// - Parameter resetDeviceIdentity: 静默换号应传 true，避免同一 deviceId 挂过多账号触发服务端限制。
    private func reinjectSessionPayload(
        _ payload: String,
        activateTypeless: Bool,
        resetDeviceIdentity: Bool = true
    ) async -> Bool {
        _ = terminateInstalledTypelessApp()

        if resetDeviceIdentity {
            let backupRoot = automationDirectoryURL()
                .appendingPathComponent("DesktopSessionBackups", isDirectory: true)
                .appendingPathComponent("silent-\(Self.safeTimestamp())", isDirectory: true)
            let resetLog = resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: backupRoot)
            // 设备重置会删掉 user-data.json；紧接着用目标会话 payload 重新写入。
            if resetLog.contains(where: { $0.contains("失败") && !$0.contains("未发现") }) {
                lastSilentSwitchFailureReason = resetLog.first { $0.contains("失败") } ?? "设备身份重置失败"
                // 仍继续尝试写入会话，但保留失败原因供上层降级。
            }
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        let scriptURL = folder.appendingPathComponent("write-active-session.js")

        let result = await Task.detached(priority: .userInitiated) {
            return SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path, payload],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 10
            )
        }.value

        guard result.status == 0 else {
            lastSilentSwitchFailureReason = "写入桌面会话失败：\(result.output.ifEmpty("退出码 \(result.status)"))"
            return false
        }

        // 确保 Typeless 数据目录存在，避免设备缓存被清后 Electron 冷启动路径异常。
        for directory in typelessDesktopSessionDataDirectories() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        launchTypelessInBackground(activate: activateTypeless)
        // 给 Electron 一点时间读入新会话并生成新的 device.cache。
        try? await Task.sleep(nanoseconds: SmartSwitchPolicy.silentInjectSettleSeconds * 1_000_000_000)
        return true
    }

    private func launchTypelessInBackground(activate: Bool) {
        guard let path = typelessAppPath() else {
            if activate { openInstalledTypelessApp() }
            return
        }
        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }


    func addAccount() -> UUID {
        let account = Account.blank(settings: state.settings)
        state.accounts.append(account)
        save()
        return account.id
    }

    func importMoeMailEmail(_ email: MoeMailEmail) -> UUID {
        if let index = state.accounts.firstIndex(where: { $0.email == email.address && !email.address.isEmpty }) {
            state.accounts[index].moeMailEmailID = email.id
            state.accounts[index].domain = email.domain
            state.accounts[index].inboxURL = state.settings.moeMailBaseURL
            save()
            return state.accounts[index].id
        }

        var account = Account.blank(settings: state.settings)
        account.moeMailEmailID = email.id
        account.name = email.displayName
        account.email = email.address
        account.domain = email.domain
        account.inboxURL = state.settings.moeMailBaseURL
        account.notes = "从 MoeMail 导入"
        account.reviewState = .approved
        account.reviewedAt = Date()
        state.accounts.append(account)
        save()
        return account.id
    }

    func deleteAccount(id: UUID) {
        state.accounts.removeAll { $0.id == id }
        save()
    }

    func accountIndex(id: UUID?) -> Int? {
        guard let id else { return nil }
        return state.accounts.firstIndex { $0.id == id }
    }

    func nextAvailableAccountID() -> UUID? {
        nextAvailableAccountID(excluding: nil)
    }

    func nextAvailableAccountID(excluding excludedID: UUID?) -> UUID? {
        state.accounts
            .filter { $0.id != excludedID }
            .filter { $0.isUsable && $0.remainingCharacters > 0 }
            .sorted {
                if $0.remainingCharacters == $1.remainingCharacters {
                    return $0.createdAt < $1.createdAt
                }
                return $0.remainingCharacters > $1.remainingCharacters
            }
            .first?
            .id
    }

    func lastCompletedAutomationAccountID() -> UUID? {
        guard state.lastAutomationResult?.status == .completed else { return nil }
        return state.lastAutomationResult?.accountID
    }

    func pendingReviewAccountIDs() -> [UUID] {
        state.accounts
            .filter { $0.effectiveReviewState == .pending }
            .map(\.id)
    }

    func approveAccount(id: UUID) {
        guard let index = accountIndex(id: id) else { return }
        state.accounts[index].reviewState = .approved
        state.accounts[index].reviewedAt = Date()
        state.accounts[index].status = .available
        if state.accounts[index].notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            state.accounts[index].notes == "候选账号，等待兜底注册核验" {
            state.accounts[index].notes = "已由兜底确认，可用于正常切换"
        }
        save()
        statusMessage = "已确认账号：\(state.accounts[index].email)"
    }

    func rejectAccount(id: UUID) {
        guard let index = accountIndex(id: id) else { return }
        state.accounts[index].reviewState = .rejected
        state.accounts[index].status = .paused
        save()
        statusMessage = "已退回账号：\(state.accounts[index].email)"
    }

    func prepareSwitch(from currentID: UUID?) -> UUID? {
        guard let nextID = nextAvailableAccountID(excluding: currentID),
              let nextIndex = accountIndex(id: nextID) else {
            statusMessage = "没有其它可用账号；当前账号状态未改变。请先导入已有账号或处理兜底确认账号。"
            return nil
        }

        if let currentIndex = accountIndex(id: currentID) {
            state.accounts[currentIndex].status = .exhausted
            state.accounts[currentIndex].usedCharacters = state.accounts[currentIndex].monthlyLimit
        }

        let account = state.accounts[nextIndex]
        copyToClipboard(account.email)
        openInstalledTypelessApp()
        openURL(account.typelessURL)
        openURL(account.inboxURL)
        for index in state.settings.checklist.indices {
            state.settings.checklist[index].isDone = false
        }
        save()
        statusMessage = "已准备切换：\(account.email.isEmpty ? account.name : account.email)"
        return nextID
    }

    func generateCandidateAccounts(count: Int, domain: String) {
        let resolvedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty(state.settings.domains.first ?? "example.com")
        for _ in 0..<max(count, 1) {
            let profile = AccountProfileGenerator.make(domain: resolvedDomain)
            var account = Account.blank(settings: state.settings)
            account.name = profile.displayName
            account.typelessUsername = profile.username
            account.email = profile.email
            account.domain = profile.domain
            account.passwordHint = "强密码已生成，请放入密码管理器"
            account.reviewState = .pending
            account.reviewedAt = nil
            account.status = .paused
            account.notes = "候选账号，等待兜底注册核验"
            state.accounts.append(account)
        }
        save()
        statusMessage = "已生成 \(max(count, 1)) 个候选账号"
    }

    func exportAccountsToClipboard() {
        do {
            let data = try JSONEncoder.appEncoder.encode(state)
            if let text = String(data: data, encoding: .utf8) {
                copyToClipboard(text)
                statusMessage = "已复制账号备份 JSON"
            }
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func importAccountsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            statusMessage = "剪贴板没有可导入的 JSON"
            return
        }

        do {
            let imported = try JSONDecoder.appDecoder.decode(PersistedState.self, from: data)
            state = imported
            save()
            statusMessage = "已从剪贴板导入账号备份"
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func importToolkitAccountsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            statusMessage = "剪贴板没有 typeless-toolkit accounts.json"
            return
        }

        do {
            let root = try JSONSerialization.jsonObject(with: data)
            let rawAccounts: [[String: Any]]
            if let array = root as? [[String: Any]] {
                rawAccounts = array
            } else if let dict = root as? [String: Any],
                      let array = (dict["accounts"] ?? dict["data"]) as? [[String: Any]] {
                rawAccounts = array
            } else {
                statusMessage = "无法识别 toolkit 账号 JSON"
                return
            }

            if state.tokenSummaries == nil { state.tokenSummaries = [] }
            var importedCount = 0
            var tokenCount = 0

            for raw in rawAccounts {
                let imported = ToolkitAccountImporter.importableAccount(from: raw, existingDomains: state.settings.domains)
                let item = imported.account

                var account = Account.blank(settings: state.settings)
                account.name = item.name
                account.email = item.email
                account.domain = item.domain.ifEmpty(state.settings.domains.first ?? "")
                account.role = item.role
                account.typelessUsername = item.typelessUsername
                account.status = .paused
                account.reviewState = .pending
                account.reviewedAt = nil
                account.notes = item.notes

                if let index = state.accounts.firstIndex(where: { !$0.email.isEmpty && $0.email == item.email }) {
                    account.id = state.accounts[index].id
                    account.createdAt = state.accounts[index].createdAt
                    state.accounts[index] = account
                } else {
                    state.accounts.append(account)
                }

                if let summary = imported.tokenSummary {
                    state.tokenSummaries?.removeAll { $0.accountEmail == summary.accountEmail }
                    state.tokenSummaries?.append(summary)
                    tokenCount += 1
                }
                importedCount += 1
            }

            save()
            statusMessage = "已导入 \(importedCount) 个 toolkit 账号；记录 \(tokenCount) 条 token 指纹"
        } catch {
            statusMessage = "toolkit 账号导入失败：\(error.localizedDescription)"
        }
    }

    func exportAccountsCSVToClipboard() {
        let headers = [
            "name", "email", "domain", "role", "monthly_limit", "used_characters",
            "status", "review_state", "moemail_id", "typeless_username", "notes"
        ]
        let rows = state.accounts.map { account in
            [
                account.name,
                account.email,
                account.domain,
                account.role,
                String(account.monthlyLimit),
                String(account.usedCharacters),
                account.status.rawValue,
                account.effectiveReviewState.rawValue,
                account.moeMailEmailID ?? "",
                account.typelessUsername ?? "",
                account.notes
            ]
        }
        let csv = ([headers] + rows)
            .map { $0.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n")
        copyToClipboard(csv)
        statusMessage = "已复制账号表格 CSV"
    }

    func copySwitchSummary(for id: UUID?) {
        guard let index = accountIndex(id: id) else {
            statusMessage = "没有选中账号"
            return
        }
        let account = state.accounts[index]
        let lines = [
            "账号：\(account.name)",
            "邮箱：\(account.email)",
            "用户名：\(account.typelessUsername ?? "")",
            "域名：\(account.domain)",
            "额度：剩余 \(account.remainingCharacters) / \(account.monthlyLimit)",
            "状态：\(account.status.title)，\(account.effectiveReviewState.title)",
            "Typeless：\(account.typelessURL)",
            "邮箱入口：\(account.inboxURL)",
            "备注：\(account.notes)"
        ]
        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制当前账号摘要"
    }

    func copyAccountPoolAuditToClipboard() {
        let duplicates = Dictionary(grouping: state.accounts.filter { !$0.email.isEmpty }, by: { $0.email.lowercased() })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        let missingEmail = state.accounts.filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }
        let exhausted = state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }
        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }
        let lowQuota = available
            .filter { $0.monthlyLimit > 0 && Double($0.remainingCharacters) / Double($0.monthlyLimit) <= 0.15 }
            .sorted { $0.remainingCharacters < $1.remainingCharacters }

        var lines = [
            "Typeless Switchboard 账号池体检",
            "总账号：\(state.accounts.count)",
            "可用账号：\(available.count)",
            "待兜底确认：\(pending.count)",
            "本月已用完：\(exhausted.count)",
            "重复邮箱：\(duplicates.count)",
            "未填写邮箱：\(missingEmail.count)",
            ""
        ]

        if !duplicates.isEmpty {
            lines.append("重复邮箱")
            lines += duplicates.map { "- \($0)" }
            lines.append("")
        }

        if !missingEmail.isEmpty {
            lines.append("未填写邮箱")
            lines += missingEmail.map { "- \($0.name)" }
            lines.append("")
        }

        if !pending.isEmpty {
            lines.append("待兜底确认")
            lines += pending.map { "- \($0.email.ifEmpty($0.name))" }
            lines.append("")
        }

        if !lowQuota.isEmpty {
            lines.append("剩余额度低于 15%")
            lines += lowQuota.map { "- \($0.email.ifEmpty($0.name))：\($0.remainingCharacters) / \($0.monthlyLimit)" }
            lines.append("")
        }

        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制账号池体检报告"
    }

    func copyTypelessEnvironmentReport() {
        let appPath = typelessAppPath() ?? "未找到"
        let executablePath = typelessExecutablePath() ?? "未找到"
        let userData = typelessUserDataDir()
        let cache = typelessDeviceCacheDir()
        let lines = [
            "Typeless macOS 环境报告",
            "App Bundle：\(appPath)",
            "可执行文件：\(executablePath)",
            "登录态目录：\(userData.path) \(FileManager.default.fileExists(atPath: userData.path) ? "✅" : "⚠️ 不存在")",
            "设备缓存目录：\(cache.path) \(FileManager.default.fileExists(atPath: cache.path) ? "✅" : "⚠️ 不存在")",
            "设备凭据 Service：\(typelessCredentialTarget)",
            "设备凭据 Account：\(typelessCredentialAccount)",
            "兼容旧凭据名：\(typelessLegacyCredentialTarget)",
            "复制报告本身只读；一键换号会按 typeless-toolkit resetDevice 逻辑重置设备 ID，并隔离 Typeless 桌面登录态和工具浏览器登录态。"
        ]
        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制 Typeless 环境报告"
    }

    func copyTokenAuditReport() {
        let summaries = state.tokenSummaries ?? []
        var lines = [
            "Typeless token 指纹报告",
            "记录数量：\(summaries.count)",
            "说明：这里只保存 sha256 指纹和字段名，不保存 token 明文。",
            ""
        ]

        if summaries.isEmpty {
            lines.append("还没有导入带 token 字段的 toolkit 账号。")
        } else {
            lines += summaries
                .sorted { $0.importedAt > $1.importedAt }
                .map { summary in
                    [
                        "- 账号：\(summary.accountEmail.ifEmpty("未填写邮箱"))",
                        "  access：\(summary.accessTokenFingerprint ?? "未发现")",
                        "  refresh：\(summary.refreshTokenFingerprint ?? "未发现")",
                        "  字段：\(summary.discoveredKeys.joined(separator: ", "))",
                        "  时间：\(summary.importedAt)"
                    ].joined(separator: "\n")
                }
        }

        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制 token 指纹报告"
    }

    func captureLoginSnapshotManifest() {
        let source = typelessUserDataDir()
        guard FileManager.default.fileExists(atPath: source.path) else {
            statusMessage = "登录态目录不存在，无法生成快照清单"
            return
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [SnapshotFile] = []

        while let url = enumerator?.nextObject() as? URL, files.count < 500 {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(source.path + "/")
                ? String(url.path.dropFirst(source.path.count + 1))
                : url.lastPathComponent
            files.append(SnapshotFile(
                path: relative,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? Date()
            ))
        }

        let manifest = LoginSnapshotManifest.make(
            sourcePath: source.path,
            files: files,
            includeSensitiveContents: false
        )
        if state.loginSnapshots == nil { state.loginSnapshots = [] }
        state.loginSnapshots?.insert(manifest, at: 0)
        save()
        copyToClipboard(manifest.markdown)
        statusMessage = "已生成登录态快照清单：\(files.count) 个文件"
    }

    func copyLatestLoginSnapshotManifest() {
        guard let manifest = state.loginSnapshots?.first else {
            statusMessage = "还没有登录态快照清单"
            return
        }
        copyToClipboard(manifest.markdown)
        statusMessage = "已复制最近一次登录态快照清单"
    }

    func copyDeviceInfoReport() {
        let report = DeviceInfoReport.make(
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelIdentifier: macModelIdentifier(),
            appPath: typelessAppPath() ?? "未找到",
            loginDataPath: typelessUserDataDir().path,
            cachePath: typelessDeviceCacheDir().path
        )
        state.deviceReport = report
        save()
        copyToClipboard(report.markdown)
        statusMessage = "已复制设备信息报告"
    }

    func copyRegistrationPreparationPlan(for id: UUID?) {
        guard let index = accountIndex(id: id) else {
            statusMessage = "没有选中账号"
            return
        }

        let account = state.accounts[index]
        let candidate = RegistrationCandidate(
            displayName: account.name,
            username: (account.typelessUsername ?? account.name).ifEmpty(account.email.components(separatedBy: "@").first ?? account.name),
            email: account.email,
            domain: account.domain,
            passwordHint: account.passwordHint ?? "请使用密码管理器里的强密码"
        )
        let plan = RegistrationPreparationPlan.make(candidate: candidate, typelessURL: account.typelessURL)
        if state.registrationPlans == nil { state.registrationPlans = [] }
        state.registrationPlans?.insert(plan, at: 0)
        save()
        copyToClipboard(plan.markdown)
        statusMessage = "已复制注册准备包"
    }

    func copyTroubleshootingBundle() {
        let appPath = typelessAppPath() ?? "未找到"
        let executablePath = typelessExecutablePath() ?? "未找到"
        let userData = typelessUserDataDir()
        let cache = typelessDeviceCacheDir()

        let total = state.accounts.count
        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }.count
        let exhausted = state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }.count
        let missingEmail = state.accounts.filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count

        var lines = [
            "Typeless Switchboard 排障包",
            "生成时间：\(Date())",
            "",
            "【Typeless】",
            "入口：\(state.settings.typelessLoginURL)",
            "App Bundle：\(appPath)",
            "可执行文件：\(executablePath)",
            "登录态目录：\(userData.path) \(FileManager.default.fileExists(atPath: userData.path) ? "✅" : "⚠️ 不存在")",
            "设备缓存目录：\(cache.path) \(FileManager.default.fileExists(atPath: cache.path) ? "✅" : "⚠️ 不存在")",
            "",
            "【MoeMail】",
            "地址：\(state.settings.moeMailBaseURL)",
            "域名数量：\(state.settings.domains.count)",
            "邮箱列表缓存：\(moeMailEmails.count)",
            "邮件列表缓存：\(moeMailMessages.count)",
            "",
            "【账号池】",
            "总账号：\(total)",
            "可切换账号：\(available)",
            "待兜底确认账号：\(pending)",
            "本月已用完：\(exhausted)",
            "未填写邮箱：\(missingEmail)",
            "",
            "【最近自检】"
        ]

        if diagnostics.isEmpty {
            lines.append("还没有运行一键自检")
        } else {
            lines += diagnostics.map { "- [\($0.level.title)] \($0.title)：\($0.detail)" }
        }

        lines += [
            "",
            "说明：此排障包不包含 MoeMail API Key、不包含密码、不包含验证码。",
            "当前工具支持浏览器自动注册、验证码轮询和结果桥接；一键换号会按 typeless-toolkit resetDevice 逻辑重置本机设备身份，并隔离 Typeless 桌面登录态和工具浏览器登录态。"
        ]

        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制完整排障包"
    }

    private func macModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "未知"
        }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "未知"
        }
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func openTypelessOfficialWebsite() {
        openURL(typelessOfficialURL)
        statusMessage = "已打开 Typeless 官网"
    }

    func openInstalledTypelessApp() {
        if let path = typelessAppPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            statusMessage = "已打开本机 Typeless App"
            return
        }

        openURL(typelessOfficialURL)
        statusMessage = "未找到本机 Typeless App，已打开官网"
    }

    private func typelessAppPath() -> String? {
        let candidates = [
            "/Applications/Typeless.app",
            "\(NSHomeDirectory())/Applications/Typeless.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func typelessExecutablePath() -> String? {
        let candidates = [
            "/Applications/Typeless.app/Contents/MacOS/Typeless",
            "\(NSHomeDirectory())/Applications/Typeless.app/Contents/MacOS/Typeless"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func firstExistingAppSupportPath(_ names: [String]) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in names {
            let url = appSupport.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return appSupport.appendingPathComponent(names.first ?? "Typeless")
    }

    private func typelessUserDataDir() -> URL {
        firstExistingAppSupportPath(["Typeless.exe", "Typeless"])
    }

    private func typelessDeviceCacheDir() -> URL {
        let candidates = typelessDeviceCacheDirectories()
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    private func typelessDeviceCacheDirectories() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates = [
            appSupport.appendingPathComponent("now.typeless.desktop", isDirectory: true),
            appSupport.appendingPathComponent("Typeless/Cache", isDirectory: true),
            appSupport.appendingPathComponent("Typeless.exe/Cache", isDirectory: true),
            appSupport.appendingPathComponent("Typeless", isDirectory: true),
            appSupport.appendingPathComponent("Typeless.exe", isDirectory: true)
        ]
        return candidates.reduce(into: [URL]()) { result, url in
            if !result.contains(where: { $0.path == url.path }) {
                result.append(url)
            }
        }
    }

    func checkTypelessEntry() async {
        guard let url = URL(string: state.settings.typelessLoginURL) else {
            statusMessage = "Typeless 入口地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<400).contains(code) {
                statusMessage = "Typeless 入口可访问：HTTP \(code)"
            } else {
                statusMessage = "Typeless 入口返回 HTTP \(code)，建议打开官网或本机 App"
            }
        } catch {
            statusMessage = "Typeless 入口检查失败：\(error.localizedDescription)"
        }
    }

    func runSetupDiagnostics(apiKey: String) async {
        var results: [DiagnosticItem] = []

        let appExists = typelessAppPath() != nil
        results.append(DiagnosticItem(
            title: "Typeless App",
            detail: appExists ? "已找到本机 Typeless App" : "未找到本机 App，会改用官网入口",
            level: appExists ? .ok : .warning
        ))
        appendMacPermissionDiagnostics(to: &results)

        if let url = URL(string: state.settings.typelessLoginURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                results.append(DiagnosticItem(
                    title: "Typeless 入口",
                    detail: (200..<400).contains(code) ? "入口可访问，HTTP \(code)" : "入口返回 HTTP \(code)，建议打开官网或本机 App",
                    level: (200..<400).contains(code) ? .ok : .warning
                ))
            } catch {
                results.append(DiagnosticItem(
                    title: "Typeless 入口",
                    detail: "入口检查失败：\(error.localizedDescription)",
                    level: .error
                ))
            }
        } else {
            results.append(DiagnosticItem(title: "Typeless 入口", detail: "入口地址格式无效", level: .error))
        }

        if URL(string: state.settings.moeMailBaseURL) == nil {
            results.append(DiagnosticItem(title: "MoeMail 地址", detail: "MoeMail 地址格式无效", level: .error))
        } else if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(DiagnosticItem(title: "MoeMail API Key", detail: "未填写 API Key，无法读取邮箱和邮件", level: .warning))
        } else {
            do {
                guard let url = moeMailURL(path: "/api/config") else {
                    throw NSError(domain: "MoeMail", code: -1, userInfo: [NSLocalizedDescriptionKey: "MoeMail 地址无效"])
                }
                let data = try await moeMailRequest(url: url, apiKey: apiKey)
                let domains = extractDomains(from: data)
                results.append(DiagnosticItem(
                    title: "MoeMail 配置",
                    detail: domains.isEmpty ? "API 可连通，但没有识别到域名" : "API 可连通，识别到 \(domains.count) 个域名",
                    level: domains.isEmpty ? .warning : .ok
                ))
            } catch {
                results.append(DiagnosticItem(title: "MoeMail 配置", detail: "连接失败：\(error.localizedDescription)", level: .error))
            }
        }

        let nodeCheck = await automationCommandVersion(command: "node", versionArgument: "--version")
        results.append(DiagnosticItem(
            title: "Node.js 自动化",
            detail: nodeCheck.isEmpty ? "未检测到 node；全自动浏览器注册会降级为脚本和手动兜底" : "已检测到 node：\(nodeCheck)",
            level: nodeCheck.isEmpty ? .warning : .ok
        ))

        let npmCheck = await automationCommandVersion(command: "npm", versionArgument: "--version")
        results.append(DiagnosticItem(
            title: "npm / Playwright",
            detail: npmCheck.isEmpty ? "未检测到 npm；无法自动安装/运行 Playwright" : "已检测到 npm：\(npmCheck)，准备预热 Playwright 运行时",
            level: npmCheck.isEmpty ? .warning : .ok
        ))

        if !nodeCheck.isEmpty && !npmCheck.isEmpty {
            let runtime = await prepareAutomationRuntime()
            results.append(DiagnosticItem(
                title: "Playwright 运行时",
                detail: runtime.message,
                level: runtime.success ? .ok : .warning
            ))
        }

        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }.count
        results.append(DiagnosticItem(
            title: "可切换账号",
            detail: available > 0 ? "有 \(available) 个已确认可用账号" : "没有已确认可用账号，需要先导入账号或处理兜底确认账号",
            level: available > 0 ? .ok : .warning
        ))

        if pending > 0 {
            results.append(DiagnosticItem(title: "待兜底确认账号", detail: "\(pending) 个候选账号等待兜底确认", level: .warning))
        }

        diagnostics = results
        let errors = results.filter { $0.level == .error }.count
        let warnings = results.filter { $0.level == .warning }.count
        statusMessage = errors > 0 ? "自检完成：\(errors) 个问题需要处理" : "自检完成：\(warnings) 个注意项"
    }

    /// 权限探测结果缓存，避免后台热备/巡检反复触发系统弹窗。
    private var cachedAccessibilityTrusted: Bool?
    private var cachedAutomationOK: Bool?
    private var cachedAutomationDetail = ""
    private var lastPermissionProbeAt: Date?
    private var didAutoOpenPermissionSettingsThisSession = false
    private let permissionProbeCacheTTL: TimeInterval = 30 * 60

    private func refreshPermissionCacheIfNeeded(force: Bool = false, probeAppleEvents: Bool = true) {
        if !force,
           let last = lastPermissionProbeAt,
           Date().timeIntervalSince(last) < permissionProbeCacheTTL,
           cachedAccessibilityTrusted != nil {
            return
        }

        // 只做静默检查，绝不调用 AXIsProcessTrustedWithOptions(prompt:true)。
        // prompt:true 会在未授权/签名变化时反复弹出“想使用辅助功能”。
        cachedAccessibilityTrusted = AXIsProcessTrusted()

        if probeAppleEvents {
            // Apple Events 探测也可能弹“自动化”授权；后台路径默认跳过，仅自检/手动时探测。
            let chromeProbe = Self.runAppleEventsProbe(#"tell application "Google Chrome" to get version"#)
            let systemEventsProbe = Self.runAppleEventsProbe(#"tell application "System Events" to count processes"#)
            cachedAutomationOK = chromeProbe.success && systemEventsProbe.success
            cachedAutomationDetail = "Chrome：\(chromeProbe.message)；System Events：\(systemEventsProbe.message)"
        } else if cachedAutomationOK == nil {
            cachedAutomationOK = true
            cachedAutomationDetail = "后台路径跳过 Apple Events 探测，避免重复弹窗"
        }

        lastPermissionProbeAt = Date()
    }

    private func appendMacPermissionDiagnostics(to results: inout [DiagnosticItem]) {
        refreshPermissionCacheIfNeeded(force: true, probeAppleEvents: true)
        let accessibilityTrusted = cachedAccessibilityTrusted == true
        results.append(DiagnosticItem(
            title: "电脑权限：辅助功能",
            detail: accessibilityTrusted
                ? "已允许辅助功能控制；可自动点击 Chrome 弹窗、System Events 弹窗和 Typeless 交接。"
                : "需要在系统设置 → 隐私与安全性 → 辅助功能中允许 TypelessSwitchboard，才能自动点击 Chrome 的“打开 Typeless.app”弹窗。请只开一次；工具不会反复弹授权窗。",
            level: accessibilityTrusted ? .ok : .warning
        ))

        let automationOK = cachedAutomationOK == true
        results.append(DiagnosticItem(
            title: "电脑权限：自动化",
            detail: automationOK
                ? "Apple Events 已可控制 Google Chrome 和 System Events。"
                : "需要在系统设置 → 隐私与安全性 → 自动化（Privacy_Automation）允许 TypelessSwitchboard 控制 Google Chrome 和 System Events。\(cachedAutomationDetail)",
            level: automationOK ? .ok : .warning
        ))

        if let externalProtocolItem = MacPermissionChecklist.recommendedItems.first(where: { $0.title.contains("Google Chrome 外部协议") }) {
            results.append(DiagnosticItem(
                title: "电脑权限：Chrome 外部协议",
                detail: externalProtocolItem.detail,
                level: .warning
            ))
        }

        let typelessPermissionTitles = ["麦克风", "输入监听", "屏幕录制"]
        let typelessPermissionDetails = MacPermissionChecklist.recommendedItems
            .filter { item in typelessPermissionTitles.contains { item.title.contains($0) } }
            .map(\.detail)
            .joined(separator: " ")
        results.append(DiagnosticItem(
            title: "Typeless 权限：麦克风 / 输入监听 / 屏幕录制",
            detail: typelessPermissionDetails.ifEmpty("给 Typeless.app 打开麦克风、输入监听和屏幕录制权限，切到新账号后才能直接录音、快捷键唤起和显示浮窗。"),
            level: .warning
        ))
    }

    /// 注册前权限预检：只静默检查，绝不反复弹系统授权窗。
    /// - Parameter interactive: 用户手动点换号时为 true，允许整次会话最多打开一次系统设置。
    private func preflightMacPermissionsBeforeAutomaticReplacement(
        log: inout [String],
        interactive: Bool = false
    ) -> Bool {
        log.append("开始注册前权限预检：静默检查辅助功能与自动化（不弹系统授权窗）")

        // 后台热备/巡检：只用缓存 + 静默 AX 检查，不探测 Apple Events，避免连环弹窗。
        refreshPermissionCacheIfNeeded(force: interactive, probeAppleEvents: interactive)

        let accessibilityTrusted = cachedAccessibilityTrusted == true
        let automationOK = cachedAutomationOK != false

        if accessibilityTrusted {
            log.append("权限预检通过：辅助功能 Accessibility 已允许")
        } else {
            log.append("权限预警：辅助功能 Accessibility 未允许；Playwright 注册可继续，自动点 Chrome 弹窗可能受限")
            if interactive {
                openMacPermissionSettingsOnce("Privacy_Accessibility")
            }
        }

        if automationOK {
            log.append("权限预检通过：自动化 Apple Events 状态可用或已跳过探测")
        } else {
            log.append("权限预警：自动化 Apple Events 可能未完全允许。\(cachedAutomationDetail)")
            if interactive {
                openMacPermissionSettingsOnce("Privacy_Automation")
            }
        }

        // 不再因权限缺失硬暂停：反复 hard-fail + 后台重试会导致用户一直看到授权/设置弹窗。
        // Playwright 注册本身不依赖辅助功能；缺权限时最多降级自动点弹窗能力。
        if !accessibilityTrusted || !automationOK {
            log.append("权限未齐也继续执行；请在系统设置里一次性允许后，重建签名的 App 也只需再开一次")
            if interactive {
                statusMessage = "权限未齐：已继续换号；辅助功能/自动化请在系统设置里一次性打开"
            }
        } else {
            log.append("权限预检完成：继续执行创建邮箱、清理环境和自动换号逻辑")
        }
        return true
    }

    func copyMacPermissionChecklist() {
        copyToClipboard(MacPermissionChecklist.markdown)
        statusMessage = "已复制 macOS 权限清单"
    }

    /// 用户主动点 UI 时打开系统设置；自动流程整次会话最多打开一次。
    func openMacPermissionSettings(_ settingsPaneIdentifier: String) {
        openMacPermissionSettingsOnce(settingsPaneIdentifier, force: true)
    }

    private func openMacPermissionSettingsOnce(_ settingsPaneIdentifier: String, force: Bool = false) {
        if !force, didAutoOpenPermissionSettingsThisSession {
            return
        }
        if !force {
            didAutoOpenPermissionSettingsThisSession = true
        }

        // 优先用现代 System Settings URL，减少旧路径反复拉起。
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(settingsPaneIdentifier)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsPaneIdentifier)"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                statusMessage = "已打开系统设置：\(settingsPaneIdentifier)（只需允许一次）"
                return
            }
        }
        statusMessage = "权限设置入口无效：\(settingsPaneIdentifier)"
    }

    func openDataFolder() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
            statusMessage = "已打开本地数据文件夹"
        } catch {
            statusMessage = "打开数据文件夹失败：\(error.localizedDescription)"
        }
    }

    func copyDataPath() {
        copyToClipboard(fileURL.path)
        statusMessage = "已复制本地数据路径"
    }

    func importAccountsCSVFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "剪贴板没有可导入的 CSV"
            return
        }

        let rows = parseCSV(text)
        guard let header = rows.first else {
            statusMessage = "CSV 内容为空"
            return
        }

        let keys = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element.lowercased(), $0.offset) })
        var importedCount = 0

        for row in rows.dropFirst() {
            let email = csvValue(row, keys: keys, name: "email")
            guard !email.isEmpty else { continue }

            let domain = csvValue(row, keys: keys, name: "domain")
                .ifEmpty(email.components(separatedBy: "@").last ?? state.settings.domains.first ?? "")
            let status = AccountStatus(rawValue: csvValue(row, keys: keys, name: "status")) ?? .paused
            let reviewState = ReviewState(rawValue: csvValue(row, keys: keys, name: "review_state")) ?? .pending

            var account = Account.blank(settings: state.settings)
            account.name = csvValue(row, keys: keys, name: "name").ifEmpty(email.components(separatedBy: "@").first ?? "导入账号")
            account.email = email
            account.domain = domain
            account.role = csvValue(row, keys: keys, name: "role").ifEmpty("平民")
            account.monthlyLimit = Int(csvValue(row, keys: keys, name: "monthly_limit")) ?? 8000
            account.usedCharacters = Int(csvValue(row, keys: keys, name: "used_characters")) ?? 0
            account.status = status
            account.reviewState = reviewState
            account.reviewedAt = reviewState == .approved ? Date() : nil
            account.moeMailEmailID = csvValue(row, keys: keys, name: "moemail_id").nilIfEmpty
            account.typelessUsername = csvValue(row, keys: keys, name: "typeless_username").nilIfEmpty
            account.notes = csvValue(row, keys: keys, name: "notes")

            if let index = state.accounts.firstIndex(where: { $0.email == email }) {
                account.id = state.accounts[index].id
                account.createdAt = state.accounts[index].createdAt
                state.accounts[index] = account
            } else {
                state.accounts.append(account)
            }
            importedCount += 1
        }

        save()
        statusMessage = "已导入 \(importedCount) 个 CSV 账号"
    }

    func resetMonthlyQuotaForApprovedAccounts() {
        var count = 0
        for index in state.accounts.indices where state.accounts[index].effectiveReviewState == .approved {
            state.accounts[index].usedCharacters = 0
            state.accounts[index].status = .available
            state.accounts[index].lastResetAt = Date()
            count += 1
        }
        save()
        statusMessage = "已重置 \(count) 个已确认账号的本月额度"
    }

    func resetChecklist() {
        for index in state.settings.checklist.indices {
            state.settings.checklist[index].isDone = false
        }
        save()
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToClipboard(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func csvValue(_ row: [String], keys: [String: Int], name: String) -> String {
        guard let index = keys[name], row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolkitString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return ""
    }

    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n" && !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    func refreshMoeMailConfig(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return
        }
        guard let base = URL(string: state.settings.moeMailBaseURL),
              let url = URL(string: "/api/config", relativeTo: base) else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                statusMessage = "MoeMail 配置读取失败：HTTP \(status)"
                return
            }

            let discovered = extractDomains(from: data)
            if discovered.isEmpty {
                statusMessage = "MoeMail 已连通，但没有识别到新域名"
            } else {
                var merged = state.settings.domains
                for domain in discovered where !merged.contains(domain) {
                    merged.append(domain)
                }
                state.settings.domains = merged
                save()
                statusMessage = "已同步 \(discovered.count) 个域名"
            }
        } catch {
            statusMessage = "MoeMail 连接失败：\(error.localizedDescription)"
        }
    }

    func loadMoeMailEmails(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return
        }
        guard let url = moeMailURL(path: "/api/emails") else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        do {
            let data = try await moeMailRequest(url: url, apiKey: apiKey)
            let emails = parseMoeMailEmails(from: data)
            moeMailEmails = emails
            statusMessage = emails.isEmpty ? "没有读取到邮箱" : "已读取 \(emails.count) 个邮箱"
        } catch {
            statusMessage = "邮箱列表读取失败：\(error.localizedDescription)"
        }
    }

    func generateMoeMailEmail(apiKey: String, name: String, domain: String, expiryTime: Int) async -> MoeMailEmail? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return nil
        }
        guard let url = moeMailURL(path: "/api/emails/generate") else {
            statusMessage = "MoeMail 地址无效"
            return nil
        }

        let payload: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "typeless" : name,
            "expiryTime": expiryTime,
            "domain": domain
        ]

        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await moeMailRequest(url: url, apiKey: apiKey, method: "POST", body: body)
            let emails = parseMoeMailEmails(from: data)
            if let email = emails.first {
                if !moeMailEmails.contains(where: { $0.id == email.id }) {
                    moeMailEmails.insert(email, at: 0)
                }
                statusMessage = "已生成邮箱：\(email.address)"
                return email
            }

            await loadMoeMailEmails(apiKey: apiKey)
            statusMessage = "已请求生成邮箱，请在列表中确认"
            return nil
        } catch {
            statusMessage = "生成邮箱失败：\(error.localizedDescription)"
            return nil
        }
    }

    func createMoeMailRegistrationCandidate(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        copyPasswordToClipboard: Bool = true
    ) async -> UUID? {
        let resolvedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty(state.settings.domains.first ?? "example.com")
        let profile = AccountProfileGenerator.make(domain: resolvedDomain)
        let localPart = profile.email.components(separatedBy: "@").first ?? profile.username

        guard let email = await generateMoeMailEmail(
            apiKey: apiKey,
            name: localPart,
            domain: resolvedDomain,
            expiryTime: expiryTime
        ) else {
            return nil
        }

        var account = Account.blank(settings: state.settings)
        account.moeMailEmailID = email.id
        account.name = profile.displayName
        account.typelessUsername = profile.username
        account.email = email.address.ifEmpty(profile.email)
        account.domain = email.domain.ifEmpty(resolvedDomain)
        account.passwordHint = "强密码已保存到 macOS Keychain"
        account.reviewState = .pending
        account.reviewedAt = nil
        account.status = .paused
        account.usedCharacters = 0
        account.inboxURL = state.settings.moeMailBaseURL
        account.notes = "MoeMail 已生成；等待兜底完成 Typeless 注册与邮箱验证码核验"

        if let index = state.accounts.firstIndex(where: { !$0.email.isEmpty && $0.email == account.email }) {
            account.id = state.accounts[index].id
            account.createdAt = state.accounts[index].createdAt
            state.accounts[index] = account
        } else {
            state.accounts.insert(account, at: 0)
        }

        KeychainStore.saveAccountPassword(profile.password, accountID: account.id)

        let candidate = RegistrationCandidate(
            displayName: account.name,
            username: account.typelessUsername ?? profile.username,
            email: account.email,
            domain: account.domain,
            passwordHint: "强密码已保存到 macOS Keychain"
        )
        let plan = RegistrationPreparationPlan.make(candidate: candidate, typelessURL: account.typelessURL)
        if state.registrationPlans == nil { state.registrationPlans = [] }
        state.registrationPlans?.insert(plan, at: 0)

        if copyPasswordToClipboard {
            copyToClipboard(profile.password)
        }
        save()
        statusMessage = copyPasswordToClipboard
            ? "已创建注册候选账号，强密码已保存到 Keychain 并复制：\(account.email)"
            : "已创建注册候选账号，强密码已保存到 Keychain：\(account.email)"
        return account.id
    }

    func runOneClickAutomaticReplacement(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        from currentID: UUID?,
        preserveCurrentAccount: Bool = false,
        interactive: Bool = false
    ) async -> UUID? {
        guard !isRunningAutomaticReplacement else {
            statusMessage = "全自动换号正在运行中"
            return nil
        }

        isRunningAutomaticReplacement = true
        defer { isRunningAutomaticReplacement = false }

        var log: [String] = [
            preserveCurrentAccount ? "开始热备注册（不切换当前使用号）" : "开始全自动一键换号"
        ]
        let previousAccount = currentID
            .flatMap { id in accountIndex(id: id).map { state.accounts[$0] } }
        var previousAccountEmailForResult = previousAccount?.email

        // 热备/后台：interactive=false，绝不弹辅助功能授权窗、不反复打开系统设置。
        guard preflightMacPermissionsBeforeAutomaticReplacement(
            log: &log,
            interactive: interactive && !preserveCurrentAccount
        ) else {
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountID: nil,
                accountEmail: "",
                username: "",
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            return currentID
        }

        statusMessage = "正在准备 Node/npm/Playwright 自动化运行环境..."
        let runtime = await prepareAutomationRuntime()
        guard runtime.success else {
            log.append(runtime.message)
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountEmail: "",
                username: "",
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            statusMessage = "自动化运行环境未准备好，未创建新账号：\(runtime.message)"
            return nil
        }
        log.append(runtime.message)

        if preserveCurrentAccount {
            // 热备：只在独立 Playwright profile 里注册，绝不碰当前桌面/Chrome 登录态。
            log.append("热备模式：跳过桌面/Chrome 清理与 handoff，避免打断当前使用")
        } else {
            let staleChromePromptLog = resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement()
            log.append(contentsOf: staleChromePromptLog)
            let staleChromeTabsLog = closePersonalChromeTypelessTabsBeforeReplacement()
            log.append(contentsOf: staleChromeTabsLog)
            let desktopPreparationLog = prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement()
            log.append(contentsOf: desktopPreparationLog)
            let browserSessionPreparationLog = prepareRetainedTypelessBrowserSessionsForAutomaticReplacement()
            log.append(contentsOf: browserSessionPreparationLog)
            let chromePreparationLog = preparePersonalChromeTypelessWebSessionForAutomaticReplacement()
            log.append(contentsOf: chromePreparationLog)
        }
        statusMessage = preserveCurrentAccount
            ? "正在后台注册热备账号…"
            : "正在创建新的 MoeMail 邮箱和 Typeless 注册资料..."

        guard let newID = await createMoeMailRegistrationCandidate(
            apiKey: apiKey,
            domain: domain,
            expiryTime: expiryTime,
            copyPasswordToClipboard: false
        ), let index = accountIndex(id: newID) else {
            log.append("创建新候选账号失败；一键自动流程不会兜底打开邮箱页或切到旧账号")
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountID: nil,
                accountEmail: "",
                username: "",
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            statusMessage = "创建新 MoeMail 邮箱失败，未打开邮箱页，旧账号未改变"
            return currentID
        }

        var account = state.accounts[index]
        let password = KeychainStore.readAccountPassword(accountID: account.id)
        guard !password.isEmpty else {
            log.append("Keychain 中没有读取到账户密码")
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountID: account.id,
                accountEmail: account.email,
                username: account.typelessUsername ?? account.name,
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            return nil
        }

        log.append("新邮箱已创建：\(account.email)")
        log.append("强密码已保存到 Keychain")

        let verificationCodeFileURL = makeVerificationCodeBridgeFileURL(account: account)
        let automationResultFileURL = makeAutomationResultBridgeFileURL(account: account)
        try? FileManager.default.removeItem(at: verificationCodeFileURL)
        try? FileManager.default.removeItem(at: automationResultFileURL)

        let firstScriptURL = writeRegistrationAutomationScript(
            account: account,
            password: password,
            verificationCode: nil,
            verificationCodeFileURL: verificationCodeFileURL,
            automationResultFileURL: automationResultFileURL
        )
        var automationTask: Task<(success: Bool, message: String), Never>?
        if let firstScriptURL {
            log.append("已生成注册自动化脚本：\(firstScriptURL.path)")
            log.append("网页登录态将保留在固定浏览器目录：\(makeBrowserProfileDirectoryURL(account: account).path)")
            statusMessage = "正在尝试自动打开并填写 Typeless 注册页..."
            automationTask = Task { await runPlaywrightScript(firstScriptURL, password: password) }
            log.append("Playwright 脚本已启动并等待验证码文件：\(verificationCodeFileURL.path)")
        } else {
            log.append("注册自动化脚本生成失败")
        }

        log.append("注册阶段后台运行：不自动弹出邮箱页或注册页")

        statusMessage = "正在轮询 MoeMail 验证码..."
        let verificationCode = await pollVerificationCode(
            for: account,
            apiKey: apiKey,
            attempts: RegistrationAutomationTiming.moeMailPollingAttempts,
            delaySeconds: RegistrationAutomationTiming.moeMailPollingDelaySeconds
        )
        if let verificationCode {
            log.append("已提取验证码：\(verificationCode)")
            copyToClipboard(verificationCode)
            writeVerificationCode(verificationCode, to: verificationCodeFileURL)
            log.append("已写入验证码桥接文件，浏览器脚本会继续提交")
        } else {
            log.append("暂未从 MoeMail 邮件中提取到验证码，已打开邮箱并保留账号资料")
            writeVerificationCode("NO_CODE", to: verificationCodeFileURL)
            copyToClipboard(account.email)
        }

        if let automationTask {
            let runResult = await automationTask.value
            log.append(runResult.message)
        }
        let browserResult = readAutomationResult(from: automationResultFileURL)
        if let browserResult {
            log.append("浏览器结果：\(browserResult.summary)")
            if previousAccountEmailForResult?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
               let detected = browserResult.detectedPreviousAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detected.isEmpty {
                previousAccountEmailForResult = detected
                log.append("自动检测到旧账号：\(detected)")
            }
            if browserResult.isLikelyRegistrationComplete {
                log.append("浏览器结果判定：注册大概率完成")
            } else {
                log.append("浏览器结果判定：仍可能停留在注册/验证/错误页面，需要兜底确认")
            }
        } else {
            log.append("未读取到浏览器结果文件，保留脚本和账号资料供兜底")
        }

        let automationComplete = RegistrationAutomationCompletionPolicy.isComplete(
            verificationCode: verificationCode,
            browserResult: browserResult
        )

        if automationComplete,
           !preserveCurrentAccount,
           let currentIndex = accountIndex(id: currentID),
           state.accounts[currentIndex].id != account.id {
            state.accounts[currentIndex].status = .exhausted
            state.accounts[currentIndex].usedCharacters = state.accounts[currentIndex].monthlyLimit
            state.accounts[currentIndex].notes = "已由全自动一键换号替换为：\(account.email)"
        }

        if let refreshedIndex = accountIndex(id: account.id) {
            state.accounts[refreshedIndex].passwordHint = "强密码已保存到 macOS Keychain"
            if automationComplete {
                state.accounts[refreshedIndex].reviewState = .approved
                state.accounts[refreshedIndex].reviewedAt = Date()
                state.accounts[refreshedIndex].status = .available
                state.accounts[refreshedIndex].usedCharacters = 0
                state.accounts[refreshedIndex].notes = preserveCurrentAccount
                    ? "热备账号：已注册完成，等待无感静默切换"
                    : "自动换号已提取验证码，浏览器结果判定注册完成，可用于切换"
            } else {
                state.accounts[refreshedIndex].reviewState = .pending
                state.accounts[refreshedIndex].reviewedAt = nil
                state.accounts[refreshedIndex].status = .paused
                state.accounts[refreshedIndex].notes = verificationCode == nil
                    ? "自动换号已创建账号资料；验证码暂未提取，等待兜底确认"
                    : "自动换号已提取验证码并尝试提交；浏览器结果未证明注册完成，等待兜底确认"
            }
            account = state.accounts[refreshedIndex]
        }

        let browserProfileURL = makeBrowserProfileDirectoryURL(account: account)
        if automationComplete {
            // 优先从浏览器 profile 抽出 token，写成可静默注入的桌面会话 payload。
            if let tokenInfo = extractTypelessTokenInfo(
                fromBrowserProfile: browserProfileURL.path,
                expectedEmail: account.email
            ),
               let desktopPayload = SmartSwitchPolicy.desktopUserDataPayload(fromBrowserTokenInfo: tokenInfo),
               let refreshedIndex = accountIndex(id: account.id) {
                state.accounts[refreshedIndex].rawUserDataPayload = desktopPayload
                account = state.accounts[refreshedIndex]
                log.append("已从浏览器 profile 固化静默会话缓存，可供下次无感换号秒切")
            }

            if !preserveCurrentAccount {
                log.append(contentsOf: syncPersonalChromeTypelessWebSession(
                    account: account,
                    profileDirectoryPath: browserProfileURL.path
                ))
                log.append(handoffRetainedTypelessProfileToDesktopOnce(
                    profileDirectoryPath: browserProfileURL.path,
                    expectedEmail: account.email
                ))
                log.append("新账号浏览器会话已保留：\(browserProfileURL.path)；未自动打开额外浏览器，需要排查时再点“打开新账号会话”")
                log.append(contentsOf: completeTypelessDesktopOnboardingIfPresent(
                    expectedEmail: account.email,
                    timeoutSeconds: 120
                ))
            } else {
                log.append("热备模式：已保留浏览器 profile，未切换当前桌面/Chrome 使用号")
            }
        }

        if !preserveCurrentAccount {
            copyToClipboard(automationComplete ? account.email : (verificationCode ?? account.email))
            for index in state.settings.checklist.indices {
                state.settings.checklist[index].isDone = false
            }
        }

        let status: RegistrationAutomationStatus = automationComplete ? .completed : .needsAttention
        state.lastAutomationResult = RegistrationAutomationResult(
            previousAccountID: previousAccount?.id,
            previousAccountEmail: previousAccountEmailForResult,
            accountID: account.id,
            accountEmail: account.email,
            username: account.typelessUsername ?? account.name,
            status: status,
            verificationCode: verificationCode,
            scriptPath: firstScriptURL?.path,
            verificationCodeFilePath: verificationCodeFileURL.path,
            browserResultFilePath: automationResultFileURL.path,
            browserProfileDirectoryPath: browserProfileURL.path,
            passwordStoredInKeychain: true,
            log: log
        )
        save()
        if automationComplete, !preserveCurrentAccount {
            // 同步官方会话并把桌面登录态缓存写回账号池，供下次无感换号静默注入。
            for attempt in 0..<SmartSwitchPolicy.sessionCaptureRetryAttempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: SmartSwitchPolicy.sessionCaptureRetryDelaySeconds * 1_000_000_000)
                }
                if let synced = await syncActiveAppSessionAndQuota(),
                   let syncedIndex = accountIndex(id: synced) {
                    let email = state.accounts[syncedIndex].email.lowercased()
                    if email == account.email.lowercased() {
                        liveAccountEmail = state.accounts[syncedIndex].email
                        liveRemainingCharacters = state.accounts[syncedIndex].remainingCharacters
                        lastKnownRemainingForInterval = liveRemainingCharacters
                        break
                    }
                    if state.accounts[syncedIndex].rawUserDataPayload != nil,
                       let accountIndex = accountIndex(id: account.id),
                       state.accounts[accountIndex].rawUserDataPayload == nil {
                        // 桌面已是新号但邮箱匹配慢时，仍把 payload 留在账号上。
                        break
                    }
                }
            }
        }
        if preserveCurrentAccount {
            statusMessage = automationComplete
                ? "热备账号已就绪：\(account.email)"
                : "热备注册未完成，等待下次补齐：\(account.email)"
            return automationComplete ? account.id : nil
        }
        statusMessage = automationComplete
            ? "全自动换号已完成，已同步 Google Chrome / Typeless 桌面端并复制新邮箱：\(account.email)"
            : "自动换号已推进到兜底确认阶段；旧账号未标记用完：\(account.email)"
        return automationComplete ? account.id : currentID
    }

    func runCommandLineAutomaticReplacementIfRequested() async -> Bool {
        let arguments = CommandLine.arguments
        guard let countIndex = arguments.firstIndex(of: "--auto-switch-count") else {
            return false
        }

        let requestedCount = arguments.indices.contains(countIndex + 1)
            ? (Int(arguments[countIndex + 1]) ?? 1)
            : 1
        let count = min(max(requestedCount, 1), 5)
        let domain = commandLineValue(for: "--auto-switch-domain", in: arguments)
            .ifEmpty(state.settings.domains.first ?? "8888891.xyz")
        let apiKey = KeychainStore.readAPIKey()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("TypelessSwitchboard CLI: MoeMail API Key missing in Keychain\n", stderr)
            return true
        }

        print("TypelessSwitchboard CLI: starting \(count) automatic replacement run(s), domain=\(domain)")
        for runIndex in 1...count {
            let fromID = lastCompletedAutomationAccountID()
            let startedAt = Date()
            let resultID = await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: 0,
                from: fromID
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            let result = state.lastAutomationResult
            print("TypelessSwitchboard CLI: run \(runIndex)/\(count) resultID=\(resultID?.uuidString ?? "nil") status=\(result?.status.rawValue ?? "none") account=\(result?.accountEmail ?? "") elapsed=\(String(format: "%.1f", elapsed))s")
            if result?.status != .completed {
                print("TypelessSwitchboard CLI: stopping because run \(runIndex) did not complete")
                break
            }
        }
        save()
        return true
    }

    private func commandLineValue(for flag: String, in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return ""
        }
        return arguments[index + 1]
    }

    func retryLastAutomation() async -> UUID? {
        guard !isRunningAutomaticReplacement else {
            statusMessage = "自动化正在运行中"
            return nil
        }
        guard let last = state.lastAutomationResult, last.canRetry else {
            statusMessage = "没有可重试的最近自动化结果"
            return nil
        }
        guard let accountID = last.accountID,
              let accountIndex = accountIndex(id: accountID) else {
            statusMessage = "最近自动化对应账号不存在"
            return nil
        }
        guard let scriptPath = last.scriptPath,
              FileManager.default.fileExists(atPath: scriptPath) else {
            statusMessage = "最近自动化脚本不存在，无法重试"
            return nil
        }

        let account = state.accounts[accountIndex]
        let password = KeychainStore.readAccountPassword(accountID: accountID)
        guard !password.isEmpty else {
            statusMessage = "Keychain 中没有这个账号的密码，无法重试"
            return nil
        }

        isRunningAutomaticReplacement = true
        defer { isRunningAutomaticReplacement = false }

        var log = last.log
        log.append("开始重试最近自动化")

        if let code = last.verificationCode,
           let codePath = last.verificationCodeFilePath,
           !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writeVerificationCode(code, to: URL(fileURLWithPath: codePath))
            log.append("已重新写入验证码桥接文件：\(codePath)")
        }

        if let resultPath = last.browserResultFilePath {
            try? FileManager.default.removeItem(atPath: resultPath)
        }

        statusMessage = "正在重试最近自动化：\(account.email)"
        let runResult = await runPlaywrightScript(URL(fileURLWithPath: scriptPath), password: password)
        log.append(runResult.message)

        let browserResult = last.browserResultFilePath
            .map { URL(fileURLWithPath: $0) }
            .flatMap(readAutomationResult)
        if let browserResult {
            log.append("重试浏览器结果：\(browserResult.summary)")
        } else {
            log.append("重试后仍未读取到浏览器结果")
        }

        let automationComplete = RegistrationAutomationCompletionPolicy.isComplete(
            verificationCode: last.verificationCode,
            browserResult: browserResult
        )
        if let refreshedIndex = self.accountIndex(id: accountID) {
            if automationComplete {
                state.accounts[refreshedIndex].reviewState = .approved
                state.accounts[refreshedIndex].reviewedAt = Date()
                state.accounts[refreshedIndex].status = .available
                state.accounts[refreshedIndex].usedCharacters = 0
                state.accounts[refreshedIndex].notes = "重试自动化后浏览器结果判定注册完成，可用于切换"
            } else {
                state.accounts[refreshedIndex].reviewState = .pending
                state.accounts[refreshedIndex].status = .paused
                state.accounts[refreshedIndex].notes = "重试自动化后仍未证明注册完成，等待兜底确认"
            }
        }

        let status: RegistrationAutomationStatus = automationComplete ? .completed : .needsAttention
        state.lastAutomationResult = RegistrationAutomationResult(
            previousAccountID: last.previousAccountID,
            previousAccountEmail: last.previousAccountEmail,
            accountID: accountID,
            accountEmail: account.email,
            username: account.typelessUsername ?? account.name,
            status: status,
            verificationCode: last.verificationCode,
            scriptPath: last.scriptPath,
            verificationCodeFilePath: last.verificationCodeFilePath,
            browserResultFilePath: last.browserResultFilePath,
            browserProfileDirectoryPath: last.browserProfileDirectoryPath,
            passwordStoredInKeychain: true,
            log: log
        )
        save()
        statusMessage = automationComplete
            ? "最近自动化重试完成：\(account.email)"
            : "最近自动化已重试，仍需要兜底确认：\(account.email)"
        return automationComplete ? accountID : nil
    }

    func loadMessages(for account: Account, apiKey: String) async {
        guard let emailID = account.moeMailEmailID, !emailID.isEmpty else {
            statusMessage = "这个账号还没有关联 MoeMail 邮箱 ID"
            return
        }
        guard let url = moeMailURL(path: "/api/emails/\(emailID)") else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        do {
            let data = try await moeMailRequest(url: url, apiKey: apiKey)
            moeMailMessages = parseMoeMailMessages(from: data)
            statusMessage = moeMailMessages.isEmpty ? "没有读取到邮件" : "已读取 \(moeMailMessages.count) 封邮件"
        } catch {
            statusMessage = "邮件列表读取失败：\(error.localizedDescription)"
        }
    }

    private func pollVerificationCode(for account: Account, apiKey: String, attempts: Int, delaySeconds: UInt64) async -> String? {
        let totalAttempts = max(attempts, 1)
        for attempt in 1...totalAttempts {
            await loadMessages(for: account, apiKey: apiKey)
            if let code = verificationCode(from: moeMailMessages) {
                return code
            }
            statusMessage = "正在等待验证码邮件（\(attempt)/\(totalAttempts)）..."
            guard attempt < totalAttempts else { continue }
            let scheduledDelay = RegistrationAutomationTiming.moeMailPollingDelaySeconds(afterAttempt: attempt) ?? delaySeconds
            try? await Task.sleep(nanoseconds: scheduledDelay * 1_000_000_000)
        }
        return nil
    }

    private func automationCommandVersion(command: String, versionArgument: String) async -> String {
        await Task.detached(priority: .utility) {
            let result = SwitchboardStore.runProcess(arguments: [command, versionArgument], environment: SwitchboardStore.automationEnvironment())
            guard result.status == 0 else { return "" }
            return result.output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }

    private func prepareAutomationRuntime() async -> (success: Bool, message: String) {
        let folder = automationDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.ensureAutomationPackageManifest(in: folder)
        } catch {
            return (false, "自动化目录准备失败：\(error.localizedDescription)")
        }

        return await Task.detached(priority: .utility) {
            let node = SwitchboardStore.runProcess(
                arguments: ["node", "--version"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard node.status == 0 else {
                return (false, "未检测到 node：\(node.output.ifEmpty("退出码 \(node.status)"))")
            }

            let npm = SwitchboardStore.runProcess(
                arguments: ["npm", "--version"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard npm.status == 0 else {
                return (false, "未检测到 npm：\(npm.output.ifEmpty("退出码 \(npm.status)"))")
            }

            let nodeVersion = node.output.components(separatedBy: .newlines).first ?? "node"
            let npmVersion = npm.output.components(separatedBy: .newlines).first ?? "npm"
            if SwitchboardStore.isAutomationRuntimeCached(in: folder) {
                return (true, "自动化运行环境已缓存，跳过 npm install / playwright install：\(nodeVersion)，npm \(npmVersion)")
            }

            let installPackage = SwitchboardStore.runProcess(
                arguments: ["npm", "install", "--silent", "--no-audit", "--no-fund", "playwright"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 90
            )
            guard installPackage.status == 0 else {
                return (false, "Playwright 包准备失败：\(installPackage.output.ifEmpty("退出码 \(installPackage.status)"))")
            }

            let installBrowser = SwitchboardStore.runProcess(
                arguments: ["npm", "exec", "--", "playwright", "install", "chromium"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 120
            )
            guard installBrowser.status == 0 else {
                return (false, "Playwright Chromium 准备失败：\(installBrowser.output.ifEmpty("退出码 \(installBrowser.status)"))")
            }

            SwitchboardStore.markAutomationRuntimeReady(in: folder)
            return (true, "自动化运行环境已准备：\(nodeVersion)，npm \(npmVersion)")
        }.value
    }

    private func verificationCode(from messages: [MoeMailMessage]) -> String? {
        for message in messages {
            let fields = [message.subject, message.sender, message.receivedAt, message.preview]
            if let code = VerificationCodeExtractor.extract(from: fields) {
                return code
            }
        }
        return nil
    }

    private func makeVerificationCodeBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-code-\(safeEmail)-\(account.id.uuidString).txt")
    }

    private func makeAutomationResultBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-result-\(safeEmail)-\(account.id.uuidString).json")
    }

    private func makeBrowserProfileDirectoryURL(account: Account) -> URL {
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return retainedTypelessBrowserProfileRootURL()
            .appendingPathComponent("\(safeEmail)-\(account.id.uuidString)", isDirectory: true)
    }

    private func retainedTypelessBrowserProfileRootURL() -> URL {
        automationDirectoryURL()
            .appendingPathComponent("BrowserProfiles", isDirectory: true)
    }

    private func automationDirectoryURL() -> URL {
        dataFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Automation", isDirectory: true)
    }

    private func writeVerificationCode(_ code: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "写入验证码桥接文件失败：\(error.localizedDescription)"
        }
    }

    private func writeRegistrationAutomationScript(
        account: Account,
        password: String,
        verificationCode: String?,
        verificationCodeFileURL: URL?,
        automationResultFileURL: URL?
    ) -> URL? {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeEmail = account.email
                .replacingOccurrences(of: "@", with: "_at_")
                .replacingOccurrences(of: ".", with: "_")
            let scriptURL = folder.appendingPathComponent("typeless-register-\(safeEmail)-\(Date().timeIntervalSince1970).js")
            let input = BrowserRegistrationAutomationInput(
                registrationURL: account.typelessURL,
                email: account.email,
                username: account.typelessUsername ?? account.name,
                password: password,
                verificationCode: verificationCode,
                verificationCodeFilePath: verificationCodeFileURL?.path,
                automationResultFilePath: automationResultFileURL?.path,
                browserProfileDirectoryPath: makeBrowserProfileDirectoryURL(account: account).path,
                clearBrowserProfileBeforeRun: true,
                passwordEnvironmentVariable: typelessAutomationPasswordEnvironmentKey,
                headless: true
            )
            try BrowserAutomationScriptBuilder
                .makeRegistrationScript(input: input)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            return scriptURL
        } catch {
            statusMessage = "写入自动化脚本失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func readAutomationResult(from url: URL) -> BrowserAutomationResultPayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserAutomationResultPayload.self, from: data)
    }

    private func prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement() -> [String] {
        var log: [String] = []
        log.append(terminateInstalledTypelessApp())

        let backupRoot = automationDirectoryURL()
            .appendingPathComponent("DesktopSessionBackups", isDirectory: true)
            .appendingPathComponent(Self.safeTimestamp(), isDirectory: true)

        log.append(contentsOf: resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: backupRoot))

        for source in typelessDesktopSessionDataDirectories() {
            guard FileManager.default.fileExists(atPath: source.path) else {
                log.append("桌面登录态目录不存在，跳过：\(source.path)")
                continue
            }

            do {
                try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                let destination = backupRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                log.append("已隔离旧桌面登录态：\(source.path) → \(destination.path)")
            } catch {
                log.append("隔离旧桌面登录态失败：\(source.path)：\(error.localizedDescription)")
            }
        }

        return log
    }

    private func resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: URL) -> [String] {
        var log: [String] = []

        log.append(contentsOf: deleteTypelessDeviceCredentialsFromKeychain())

        for cacheDirectory in typelessDeviceCacheDirectories() {
            let deviceCache = cacheDirectory.appendingPathComponent("device.cache")
            if FileManager.default.fileExists(atPath: deviceCache.path) {
                do {
                    try FileManager.default.removeItem(at: deviceCache)
                    log.append("已删除 Typeless 设备缓存 device.cache：\(deviceCache.path)")
                } catch {
                    log.append("删除 Typeless 设备缓存失败：\(deviceCache.path)：\(error.localizedDescription)")
                }
            }
        }

        for dataDirectory in typelessDesktopSessionDataDirectories() {
            let userData = dataDirectory.appendingPathComponent("user-data.json")
            if FileManager.default.fileExists(atPath: userData.path) {
                do {
                    try FileManager.default.removeItem(at: userData)
                    log.append("已删除 Typeless 加密登录凭证 user-data.json：\(userData.path)")
                } catch {
                    log.append("删除 Typeless 加密登录凭证失败：\(userData.path)：\(error.localizedDescription)")
                }
            }

            let storage = dataDirectory.appendingPathComponent("app-storage.json")
            if FileManager.default.fileExists(atPath: storage.path) {
                do {
                    try clearTypelessAppStorageForDeviceReset(storage)
                    log.append("已清理 Typeless app-storage.json 的 userData / quotaUsage：\(storage.path)")
                } catch {
                    log.append("清理 Typeless app-storage.json 失败：\(storage.path)：\(error.localizedDescription)")
                }
            }

            for subdirectory in ["Local Storage", "Network", "Cookies", "Session Storage"] {
                let url = dataDirectory.appendingPathComponent(subdirectory, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        log.append("已清理 Typeless Electron 残留目录 \(subdirectory)：\(url.path)")
                    } catch {
                        log.append("清理 Typeless Electron 残留目录失败 \(subdirectory)：\(error.localizedDescription)")
                    }
                }
            }
        }

        if log.isEmpty {
            log.append("未发现 Typeless 设备身份残留；继续隔离桌面登录态")
        } else {
            log.append("已按 typeless-toolkit resetDevice 逻辑重置本机 Typeless 设备身份")
        }
        _ = backupRoot
        return log
    }

    private func deleteTypelessDeviceCredentialsFromKeychain() -> [String] {
        var log: [String] = []
        let candidates: [(service: String, account: String?)] = [
            (typelessCredentialTarget, typelessCredentialAccount),
            (typelessLegacyCredentialTarget, nil)
        ]

        for candidate in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service
            ]
            if let account = candidate.account {
                query[kSecAttrAccount as String] = account
            }
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                if let account = candidate.account {
                    log.append("已删除 Typeless 设备 Keychain 凭据：service=\(candidate.service), account=\(account)")
                } else {
                    log.append("已删除 Typeless 旧设备 Keychain 凭据：service=\(candidate.service)")
                }
            } else if status != errSecItemNotFound {
                if deleteTypelessDeviceCredentialWithSecurityCLI(service: candidate.service, account: candidate.account) {
                    log.append("已通过 security delete-generic-password 删除 Typeless 设备 Keychain 凭据：service=\(candidate.service)")
                } else {
                    log.append("删除 Typeless 设备 Keychain 凭据失败：service=\(candidate.service)，状态 \(status)")
                }
            }

            let labelQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrLabel as String: candidate.service
            ]
            let labelStatus = SecItemDelete(labelQuery as CFDictionary)
            if labelStatus == errSecSuccess {
                log.append("已删除 Typeless 设备 Keychain 标签凭据：label=\(candidate.service)")
            } else if labelStatus != errSecItemNotFound {
                if deleteTypelessDeviceCredentialWithSecurityCLI(label: candidate.service) {
                    log.append("已通过 security delete-generic-password 删除 Typeless 设备 Keychain 标签凭据：label=\(candidate.service)")
                } else {
                    log.append("删除 Typeless 设备 Keychain 标签凭据失败：label=\(candidate.service)，状态 \(labelStatus)")
                }
            }
        }

        if log.isEmpty {
            log.append("未发现 Typeless 设备 Keychain 凭据")
        }
        return log
    }

    private func deleteTypelessDeviceCredentialWithSecurityCLI(service: String, account: String?) -> Bool {
        var arguments = ["security", "delete-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        let result = SwitchboardStore.runProcess(
            arguments: arguments,
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }

    private func deleteTypelessDeviceCredentialWithSecurityCLI(label: String) -> Bool {
        let result = SwitchboardStore.runProcess(
            arguments: ["security", "delete-generic-password", "-l", label],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }

    private func clearTypelessAppStorageForDeviceReset(_ storageURL: URL) throws {
        guard let data = try? Data(contentsOf: storageURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        object["userData"] = [:]
        object.removeValue(forKey: "quotaUsage")
        if object.keys.contains("session") {
            object["session"] = NSNull()
        }
        if object.keys.contains("currentRoute") {
            object["currentRoute"] = NSNull()
        }

        let patchedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patchedData.write(to: storageURL, options: .atomic)
    }

    private func prepareRetainedTypelessBrowserSessionsForAutomaticReplacement() -> [String] {
        var log: [String] = []
        log.append(terminateRetainedTypelessBrowserSessions())

        let source = retainedTypelessBrowserProfileRootURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            log.append("旧网页登录态目录不存在，跳过：\(source.path)")
            return log
        }

        let backupRoot = automationDirectoryURL()
            .appendingPathComponent("BrowserSessionBackups", isDirectory: true)
            .appendingPathComponent(Self.safeTimestamp(), isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            let destination = backupRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            log.append("已隔离旧网页登录态：\(source.path) → \(destination.path)")
        } catch {
            log.append("隔离旧网页登录态失败：\(source.path)：\(error.localizedDescription)")
        }

        return log
    }

    private func resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement() -> [String] {
        let result = approveChromeTypelessAppPrompt()
        let output = result.output.ifEmpty("退出码 \(result.status)")
        if result.status == 0,
           output.localizedCaseInsensitiveContains("approved") {
            return ["已先处理 Google Chrome 遗留的 Typeless.app 弹窗，并尝试勾选“始终允许 www.typeless.com”"]
        }
        if result.status == 0,
           output.localizedCaseInsensitiveContains("not found") {
            return ["未发现 Google Chrome 遗留的 Typeless.app 弹窗，继续清理环境"]
        }
        return ["处理 Google Chrome 遗留 Typeless.app 弹窗未完成：\(output)；继续清理环境"]
    }

    private func closePersonalChromeTypelessTabsBeforeReplacement() -> [String] {
        let script = """
        tell application "Google Chrome"
          set closedCount to 0
          if (count of windows) = 0 then return "closed 0 typeless tabs"
          repeat with chromeWindow in windows
            set tabCount to count of tabs of chromeWindow
            repeat with tabIndex from tabCount to 1 by -1
              try
                set chromeTab to tab tabIndex of chromeWindow
                if (URL of chromeTab contains "typeless.com") then
                  close chromeTab
                  set closedCount to closedCount + 1
                end if
              end try
            end repeat
          end repeat
          return "closed " & closedCount & " typeless tabs"
        end tell
        """
        let result = runInlineAppleScript(
            script,
            label: "close-personal-chrome-typeless-tabs",
            timeoutSeconds: 10
        )
        if result.status == 0 {
            return ["已关闭 Google Chrome 里的旧 Typeless 标签：\(result.output.ifEmpty("closed 0 typeless tabs"))"]
        }
        return ["关闭 Google Chrome 旧 Typeless 标签失败：\(result.output.ifEmpty("退出码 \(result.status)"))"]
    }

    private func preparePersonalChromeTypelessWebSessionForAutomaticReplacement() -> [String] {
        let clearScript = """
        (async () => {
          try { localStorage.clear(); } catch (error) {}
          try { sessionStorage.clear(); } catch (error) {}
          try {
            document.cookie.split(';').forEach(cookie => {
              const name = cookie.split('=')[0].trim();
              if (!name) return;
              const domains = ['', 'www.typeless.com', '.typeless.com'];
              const paths = ['/', '/login', '/login/app/success'];
              for (const domain of domains) {
                for (const path of paths) {
                  document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; path=' + path + (domain ? '; domain=' + domain : '');
                }
              }
            });
          } catch (error) {}
          try {
            if (window.indexedDB && indexedDB.databases) {
              const databases = await indexedDB.databases();
              for (const database of databases) {
                if (database.name) indexedDB.deleteDatabase(database.name);
              }
            }
          } catch (error) {}
          try {
            if (window.caches) {
              const keys = await caches.keys();
              for (const key of keys) await caches.delete(key);
            }
          } catch (error) {}
          location.href = 'https://www.typeless.com/login';
          'cleared typeless chrome session';
        })();
        """

        let result = runJavaScriptInPersonalChrome(
            clearScript,
            label: "clear-personal-chrome-typeless-session",
            targetURL: typelessDefaultLoginURL,
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        return result.status == 0
            ? ["已清理 Google Chrome 里的 Typeless 网页旧账号会话"]
            : ["清理 Google Chrome 里的 Typeless 网页旧账号会话失败：\(result.output.ifEmpty("退出码 \(result.status)"))"]
    }

    private func syncPersonalChromeTypelessWebSession(account: Account, profileDirectoryPath: String) -> [String] {
        guard let tokenInfo = extractTypelessTokenInfo(fromBrowserProfile: profileDirectoryPath, expectedEmail: account.email) else {
            return ["未能从新账号浏览器 profile 提取 Typeless 登录态，跳过同步 Google Chrome"]
        }

        let syncScript = """
        try { localStorage.clear(); } catch (error) {}
        try { sessionStorage.clear(); } catch (error) {}
        localStorage.setItem('MAXAI_CLIENT__FEATURES__AUTH__TOKEN_INFO', \(Self.javaScriptStringLiteral(tokenInfo)));
        location.href = 'https://www.typeless.com/login/app/success';
        'synced typeless chrome session';
        """

        let syncResult = runJavaScriptInPersonalChrome(
            syncScript,
            label: "sync-personal-chrome-typeless-session",
            targetURL: "https://www.typeless.com/login",
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        guard syncResult.status == 0 else {
            return ["同步新账号到 Google Chrome 失败：\(syncResult.output.ifEmpty("退出码 \(syncResult.status)"))"]
        }

        let openDesktopScript = """
        const button = Array.from(document.querySelectorAll('button, [role="button"]')).find(element => {
          const text = (element.innerText || '').toLowerCase();
          return text.includes('open the desktop app') || text.includes('打开桌面应用');
        });
        if (button) {
          button.click();
          'clicked desktop handoff';
        } else {
          'desktop handoff button not found';
        }
        """
        _ = runJavaScriptInPersonalChrome(
            openDesktopScript,
            label: "open-typeless-desktop-from-personal-chrome",
            targetURL: "https://www.typeless.com/login/app/success",
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        _ = approveChromeTypelessAppPrompt()

        return ["已把 Google Chrome 的 Typeless 网页会话切到新账号：\(account.email)"]
    }

    private func handoffRetainedTypelessProfileToDesktopOnce(profileDirectoryPath: String, expectedEmail: String) -> String {
        if let tokenInfo = extractTypelessTokenInfo(fromBrowserProfile: profileDirectoryPath, expectedEmail: expectedEmail),
           let authURL = makeTypelessDesktopAuthURL(fromTokenInfo: tokenInfo) {
            forceLaunchTypelessBeforeAuthProtocol()
            let firstOpen = openTypelessAuthProtocol(authURL)
            Thread.sleep(forTimeInterval: 2.0)
            let secondOpen = openTypelessAuthProtocol(authURL)
            if firstOpen || secondOpen {
                return "已用完整 access_token / refresh_token / user_id 后台触发 Typeless 桌面端登录协议"
            }
        }

        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scriptURL = folder.appendingPathComponent("typeless-desktop-handoff-\(Date().timeIntervalSince1970).js")
            try makeDesktopHandoffScript(profileDirectoryPath: profileDirectoryPath)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            let result = SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 45
            )
            if result.status == 0 {
                return "已后台触发新账号 Typeless 桌面端 handoff：\(result.output.ifEmpty("无输出"))"
            }
            return "后台触发 Typeless 桌面端 handoff 未完成：\(result.output.ifEmpty("退出码 \(result.status)"))"
        } catch {
            return "后台触发 Typeless 桌面端 handoff 失败：\(error.localizedDescription)"
        }
    }

    private func forceLaunchTypelessBeforeAuthProtocol() {
        if let path = typelessAppPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            Thread.sleep(forTimeInterval: 6.0)
        }
    }

    private func openTypelessAuthProtocol(_ authURL: String) -> Bool {
        let result = SwitchboardStore.runProcess(
            arguments: ["open", authURL],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 15
        )
        return result.status == 0
    }

    private func makeTypelessDesktopAuthURL(fromTokenInfo tokenInfo: String) -> String? {
        guard let data = tokenInfo.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["accessToken"] as? String,
              let refreshToken = object["refreshToken"] as? String,
              let userID = object["userId"] as? String,
              let email = object["email"] as? String else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "typeless"
        components.host = "auth"
        components.path = "/google/success"
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "client_user_id", value: "")
        ]
        return components.url?.absoluteString
    }

    private func makeDesktopHandoffScript(profileDirectoryPath: String) -> String {
        let profile = Self.javaScriptStringLiteral(profileDirectoryPath)
        return """
        const { chromium } = require('playwright');
        const { execFileSync } = require('child_process');

        const browserProfileDirectoryPath = \(profile);
        const targetURL = 'https://www.typeless.com/login/app/success';
        let openedProtocolURL = '';

        function openExternalTypelessProtocolURL(url) {
          if (!url || !url.startsWith('typeless://')) return false;
          if (openedProtocolURL) return true;
          openedProtocolURL = url;
          execFileSync('/usr/bin/open', [url], { stdio: 'ignore' });
          return true;
        }

        async function clickDesktopHandoff(page) {
          const selectors = [
            'button:has-text("Open the desktop app")',
            '[role="button"]:has-text("Open the desktop app")',
            'button:has-text("打开桌面应用")',
            '[role="button"]:has-text("打开桌面应用")'
          ];
          for (const selector of selectors) {
            const locator = page.locator(selector).first();
            try {
              if (await locator.isVisible({ timeout: 2500 })) {
                await locator.click({ timeout: 2500 });
                return selector;
              }
            } catch (error) {}
          }
          const directProtocolURL = await page.evaluate(() => {
            const urls = [];
            document.querySelectorAll('a[href], button, [role="button"]').forEach(element => {
              const href = element.getAttribute && element.getAttribute('href');
              if (href) urls.push(href);
              const dataset = element.dataset || {};
              Object.values(dataset).forEach(value => { if (typeof value === 'string') urls.push(value); });
              const onclick = element.getAttribute && element.getAttribute('onclick');
              if (onclick) urls.push(onclick);
            });
            const match = urls.join('\\n').match(/typeless:\\/\\/[^\\s"'<>]+/i);
            return match ? match[0] : '';
          }).catch(() => '');
          if (directProtocolURL) {
            openExternalTypelessProtocolURL(directProtocolURL);
            return 'direct typeless:// URL';
          }
          return '';
        }

        (async () => {
          const context = await chromium.launchPersistentContext(browserProfileDirectoryPath, { headless: true });
          const page = context.pages()[0] || await context.newPage();
          page.on('request', request => {
            try { openExternalTypelessProtocolURL(request.url()); } catch (error) {}
          });
          await page.goto(targetURL, { waitUntil: 'domcontentloaded', timeout: 20000 }).catch(() => {});
          await page.waitForLoadState('domcontentloaded', { timeout: 10000 }).catch(() => {});
          await page.waitForTimeout(1200);
          const clicked = await clickDesktopHandoff(page);
          await page.waitForTimeout(3500);
          await context.close();
          if (openedProtocolURL) {
            console.log('opened typeless:// desktop handoff via ' + (clicked || 'request') + ': ' + openedProtocolURL.slice(0, 120));
          } else {
            console.log('desktop handoff button/protocol not found at ' + page.url() + ' title=' + await page.title().catch(() => ''));
          }
        })().catch(error => {
          console.error(error.stack || error.message || String(error));
          process.exit(1);
        });
        """
    }

    private func completeTypelessDesktopOnboardingIfPresent(expectedEmail: String, timeoutSeconds: TimeInterval = 60) -> [String] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let typelessFolder = appSupport.appendingPathComponent("Typeless", isDirectory: true)
        let storageURL = typelessFolder.appendingPathComponent("app-storage.json")
        let onboardingURL = typelessFolder.appendingPathComponent("app-onboarding.json")

        let readiness = waitForTypelessDesktopStorage(
            storageURL: storageURL,
            onboardingURL: onboardingURL,
            expectedEmail: expectedEmail,
            timeoutSeconds: timeoutSeconds
        )
        if let email = readiness.email {
            guard email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                return ["桌面 App 当前账号不是新邮箱（检测到 \(email)），暂不改新手引导"]
            }
        } else {
            return ["尚未检测到桌面 App 新账号登录态，暂不改新手引导"]
        }

        do {
            logOutAndStopTypelessForOnboardingPatch()
            try writeTypelessOnboardingCompletion(to: onboardingURL)
            try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
            if let path = typelessAppPath() {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                enforceTypelessDesktopOnboardingPatchAfterRelaunch(
                    storageURL: storageURL,
                    onboardingURL: onboardingURL,
                    expectedEmail: expectedEmail
                )
            }
            return ["已跳过/完成 Typeless 桌面端新手引导"]
        } catch {
            return ["跳过 Typeless 新手引导失败：\(error.localizedDescription)"]
        }
    }

    private func writeTypelessOnboardingCompletion(to onboardingURL: URL) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: onboardingURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["isCompleted"] = true
        object["step"] = 99
        object["setUpStep"] = 99
        object["tryItStep"] = 99
        object["tryItPlaygroundStep"] = 99
        object["onboardingStep"] = NSNull()
        object["onboardingMaxReachedStep"] = NSNull()
        object["onboardingAutoLanguageDetection"] = true
        object["onboardingCompletedFloatingBarStart"] = true
        object["onboardingCompletedFloatingBarRelease"] = true
        object["onboardingHomePageClickAppToShowFloatingBar"] = []
        object["onboardingTryItPlaygroundIsCompleted"] = true
        object["onboardingMaxTryItPlaygroundStepValue"] = 99
        object["onboardingShortcutCalloutDismissedStep"] = 99
        object["pressToStopDictationOnboardingShown"] = [
            "voice_transcript_release": true,
            "voice_transcript": true,
            "voice_command": true,
            "voice_translation": true
        ]
        object["translationModeFeatureAlertOnboarding"] = [
            "dictationCount": 99,
            "shown": true
        ]
        if var translation = object["translationModeFeatureOnboarding"] as? [String: Any] {
            if var settingDot = translation["settingDot"] as? [String: Any] {
                settingDot["dismissed"] = true
                translation["settingDot"] = settingDot
            }
            if var newTags = translation["newTags"] as? [String: Any] {
                newTags["dismissed"] = true
                translation["newTags"] = newTags
            }
            object["translationModeFeatureOnboarding"] = translation
        }
        if var appDownload = object["appDownloadButtonOnboarding"] as? [String: Any] {
            appDownload["dismissed"] = true
            object["appDownloadButtonOnboarding"] = appDownload
        }
        if var shortcut = object["shortcutChangeFeatureOnboarding"] as? [String: Any] {
            if var settingDot = shortcut["settingDot"] as? [String: Any] {
                settingDot["dismissed"] = true
                shortcut["settingDot"] = settingDot
            }
            if var newTags = shortcut["newTags"] as? [String: Any] {
                newTags["dismissed"] = true
                shortcut["newTags"] = newTags
            }
            object["shortcutChangeFeatureOnboarding"] = shortcut
        }
        object["__ONBOARDING_UPGRADE_NOTICE"] = true

        try FileManager.default.createDirectory(at: onboardingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: onboardingURL, options: .atomic)
    }

    private func writeTypelessStorageOnboardingCompletion(to storageURL: URL, expectedEmail: String) throws {
        guard let data = try? Data(contentsOf: storageURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var userData = object["userData"] as? [String: Any] else {
            throw NSError(
                domain: "TypelessOnboardingPatch",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 Typeless 桌面端 app-storage.json 里的 userData"]
            )
        }

        guard let email = userData["email"] as? String,
              email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            let actualEmail = (userData["email"] as? String) ?? "未知"
            throw NSError(
                domain: "TypelessOnboardingPatch",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "app-storage.json 账号不匹配：\(actualEmail)"]
            )
        }

        userData["is_new_user"] = false

        var onboarding = userData["onboarding"] as? [String: Any] ?? [:]
        for platform in ["ios", "android", "macos", "windows"] {
            var platformState = onboarding[platform] as? [String: Any] ?? [:]
            platformState["completed"] = true
            onboarding[platform] = platformState
        }
        userData["onboarding"] = onboarding

        object["userData"] = userData
        if object.keys.contains("currentRoute") {
            object["currentRoute"] = NSNull()
        }

        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let patchedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patchedData.write(to: storageURL, options: .atomic)
    }

    private func enforceTypelessDesktopOnboardingPatchAfterRelaunch(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String
    ) {
        for delay in [1.0, 3.0, 6.0, 12.0, 24.0, 60.0] {
            Thread.sleep(forTimeInterval: delay)
            guard let email = readTypelessDesktopEmail(from: storageURL),
                  email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                continue
            }
            try? writeTypelessOnboardingCompletion(to: onboardingURL)
            try? writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
        }
    }

    private func waitForTypelessDesktopStorage(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String,
        timeoutSeconds: TimeInterval
    ) -> (email: String?, onboardingExists: Bool) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastEmail: String?
        var onboardingExists = FileManager.default.fileExists(atPath: onboardingURL.path)

        repeat {
            if let email = readTypelessDesktopEmail(from: storageURL) {
                lastEmail = email
                onboardingExists = FileManager.default.fileExists(atPath: onboardingURL.path)
                if email.caseInsensitiveCompare(expectedEmail) == .orderedSame {
                    return (email, onboardingExists)
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return (lastEmail, onboardingExists)
    }

    private func readTypelessDesktopEmail(from storageURL: URL) -> String? {
        guard let data = try? Data(contentsOf: storageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = object["userData"] as? [String: Any],
              let email = userData["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return email
    }

    private func logOutAndStopTypelessForOnboardingPatch() {
        _ = terminateInstalledTypelessApp()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func terminateInstalledTypelessApp() -> String {
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier == "now.typeless.desktop" ||
                app.localizedName == "Typeless" ||
                app.bundleURL?.path == typelessAppPath()
        }

        guard !running.isEmpty else {
            return "本机 Typeless App 未运行，无需退出"
        }

        for app in running {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(typelessAppQuitGraceSeconds)
        while Date() < deadline {
            let stillRunning = NSWorkspace.shared.runningApplications.contains { app in
                app.bundleIdentifier == "now.typeless.desktop" ||
                    app.localizedName == "Typeless" ||
                    app.bundleURL?.path == typelessAppPath()
            }
            if !stillRunning {
                return "已正常退出本机 Typeless App"
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }

        let forced = SwitchboardStore.runProcess(
            arguments: ["pkill", "-f", "Typeless.app/Contents"],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 5
        )
        return forced.status == 0
            ? "已强制退出残留 Typeless App 进程"
            : "已请求退出 Typeless App；未发现可强制结束的残留进程"
    }

    private func terminateRetainedTypelessBrowserSessions() -> String {
        guard FileManager.default.fileExists(atPath: retainedTypelessBrowserProfileRootURL().path) else {
            return "旧网页登录态 profile 根目录不存在，无需关闭浏览器窗口"
        }

        let running = SwitchboardStore.runProcess(
            arguments: ["pgrep", "-f", retainedTypelessBrowserProfileRootURL().path],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 5
        )
        guard running.status == 0 else {
            return "未发现旧网页登录浏览器窗口"
        }

        let forced = SwitchboardStore.runProcess(
            arguments: ["pkill", "-f", retainedTypelessBrowserProfileRootURL().path],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 5
        )
        return forced.status == 0
            ? "已关闭旧网页登录浏览器窗口"
            : "尝试关闭旧网页登录浏览器窗口失败：\(forced.output.ifEmpty("退出码 \(forced.status)"))"
    }

    private func typelessDesktopSessionDataDirectories() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates = [
            appSupport.appendingPathComponent("Typeless", isDirectory: true),
            appSupport.appendingPathComponent("Typeless.exe", isDirectory: true),
            appSupport.appendingPathComponent("now.typeless.desktop", isDirectory: true)
        ]
        return candidates.reduce(into: [URL]()) { result, url in
            if !result.contains(where: { $0.path == url.path }) {
                result.append(url)
            }
        }
    }

    private nonisolated static func safeTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func runInlineAppleScript(
        _ appleScript: String,
        label: String,
        timeoutSeconds: TimeInterval
    ) -> (status: Int32, output: String) {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).applescript")
            try appleScript.write(to: url, atomically: true, encoding: .utf8)
            return SwitchboardStore.runProcess(
                arguments: ["osascript", url.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func runJavaScriptInPersonalChrome(
        _ javaScript: String,
        label: String,
        targetURL: String,
        delayBeforeJavaScriptSeconds: Int,
        timeoutSeconds: TimeInterval
    ) -> (status: Int32, output: String) {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let javaScriptURL = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).js")
            let appleScriptURL = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).applescript")
            try javaScript.write(to: javaScriptURL, atomically: true, encoding: .utf8)

            let appleScript = """
            tell application "Google Chrome"
              activate
              if (count of windows) = 0 then
                make new window
              end if
              set targetTab to missing value
              repeat with chromeWindow in windows
                repeat with chromeTab in tabs of chromeWindow
                  try
                    if (URL of chromeTab contains "typeless.com") then
                      set targetTab to chromeTab
                      exit repeat
                    end if
                  end try
                end repeat
                if targetTab is not missing value then exit repeat
              end repeat
              if targetTab is missing value then
                set targetTab to make new tab at end of tabs of window 1 with properties {URL:\(Self.appleScriptStringLiteral(targetURL))}
              else
                set URL of targetTab to \(Self.appleScriptStringLiteral(targetURL))
              end if
              delay \(delayBeforeJavaScriptSeconds)
              set javaScriptSource to read POSIX file \(Self.appleScriptStringLiteral(javaScriptURL.path))
              execute targetTab javascript javaScriptSource
            end tell
            """
            try appleScript.write(to: appleScriptURL, atomically: true, encoding: .utf8)
            return SwitchboardStore.runProcess(
                arguments: ["osascript", appleScriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func approveChromeTypelessAppPrompt() -> (status: Int32, output: String) {
        let script = """
        -- Handles Chrome external-protocol prompt:
        -- AXCheckBox / “始终允许 www.typeless.com ...” / “Always allow ...”
        on clickFirstCheckbox(containerElement)
          tell application "System Events"
            try
              if (count of checkboxes of containerElement) > 0 then
                set targetCheckbox to checkbox 1 of containerElement
                try
                  if (value of targetCheckbox as integer) is 0 then click targetCheckbox
                on error
                  click targetCheckbox
                end try
                return true
              end if
            end try
            try
              repeat with childGroup in groups of containerElement
                if my clickFirstCheckbox(childGroup) then return true
              end repeat
            end try
          end tell
          return false
        end clickFirstCheckbox

        on clickNamedOpenButton(containerElement)
          tell application "System Events"
            set buttonNames to {"打开Typeless.app", "打开 Typeless.app", "Open Typeless.app", "打开桌面应用", "Open the desktop app"}
            repeat with buttonName in buttonNames
              try
                click button (buttonName as text) of containerElement
                return true
              end try
            end repeat
            try
              repeat with childButton in buttons of containerElement
                set buttonText to ""
                try
                  set buttonText to (name of childButton as text)
                end try
                if buttonText contains "Typeless.app" or buttonText contains "打开" or buttonText contains "Open" then
                  click childButton
                  return true
                end if
              end repeat
            end try
            try
              repeat with childGroup in groups of containerElement
                if my clickNamedOpenButton(childGroup) then return true
              end repeat
            end try
          end tell
          return false
        end clickNamedOpenButton

        on chromeHasTypelessSuccessTab()
          tell application "Google Chrome"
            try
              repeat with chromeWindow in windows
                repeat with chromeTab in tabs of chromeWindow
                  try
                    if (URL of chromeTab contains "typeless.com/login/app/success") then
                      set active tab index of chromeWindow to (index of chromeTab)
                      set index of chromeWindow to 1
                      return true
                    end if
                  end try
                end repeat
              end repeat
            end try
          end tell
          return false
        end chromeHasTypelessSuccessTab

        on chromeSuccessPageShowsDesktopButton()
          tell application "Google Chrome"
            try
              if (count of windows) = 0 then return false
              if (URL of active tab of front window contains "typeless.com/login/app/success") then
                set pageText to execute active tab of front window javascript "document.body.innerText || ''"
                if pageText contains "打开桌面应用" or pageText contains "Open the desktop app" then
                  return true
                end if
              end if
            end try
          end tell
          return false
        end chromeSuccessPageShowsDesktopButton

        on clickDesktopButtonInPage()
          tell application "Google Chrome"
            try
              if (count of windows) = 0 then return false
              if (URL of active tab of front window contains "typeless.com/login/app/success") then
                execute active tab of front window javascript "Array.from(document.querySelectorAll('button,[role=button]')).find(e => /打开桌面应用|Open the desktop app/i.test(e.innerText||''))?.click();"
                return true
              end if
            end try
          end tell
          return false
        end clickDesktopButtonInPage

        tell application "Google Chrome"
          activate
        end tell
        delay 0.2

        set hadSuccessTab to chromeHasTypelessSuccessTab()
        set pageHadDesktopButton to chromeSuccessPageShowsDesktopButton()
        if pageHadDesktopButton then
          clickDesktopButtonInPage()
          delay 0.5
        end if
        set maxAttempts to 2
        if pageHadDesktopButton then set maxAttempts to 4

        tell application "System Events"
          if exists process "Google Chrome" then
            tell process "Google Chrome"
              repeat with attempt from 1 to maxAttempts
                repeat with chromeWindow in windows
                  set checkboxClicked to my clickFirstCheckbox(chromeWindow)
                  if my clickNamedOpenButton(chromeWindow) then
                    if checkboxClicked then
                      return "approved chrome typeless prompt with always allow"
                    end if
                    return "approved chrome typeless prompt"
                  end if
                end repeat
                if attempt is 1 and hadSuccessTab and pageHadDesktopButton then
                  -- Give Chrome a short moment to render the external-protocol modal.
                  delay 0.5
                else
                  delay 0.2
                end if
              end repeat
              if hadSuccessTab and pageHadDesktopButton then
                -- Conservative keyboard fallback only after a known Typeless success page click.
                try
                  key code 48 using {shift down}
                  key code 48 using {shift down}
                  key code 49
                  key code 48
                  key code 48
                  key code 49
                  return "approved chrome typeless prompt by keyboard fallback"
                end try
              end if
            end tell
          end if
        end tell
        return "chrome typeless prompt not found"
        """

        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("approve-chrome-typeless-prompt-\(Date().timeIntervalSince1970).applescript")
            try script.write(to: url, atomically: true, encoding: .utf8)
            return SwitchboardStore.runProcess(
                arguments: ["osascript", url.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 10
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func extractTypelessTokenInfo(fromBrowserProfile profileDirectoryPath: String, expectedEmail: String) -> String? {
        let levelDBURL = URL(fileURLWithPath: profileDirectoryPath)
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: levelDBURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        let escapedEmail = NSRegularExpression.escapedPattern(for: expectedEmail)
        let pattern = #"\{"accessToken":"[^"]+","refreshToken":"[^"]+","userId":"[^"]+","email":""# + escapedEmail + #""\}"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for case let fileURL as URL in enumerator {
            guard !fileURL.hasDirectoryPath,
                  let data = try? Data(contentsOf: fileURL),
                  let contents = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8),
                  let regex else { continue }
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            guard let match = regex.firstMatch(in: contents, range: range),
                  let swiftRange = Range(match.range, in: contents) else { continue }
            let tokenInfo = String(contents[swiftRange])
            if tokenInfo.contains("MAXAI_CLIENT__FEATURES__AUTH__TOKEN_INFO") {
                return tokenInfo
            }
            return tokenInfo
        }
        return nil
    }

    private nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    private nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    func openLastAutomationBrowserSession() {
        guard let result = state.lastAutomationResult,
              let profilePath = result.browserProfileDirectoryPath,
              result.canOpenBrowserSession else {
            statusMessage = "最近自动化没有可打开的浏览器登录态目录"
            return
        }
        let targetURL = accountForLastAutomationResult()?.typelessURL ?? state.settings.typelessLoginURL
        statusMessage = openRetainedBrowserSession(profileDirectoryPath: profilePath, targetURL: targetURL)
    }

    private func accountForLastAutomationResult() -> Account? {
        guard let accountID = state.lastAutomationResult?.accountID,
              let index = accountIndex(id: accountID) else {
            return nil
        }
        return state.accounts[index]
    }

    private func openRetainedBrowserSession(profileDirectoryPath: String, targetURL: String) -> String {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: profileDirectoryPath),
                withIntermediateDirectories: true
            )

            let scriptURL = folder.appendingPathComponent("typeless-open-retained-session-\(Date().timeIntervalSince1970).js")
            let script = BrowserAutomationScriptBuilder.makeOpenSessionScript(input: BrowserSessionAutomationInput(
                targetURL: targetURL,
                browserProfileDirectoryPath: profileDirectoryPath,
                headless: false
            ))
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let syntaxCheck = SwitchboardStore.runProcess(
                arguments: ["node", "--check", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard syntaxCheck.status == 0 else {
                return "新账号浏览器会话脚本语法检查失败：\(syntaxCheck.output.ifEmpty("退出码 \(syntaxCheck.status)"))"
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", scriptURL.path]
            process.environment = SwitchboardStore.automationEnvironment()
            process.currentDirectoryURL = folder
            try process.run()
            return "已打开新账号浏览器会话：\(targetURL)"
        } catch {
            return "打开新账号浏览器会话失败：\(error.localizedDescription)"
        }
    }

    private func runPlaywrightScript(_ scriptURL: URL, password: String) async -> (success: Bool, message: String) {
        await Task.detached(priority: .utility) {
            let syntaxCheck = SwitchboardStore.runProcess(
                arguments: ["node", "--check", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment()
            )
            guard syntaxCheck.status == 0 else {
                return (false, "Playwright 脚本语法检查失败：\(syntaxCheck.output.ifEmpty("退出码 \(syntaxCheck.status)"))")
            }

            let scriptFolder = scriptURL.deletingLastPathComponent()
            try? SwitchboardStore.ensureAutomationPackageManifest(in: scriptFolder)

            if !SwitchboardStore.isAutomationRuntimeCached(in: scriptFolder) {
                let installPackage = SwitchboardStore.runProcess(
                    arguments: ["npm", "install", "--silent", "--no-audit", "--no-fund", "playwright"],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: scriptFolder,
                    timeoutSeconds: 90
                )
                guard installPackage.status == 0 else {
                    return (false, "Playwright 包安装失败或超时，已保留脚本可重试：\(installPackage.output.ifEmpty("退出码 \(installPackage.status)"))")
                }

                let installBrowser = SwitchboardStore.runProcess(
                    arguments: ["npm", "exec", "--", "playwright", "install", "chromium"],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: scriptFolder,
                    timeoutSeconds: 120
                )
                guard installBrowser.status == 0 else {
                    return (false, "Playwright Chromium 准备失败或超时，已保留脚本可重试：\(installBrowser.output.ifEmpty("退出码 \(installBrowser.status)"))")
                }
                SwitchboardStore.markAutomationRuntimeReady(in: scriptFolder)
            }

            var environment = SwitchboardStore.automationEnvironment()
            environment[typelessAutomationPasswordEnvironmentKey] = password
            let run = SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path],
                environment: environment,
                currentDirectory: scriptFolder,
                timeoutSeconds: 180
            )
            if run.status == 0 {
                return (true, "Playwright 自动化已执行：\(run.output.ifEmpty("无输出"))")
            }
            return (false, "Playwright 自动化未完成，已保留脚本可重试：\(run.output.ifEmpty("退出码 \(run.status)"))")
        }.value
    }

    private nonisolated static func automationEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let additions = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = environment["PATH"] ?? ""
        let merged = (additions + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            .joined(separator: ":")
        environment["PATH"] = merged
        return environment
    }

    private nonisolated static func ensureAutomationPackageManifest(in folder: URL) throws {
        let packageFile = folder.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: packageFile.path) {
            try "{\"private\":true}".write(to: packageFile, atomically: true, encoding: .utf8)
        }
    }

    private nonisolated static func automationRuntimeReadyMarkerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".typeless-playwright-runtime-ready.json")
    }

    private nonisolated static func isAutomationRuntimeCached(in folder: URL) -> Bool {
        let packageFile = folder
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
            .appendingPathComponent("package.json")
        let markerFile = automationRuntimeReadyMarkerURL(in: folder)
        return FileManager.default.fileExists(atPath: packageFile.path) &&
            FileManager.default.fileExists(atPath: markerFile.path) &&
            isPlaywrightChromiumExecutableAvailable(in: folder)
    }

    private nonisolated static func isPlaywrightChromiumExecutableAvailable(in folder: URL) -> Bool {
        let probeScript = """
        const fs = require('fs');
        const { chromium } = require('playwright');
        const executablePath = chromium.executablePath();
        if (!executablePath || !fs.existsSync(executablePath)) {
          console.error('missing chromium executable: ' + executablePath);
          process.exit(2);
        }
        console.log(executablePath);
        """
        let result = runProcess(
            arguments: ["node", "-e", probeScript],
            environment: automationEnvironment(),
            currentDirectory: folder,
            timeoutSeconds: 15
        )
        return result.status == 0
    }

    private nonisolated static func markAutomationRuntimeReady(in folder: URL) {
        let marker = automationRuntimeReadyMarkerURL(in: folder)
        let payload = [
            "readyAt": ISO8601DateFormatter().string(from: Date()),
            "package": "playwright",
            "browser": "chromium"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: marker, options: .atomic)
        }
    }

    private nonisolated static func runAppleEventsProbe(_ appleScript: String) -> (success: Bool, message: String) {
        let result = runProcess(
            arguments: ["osascript", "-e", appleScript],
            environment: automationEnvironment(),
            timeoutSeconds: 8
        )
        if result.status == 0 {
            return (true, result.output.ifEmpty("OK"))
        }
        if result.output.contains("-1743") || result.output.localizedCaseInsensitiveContains("not authorized") {
            return (false, "未授权")
        }
        return (false, result.output.ifEmpty("退出码 \(result.status)"))
    }

    private nonisolated static func runProcess(
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 60
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                group.leave()
            }
            if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                process.terminate()
                return (-2, "命令超时：\(arguments.joined(separator: " "))")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (
                process.terminationStatus,
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func moeMailURL(path: String) -> URL? {
        guard let base = URL(string: state.settings.moeMailBaseURL) else { return nil }
        return URL(string: path, relativeTo: base)
    }

    private func moeMailRequest(url: URL, apiKey: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = body
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "MoeMail",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
            )
        }
        return data
    }

    private func parseMoeMailEmails(from data: Data) -> [MoeMailEmail] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dictionaries = collectDictionaries(from: json)

        let emails = dictionaries.compactMap { dictionary -> MoeMailEmail? in
            let address = stringValue(dictionary, keys: ["email", "address", "mail", "emailAddress"])
            let id = stringValue(dictionary, keys: ["id", "_id", "emailId", "emailID", "uuid"])
            guard !address.isEmpty || !id.isEmpty else { return nil }

            let resolvedAddress = address
            let domain = stringValue(dictionary, keys: ["domain", "mailDomain"])
                .ifEmpty(resolvedAddress.components(separatedBy: "@").last ?? "")
            let name = stringValue(dictionary, keys: ["name", "username", "label"])
                .ifEmpty(resolvedAddress.components(separatedBy: "@").first ?? "")
            let resolvedID = id.ifEmpty(resolvedAddress)

            return MoeMailEmail(
                id: resolvedID,
                address: resolvedAddress,
                name: name,
                domain: domain,
                expiresAt: nil,
                rawSummary: summarize(dictionary)
            )
        }

        return Array(Dictionary(grouping: emails, by: \.id).compactMap { $0.value.first })
            .sorted { $0.address < $1.address }
    }

    private func parseMoeMailMessages(from data: Data) -> [MoeMailMessage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return collectDictionaries(from: json).compactMap { dictionary -> MoeMailMessage? in
            let id = stringValue(dictionary, keys: ["id", "_id", "messageId", "messageID", "uuid"])
            let subject = stringValue(dictionary, keys: ["subject", "title"]).ifEmpty("无主题")
            let sender = stringValue(dictionary, keys: ["from", "sender", "fromAddress"])
            let receivedAt = stringValue(dictionary, keys: ["createdAt", "receivedAt", "date", "time"])
            let preview = stringValue(dictionary, keys: ["preview", "text", "body", "content"])
            guard !id.isEmpty || !sender.isEmpty || subject != "无主题" else { return nil }
            return MoeMailMessage(
                id: id.ifEmpty(UUID().uuidString),
                subject: subject,
                sender: sender,
                receivedAt: receivedAt,
                preview: preview
            )
        }
    }

    private func collectDictionaries(from object: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                result.append(dictionary)
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }

        walk(object)
        return result
    }

    private func stringValue(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                if let string = value as? String {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return ""
    }

    private func summarize(_ dictionary: [String: Any]) -> String {
        dictionary
            .prefix(4)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "  ")
    }

    private func extractDomains(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var values: [String] = []

        func walk(_ object: Any) {
            if let string = object as? String {
                if looksLikeDomain(string) {
                    values.append(string)
                }
            } else if let array = object as? [Any] {
                array.forEach(walk)
            } else if let dictionary = object as? [String: Any] {
                dictionary.values.forEach(walk)
            }
        }

        walk(json)
        return Array(Set(values)).sorted()
    }

    private func looksLikeDomain(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."),
              !trimmed.contains(" "),
              !trimmed.contains("@"),
              !trimmed.hasPrefix("http") else {
            return false
        }
        return trimmed.range(of: #"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}

private extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum KeychainStore {
    private static let service = "local.typeless.switchboard"
    private static let account = "moemail-api-key"
    private static let accountPasswordPrefix = "typeless-account-password-"

    static func readAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveAPIKey(_ value: String) {
        save(value, account: account)
    }

    static func readAccountPassword(accountID: UUID) -> String {
        read(account: accountPasswordPrefix + accountID.uuidString)
    }

    static func saveAccountPassword(_ value: String, accountID: UUID) {
        save(value, account: accountPasswordPrefix + accountID.uuidString)
    }

    private static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            SecItemAdd(createQuery as CFDictionary, nil)
        }
    }
}

@main
struct TypelessSwitchboardApp: App {
    @NSApplicationDelegateAdaptor(SwitchboardAppDelegate.self) private var appDelegate
    @StateObject private var store = SwitchboardStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
                .onAppear {
                    appDelegate.bind(store: store)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

/// 关窗继续跑 + 菜单栏状态，支撑「后台无感守护」。
@MainActor
final class SwitchboardAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private weak var store: SwitchboardStore?
    private var statusItem: NSStatusItem?
    private var statusCancellable: AnyCancellable?
    private var mainWindow: NSWindow?
    private var didInstallWakeObserver = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 允许关主窗后进程仍在，靠菜单栏保活。
        NSApp.setActivationPolicy(.regular)
        installWakeObserverIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 默认不退出；用户可在设置里关掉 keepRunningInBackground。
        !(store?.state.settings.keepRunningInBackground ?? true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 从后台/其他 App 切回来时刷一次菜单栏；守护本身不依赖前台。
        refreshStatusItemTitle()
    }

    func bind(store: SwitchboardStore) {
        guard self.store == nil else { return }
        self.store = store
        installStatusItemIfNeeded()
        installWakeObserverIfNeeded()
        statusCancellable = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemTitle()
            }
        // 启动后稍等再刷一次标题；守护循环由 store.init 负责启动。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshStatusItemTitle()
        }
        // 再过几秒若还没读到剩余字数，主动踢一轮（避免用户以为「监控坏了」）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let store = self.store else { return }
            if store.state.settings.isAutoRotateEnabled, store.liveRemainingCharacters == nil {
                store.resumeRotateMonitorAfterWakeOrManualKick()
            }
            self.refreshStatusItemTitle()
        }
    }

    private func installWakeObserverIfNeeded() {
        guard !didInstallWakeObserver else { return }
        didInstallWakeObserver = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleSystemDidWake() {
        store?.resumeRotateMonitorAfterWakeOrManualKick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshStatusItemTitle()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "switch.2",
                accessibilityDescription: "Typeless Switchboard"
            )
            button.imagePosition = .imageLeading
            button.title = "守护"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "立即巡检额度", action: #selector(runCheckNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        refreshStatusItemTitle()
    }

    private func refreshStatusItemTitle() {
        guard let store, let button = statusItem?.button else { return }
        let threshold = SmartSwitchPolicy.normalizeThreshold(store.state.settings.autoRotateRemainingThreshold)
        if store.isRunningAutomaticReplacement || store.isRunningSmartSwitch {
            button.title = "换号中"
            button.toolTip = store.autoRotateMonitorStatus
            return
        }
        if let remaining = store.liveRemainingCharacters {
            // 菜单栏：剩余字数；低于阈值时加「↓」提示即将/正在低额度。
            button.title = remaining < threshold ? "↓\(remaining)" : "\(remaining)"
            button.toolTip = [
                store.liveAccountEmail.isEmpty ? nil : "当前：\(store.liveAccountEmail)",
                "剩余 \(remaining) 字 · 换号阈值 \(threshold)（仅低于阈值才自动换）",
                store.autoRotateMonitorStatus,
                store.lastAutoRotateDecisionReason.isEmpty ? nil : store.lastAutoRotateDecisionReason
            ].compactMap { $0 }.joined(separator: "\n")
        } else if store.state.settings.isAutoRotateEnabled {
            button.title = "监控"
            button.toolTip = [
                "无感额度守护已开，等待读到官方剩余字数",
                "换号阈值：剩余 < \(threshold) 才自动换号",
                store.autoRotateMonitorStatus
            ].joined(separator: "\n")
        } else {
            button.title = "关闭"
            button.toolTip = "无感额度守护已关闭"
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // 若窗口已被关，发通知让系统重建（SwiftUI WindowGroup 会在 activate 时恢复）。
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func runCheckNow() {
        guard let store else { return }
        store.resumeRotateMonitorAfterWakeOrManualKick()
        Task {
            // resume 里已可能触发检查；再刷一次标题保证菜单栏更新。
            try? await Task.sleep(nanoseconds: 500_000_000)
            refreshStatusItemTitle()
        }
    }

    @objc private func quitApp() {
        store?.stopRotateMonitor()
        NSApp.terminate(nil)
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: SwitchboardStore
    @State private var selectedID: UUID?
    @State private var apiKey = KeychainStore.readAPIKey()
    @State private var searchText = ""
    @State private var listFilter: AccountListFilter = .all
    @State private var commandLineAutomationStarted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 304)

            Divider()

            detailArea
                .frame(minWidth: 500)

            Divider()

            InspectorView(apiKey: $apiKey, selectedID: $selectedID)
                .frame(width: 360)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fontDesign(.rounded)
        .onAppear {
            if selectedID == nil {
                selectedID = store.state.accounts.first?.id
            }
        }
        .task {
            guard !commandLineAutomationStarted else { return }
            commandLineAutomationStarted = true
            if await store.runCommandLineAutomaticReplacementIfRequested() {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "switch.2")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Typeless Switchboard")
                        .font(.title2.weight(.semibold))
                    Text("MoeMail 注册与账号切换")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 18)

            if store.diagnostics.contains(where: { $0.level == .error }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("环境依赖或权限缺失")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.orange)
                        Text("部分功能受限，请在右侧运行“一键自检”")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
                .padding(.horizontal, 14)
            }


            QuotaSummaryView()
                .padding(.horizontal, 14)

            VStack(spacing: 8) {
                TextField("搜索账号、邮箱或域名", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("筛选", selection: $listFilter) {
                    ForEach(AccountListFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 14)

            List(selection: $selectedID) {
                ForEach(filteredAccounts) { account in
                    AccountRow(account: account)
                        .tag(account.id)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 8) {
                Button {
                    selectedID = store.addAccount()
                } label: {
                    Label("新增", systemImage: "plus")
                }

                Button {
                    selectedID = store.nextAvailableAccountID()
                } label: {
                    Label("下一个", systemImage: "arrow.right.circle")
                }
                .disabled(store.nextAvailableAccountID() == nil)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 18)

            if store.isSyncingSession {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("同步官方 App 登录与额度中...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
            } else {
                Button {
                    Task {
                        if let newID = await store.syncActiveAppSessionAndQuota() {
                            selectedID = newID
                        }
                    }
                } label: {
                    Label("同步官方 App 登录与额度", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 18)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("无感额度守护（后台自动换号）", isOn: Binding(
                    get: { store.state.settings.isAutoRotateEnabled },
                    set: { newValue in
                        store.state.settings.isAutoRotateEnabled = newValue
                        store.save()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.subheadline.weight(.medium))

                Toggle("池空时自动注册新号", isOn: Binding(
                    get: { store.state.settings.autoCreateWhenPoolEmpty },
                    set: { newValue in
                        store.state.settings.autoCreateWhenPoolEmpty = newValue
                        store.save()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!store.state.settings.isAutoRotateEnabled)

                Toggle("关窗后继续后台守护", isOn: Binding(
                    get: { store.state.settings.keepRunningInBackground },
                    set: { newValue in
                        store.state.settings.keepRunningInBackground = newValue
                        store.save()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)

                HStack {
                    Text("剩余 <")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "阈值",
                        value: Binding(
                            get: { store.state.settings.autoRotateRemainingThreshold },
                            set: { newValue in
                                store.state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.normalizeThreshold(newValue)
                                store.save()
                            }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    Text("字换号 · 热备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "热备",
                        value: Binding(
                            get: { store.state.settings.hotSpareTargetCount },
                            set: { newValue in
                                store.state.settings.hotSpareTargetCount = SmartSwitchPolicy.normalizeHotSpareTarget(newValue)
                                store.save()
                            }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    Text("个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let remaining = store.liveRemainingCharacters {
                    let threshold = SmartSwitchPolicy.normalizeThreshold(store.state.settings.autoRotateRemainingThreshold)
                    let emailSuffix = store.liveAccountEmail.isEmpty ? "" : " · \(store.liveAccountEmail)"
                    let line = remaining >= threshold
                        ? "当前剩余 \(remaining) 字 ≥ 阈值 \(threshold)：只监控，不换号\(emailSuffix)"
                        : "当前剩余 \(remaining) 字 < 阈值 \(threshold)：将自动换号\(emailSuffix)"
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(remaining >= threshold ? Color.secondary : Color.orange)
                        .lineLimit(2)
                } else if store.state.settings.isAutoRotateEnabled {
                    Text("等待读到官方剩余字数…（需本机 Typeless 已登录，且 Switchboard 保持运行）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(store.autoRotateMonitorStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                if !store.lastAutoRotateDecisionReason.isEmpty {
                    Text(store.lastAutoRotateDecisionReason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }

                Text("规则：一直监控额度；仅当剩余 < 阈值（默认 200）才自动换号。接近阈值约 20 秒巡检，否则按分钟巡检。热备后台预注册；静默换号会轮换设备身份。请保持本 App 在菜单栏运行。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)

            Button {
                Task {
                    selectedID = await store.runSmartSwitch(
                        apiKey: apiKey,
                        domain: store.state.settings.domains.first ?? "",
                        expiryTime: 0,
                        from: selectedID,
                        forceSwitch: true
                    )
                }
            } label: {
                Label(
                    store.isSwitchBusy ? "换号进行中…" : "智能换号（一点就换）",
                    systemImage: "bolt.horizontal.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(store.isSwitchBusy)
            .padding(.horizontal, 18)

            Button {
                selectedID = store.prepareSwitch(from: selectedID)
            } label: {
                Label("准备切换（打开页面兜底）", systemImage: "forward.end.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.nextAvailableAccountID() == nil || store.isSwitchBusy)
            .padding(.horizontal, 18)

            Button {
                Task {
                    selectedID = await store.runOneClickAutomaticReplacement(
                        apiKey: apiKey,
                        domain: store.state.settings.domains.first ?? "",
                        expiryTime: 0,
                        from: selectedID,
                        interactive: true
                    )
                }
            } label: {
                Label(
                    store.isRunningAutomaticReplacement ? "注册换号中" : "强制全自动注册新号",
                    systemImage: "wand.and.stars.inverse"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isSwitchBusy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var filteredAccounts: [Account] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.state.accounts.filter { account in
            let matchesFilter: Bool
            switch listFilter {
            case .all:
                matchesFilter = true
            case .available:
                matchesFilter = account.isUsable && account.remainingCharacters > 0
            case .pending:
                matchesFilter = account.effectiveReviewState == .pending
            case .exhausted:
                matchesFilter = account.status == .exhausted || account.remainingCharacters == 0
            case .paused:
                matchesFilter = account.status == .paused || account.effectiveReviewState == .rejected
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }

            let haystack = [
                account.name,
                account.email,
                account.domain,
                account.role,
                account.typelessUsername ?? "",
                account.notes
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        if let index = store.accountIndex(id: selectedID) {
            AccountDetailView(
                account: accountBinding(index: index),
                onSave: store.save,
                onDelete: {
                    let deletedID = store.state.accounts[index].id
                    store.deleteAccount(id: deletedID)
                    selectedID = store.state.accounts.first?.id
                }
            )
        } else {
            EmptyStateView {
                selectedID = store.addAccount()
            }
        }
    }

    private func accountBinding(index: Int) -> Binding<Account> {
        Binding(
            get: { store.state.accounts[index] },
            set: { newValue in
                store.state.accounts[index] = newValue
                store.save()
            }
        )
    }
}

struct QuotaSummaryView: View {
    @EnvironmentObject private var store: SwitchboardStore

    private var totalRemaining: Int {
        store.state.accounts.reduce(0) { $0 + $1.remainingCharacters }
    }

    private var availableCount: Int {
        store.state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
    }

    private var pendingCount: Int {
        store.state.accounts.filter { $0.effectiveReviewState == .pending }.count
    }

    private var exhaustedCount: Int {
        store.state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }.count
    }

    private var pausedCount: Int {
        store.state.accounts.filter { $0.status == .paused || $0.effectiveReviewState == .rejected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("可用账号", systemImage: "person.crop.circle.badge.checkmark")
                Spacer()
                Text("\(availableCount)")
                    .font(.title3.weight(.semibold))
            }
            HStack {
                Label("剩余额度", systemImage: "textformat.size")
                Spacer()
                Text("\(totalRemaining)")
                    .font(.title3.weight(.semibold))
            }
            Divider()
            HStack(spacing: 8) {
                SummaryPill(title: "待确认", value: pendingCount, color: .orange)
                SummaryPill(title: "用完", value: exhaustedCount, color: .red)
                SummaryPill(title: "暂停", value: pausedCount, color: .secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SummaryPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
            Text("\(value)")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name.isEmpty ? "未命名账号" : account.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(account.status.color)
                    .frame(width: 8, height: 8)
            }

            Text(account.email.isEmpty ? account.domain : account.email)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ProgressView(value: account.usageRatio)
                .tint(account.status.color)

            HStack(spacing: 6) {
                Text("剩余 \(account.remainingCharacters) / \(account.monthlyLimit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(account.status.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(account.status.color.opacity(0.14))
                    .foregroundStyle(account.status.color)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                if account.effectiveReviewState != .approved {
                    Text(account.effectiveReviewState.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(account.effectiveReviewState.color.opacity(0.14))
                        .foregroundStyle(account.effectiveReviewState.color)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct AccountDetailView: View {
    @Binding var account: Account
    let onSave: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var store: SwitchboardStore
    @State private var showingDeleteConfirmation = false
    @State private var generatedPassword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                complianceNotice
                quotaPanel
                editorPanel
                registrationPanel
                actionPanel
            }
            .padding(24)
        }
        .confirmationDialog("删除这个账号？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) { }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.name.isEmpty ? "未命名账号" : account.name)
                    .font(.largeTitle.weight(.semibold))
                Text(account.email.isEmpty ? "还没有填写邮箱" : account.email)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Picker("状态", selection: binding(\.status)) {
                    ForEach(AccountStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Label(account.effectiveReviewState.title, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(account.effectiveReviewState.color)
            }
        }
    }

    private var complianceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.blue)
            Text("这个工具支持自动创建邮箱、浏览器注册、验证码轮询和结果桥接；一键换号会按 typeless-toolkit resetDevice 重置本机设备身份，清理桌面端/Chrome 旧登录态，并把成功账号直接自动确认。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var quotaPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本月额度", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
                Spacer()
                Text("剩余 \(account.remainingCharacters) 字")
                    .font(.headline)
            }

            ProgressView(value: account.usageRatio)
                .tint(account.status.color)

            HStack(spacing: 12) {
                NumberField(title: "已用字数", value: binding(\.usedCharacters))
                NumberField(title: "每月额度", value: binding(\.monthlyLimit))
            }

            HStack(spacing: 8) {
                Button {
                    account.usedCharacters = account.monthlyLimit
                    account.status = .exhausted
                    onSave()
                } label: {
                    Label("标记已用完", systemImage: "xmark.circle")
                }

                Button {
                    account.usedCharacters = 0
                    account.status = .available
                    account.lastResetAt = Date()
                    onSave()
                } label: {
                    Label("本月重置", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("账号资料", systemImage: "person.text.rectangle")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("名称")
                    TextField("例如：主力账号", text: binding(\.name))
                }
                GridRow {
                    Text("邮箱")
                    TextField("name@example.com", text: binding(\.email))
                }
                GridRow {
                    Text("MoeMail ID")
                    TextField("邮箱 ID，可从 MoeMail 导入", text: optionalStringBinding(\.moeMailEmailID))
                }
                GridRow {
                    Text("登录名")
                    TextField("Typeless 用户名或显示名", text: optionalStringBinding(\.typelessUsername))
                }
                GridRow {
                    Text("密码提示")
                    TextField("不要保存明文密码", text: optionalStringBinding(\.passwordHint))
                }
                GridRow {
                    Text("域名")
                    Picker("域名", selection: binding(\.domain)) {
                        ForEach(store.state.settings.domains, id: \.self) { domain in
                            Text(domain).tag(domain)
                        }
                    }
                }
                GridRow {
                    Text("角色")
                    TextField("平民 / 骑士 / 其他", text: binding(\.role))
                }
                GridRow {
                    Text("Typeless")
                    TextField("登录页地址", text: binding(\.typelessURL))
                }
                GridRow {
                    Text("邮箱入口")
                    TextField("邮箱或收件箱地址", text: binding(\.inboxURL))
                }
                GridRow {
                    Text("备注")
                    TextField("手动记录用途、到期时间或注意事项", text: binding(\.notes), axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
            }
            .font(.callout)
        }
        .panelStyle()
    }

    private var registrationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("注册助手 / 兜底", systemImage: "person.badge.plus")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("邮箱")
                        .foregroundStyle(.secondary)
                    Text(account.email.isEmpty ? "未填写" : account.email)
                        .lineLimit(1)
                }
                GridRow {
                    Text("用户名")
                        .foregroundStyle(.secondary)
                    Text((account.typelessUsername ?? account.name).isEmpty ? "未填写" : (account.typelessUsername ?? account.name))
                        .lineLimit(1)
                }
                GridRow {
                    Text("强密码")
                        .foregroundStyle(.secondary)
                    SecureField("先生成，再复制", text: $generatedPassword)
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button {
                    let profile = AccountProfileGenerator.make(domain: account.domain.ifEmpty(store.state.settings.domains.first ?? "example.com"))
                    account.name = profile.displayName
                    account.typelessUsername = profile.username
                    account.email = profile.email
                    account.domain = profile.domain
                    account.status = .available
                    account.usedCharacters = 0
                    generatedPassword = profile.password
                    copy(profile.password, message: "已生成候选资料，并复制强密码")
                    onSave()
                } label: {
                    Label("生成候选资料", systemImage: "sparkles")
                }

                Button {
                    generatedPassword = PasswordGenerator.make()
                    copy(generatedPassword, message: "已生成并复制强密码")
                } label: {
                    Label("生成密码", systemImage: "key.horizontal")
                }

                Button {
                    copy(account.email, message: "已复制邮箱")
                } label: {
                    Label("复制邮箱", systemImage: "at")
                }
                .disabled(account.email.isEmpty)

                Button {
                    let value = (account.typelessUsername ?? account.name).trimmingCharacters(in: .whitespacesAndNewlines)
                    copy(value, message: "已复制用户名")
                } label: {
                    Label("复制用户名", systemImage: "person.text.rectangle")
                }
                .disabled((account.typelessUsername ?? account.name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    open(account.typelessURL)
                } label: {
                    Label("打开注册页", systemImage: "safari")
                }

                Button {
                    store.copyRegistrationPreparationPlan(for: account.id)
                } label: {
                    Label("复制准备包", systemImage: "doc.text")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    open(account.inboxURL)
                } label: {
                    Label("打开邮箱", systemImage: "envelope")
                }

                Button {
                    account.usedCharacters = 0
                    account.status = .available
                    account.reviewState = .approved
                    account.reviewedAt = Date()
                    if account.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        account.notes = "已由兜底完成注册核验"
                    }
                    onSave()
                    store.statusMessage = "已记录兜底核验完成"
                } label: {
                    Label("记录完成", systemImage: "checkmark.circle")
                }

                Button {
                    account.reviewState = .rejected
                    account.status = .paused
                    onSave()
                    store.statusMessage = "已退回当前候选账号"
                } label: {
                    Label("退回", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("切换操作", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    open(account.typelessURL)
                } label: {
                    Label("打开 Typeless", systemImage: "safari")
                }

                Button {
                    open(account.inboxURL)
                } label: {
                    Label("打开邮箱", systemImage: "envelope.open")
                }

                Button {
                    copy(account.email, message: "已复制邮箱")
                } label: {
                    Label("复制邮箱", systemImage: "doc.on.doc")
                }
                .disabled(account.email.isEmpty)

                Button {
                    store.copySwitchSummary(for: account.id)
                } label: {
                    Label("复制摘要", systemImage: "list.clipboard")
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Account, Value>) -> Binding<Value> {
        Binding(
            get: { account[keyPath: keyPath] },
            set: { newValue in
                account[keyPath: keyPath] = newValue
                onSave()
            }
        )
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<Account, String?>) -> Binding<String> {
        Binding(
            get: { account[keyPath: keyPath] ?? "" },
            set: { newValue in
                account[keyPath: keyPath] = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue
                onSave()
            }
        )
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            store.statusMessage = "无法打开地址"
            return
        }
        store.statusMessage = "已打开浏览器"
    }

    private func copy(_ value: String, message: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        store.statusMessage = message
    }
}

struct InspectorView: View {
    @EnvironmentObject private var store: SwitchboardStore
    @Binding var apiKey: String
    @Binding var selectedID: UUID?

    @State private var newDomain = ""
    @State private var isRefreshing = false
    @State private var isLoadingEmails = false
    @State private var isGeneratingEmail = false
    @State private var isCreatingRegistration = false
    @State private var isLoadingMessages = false
    @State private var isCheckingTypeless = false
    @State private var generatedName = "typeless"
    @State private var generatedDomain = defaultDomains.first ?? ""
    @State private var generatedExpiry = 0
    @State private var candidateCount = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsPanel
                accountPoolPanel
                reviewQueuePanel
                moeMailPanel
                checklistPanel
                domainsPanel
                statusPanel
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("连接设置", systemImage: "gearshape")
                .font(.headline)

            TextField("Typeless 入口", text: settingsBinding(\.typelessLoginURL))
            TextField("MoeMail 地址", text: settingsBinding(\.moeMailBaseURL))
            SecureField("MoeMail API Key", text: $apiKey)

            HStack(spacing: 8) {
                Button {
                    store.openInstalledTypelessApp()
                } label: {
                    Label("打开 App", systemImage: "macwindow")
                }

                Button {
                    store.openTypelessOfficialWebsite()
                } label: {
                    Label("打开官网", systemImage: "safari")
                }

                Button {
                    isCheckingTypeless = true
                    Task {
                        await store.checkTypelessEntry()
                        isCheckingTypeless = false
                    }
                } label: {
                    Label(isCheckingTypeless ? "检查中" : "检查入口", systemImage: "network")
                }
                .disabled(isCheckingTypeless)
            }
            .buttonStyle(.bordered)

            Button {
                isCheckingTypeless = true
                Task {
                    await store.runSetupDiagnostics(apiKey: apiKey)
                    isCheckingTypeless = false
                }
            } label: {
                Label(isCheckingTypeless ? "自检中" : "一键自检", systemImage: "checklist.checked")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCheckingTypeless)

            HStack(spacing: 8) {
                Menu {
                    ForEach(MacPermissionChecklist.recommendedItems.filter { $0.settingsPaneIdentifier != nil }, id: \.title) { item in
                        Button(item.title) {
                            if let pane = item.settingsPaneIdentifier {
                                store.openMacPermissionSettings(pane)
                            }
                        }
                    }
                } label: {
                    Label("打开权限设置", systemImage: "lock.shield")
                }

                Button {
                    store.copyMacPermissionChecklist()
                } label: {
                    Label("复制权限清单", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    KeychainStore.saveAPIKey(apiKey)
                    store.statusMessage = "API Key 已保存到钥匙串"
                } label: {
                    Label("保存密钥", systemImage: "key")
                }

                Button {
                    isRefreshing = true
                    Task {
                        await store.refreshMoeMailConfig(apiKey: apiKey)
                        isRefreshing = false
                    }
                } label: {
                    Label(isRefreshing ? "同步中" : "同步域名", systemImage: "arrow.down.circle")
                }
                .disabled(isRefreshing)
            }
            .buttonStyle(.bordered)

            if !store.diagnostics.isEmpty {
                VStack(spacing: 8) {
                    ForEach(store.diagnostics) { item in
                        DiagnosticRow(item: item)
                    }
                }
            }
        }
        .panelStyle()
    }

    private var accountPoolPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("账号池工具", systemImage: "tray.full")
                .font(.headline)

            Stepper(value: $candidateCount, in: 1...30) {
                Text("候选账号数量：\(candidateCount)")
                    .font(.callout)
            }

            Picker("候选域名", selection: $generatedDomain) {
                ForEach(store.state.settings.domains, id: \.self) { domain in
                    Text(domain).tag(domain)
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.generateCandidateAccounts(count: candidateCount, domain: generatedDomain)
                } label: {
                    Label("批量生成", systemImage: "sparkles")
                }

                Button {
                    selectedID = store.prepareSwitch(from: selectedID)
                } label: {
                    Label("准备切换", systemImage: "forward.end.circle")
                }
                .disabled(store.nextAvailableAccountID() == nil || store.isSwitchBusy)
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    selectedID = await store.runSmartSwitch(
                        apiKey: apiKey,
                        domain: generatedDomain,
                        expiryTime: generatedExpiry,
                        from: selectedID,
                        forceSwitch: true
                    )
                }
            } label: {
                Label(
                    store.isSwitchBusy ? "智能换号中…" : "智能换号（优先池内，必要时注册）",
                    systemImage: "bolt.horizontal.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(store.isSwitchBusy)

            Button {
                Task {
                    selectedID = await store.runOneClickAutomaticReplacement(
                        apiKey: apiKey,
                        domain: generatedDomain,
                        expiryTime: generatedExpiry,
                        from: selectedID,
                        interactive: true
                    )
                }
            } label: {
                Label(
                    store.isRunningAutomaticReplacement ? "自动创建和切换中" : "强制全自动注册新号",
                    systemImage: "wand.and.stars"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(
                store.isSwitchBusy ||
                apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                generatedDomain.isEmpty
            )

            HStack(spacing: 8) {
                Button {
                    store.exportAccountsToClipboard()
                } label: {
                    Label("复制 JSON", systemImage: "doc.on.doc")
                }

                Button {
                    store.importAccountsFromClipboard()
                    selectedID = store.state.accounts.first?.id
                } label: {
                    Label("恢复 JSON", systemImage: "arrow.down.doc")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.exportAccountsCSVToClipboard()
                } label: {
                    Label("复制 CSV", systemImage: "tablecells")
                }

                Button {
                    store.importAccountsCSVFromClipboard()
                    selectedID = store.state.accounts.first?.id
                } label: {
                    Label("导入 CSV", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.bordered)

            Button {
                store.importToolkitAccountsFromClipboard()
                selectedID = store.state.accounts.first?.id
            } label: {
                Label("导入 toolkit 账号", systemImage: "square.stack.3d.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.copyAccountPoolAuditToClipboard()
            } label: {
                Label("复制体检报告", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.resetMonthlyQuotaForApprovedAccounts()
            } label: {
                Label("月初重置已确认账号", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
        .onAppear {
            if generatedDomain.isEmpty {
                generatedDomain = store.state.settings.domains.first ?? ""
            }
        }
    }

    private var reviewQueuePanel: some View {
        let pendingIDs = store.pendingReviewAccountIDs()
        return VStack(alignment: .leading, spacing: 12) {
            if pendingIDs.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("全自动换号确认状态", systemImage: "bolt.badge.checkmark")
                            .font(.headline)
                        Text(store.state.lastAutomationResult?.status == .completed
                             ? "最近一次一键换号已自动确认成功账号，不需要再点“确认/退回”。"
                             : "当前没有待兜底确认账号；只有自动化无法证明注册完成时，才会出现兜底队列。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Label("兜底确认队列", systemImage: "checkmark.seal")
                        .font(.headline)
                    Spacer()
                    Text("\(pendingIDs.count)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Text("这里仅显示自动化没有证明完成的候选账号；正常一键换号成功后会直接进入已确认可用池。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(pendingIDs.prefix(8), id: \.self) { id in
                        if let index = store.accountIndex(id: id) {
                            ReviewAccountRow(
                                account: store.state.accounts[index],
                                onSelect: { selectedID = id },
                                onApprove: {
                                    store.approveAccount(id: id)
                                    selectedID = id
                                },
                                onReject: { store.rejectAccount(id: id) }
                            )
                        }
                    }
                }
            }
        }
        .panelStyle()
    }

    private var moeMailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MoeMail 邮箱", systemImage: "mail.stack")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                    TextField("邮箱前缀", text: $generatedName)
                }
                GridRow {
                    Text("域名")
                    Picker("域名", selection: $generatedDomain) {
                        ForEach(store.state.settings.domains, id: \.self) { domain in
                            Text(domain).tag(domain)
                        }
                    }
                }
                GridRow {
                    Text("有效期")
                    Picker("有效期", selection: $generatedExpiry) {
                        Text("永久").tag(0)
                        Text("1 小时").tag(3_600_000)
                        Text("1 天").tag(86_400_000)
                        Text("7 天").tag(604_800_000)
                    }
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button {
                    isLoadingEmails = true
                    Task {
                        await store.loadMoeMailEmails(apiKey: apiKey)
                        isLoadingEmails = false
                    }
                } label: {
                    Label(isLoadingEmails ? "读取中" : "读取列表", systemImage: "tray.and.arrow.down")
                }
                .disabled(isLoadingEmails)

                Button {
                    isGeneratingEmail = true
                    Task {
                        if let email = await store.generateMoeMailEmail(
                            apiKey: apiKey,
                            name: generatedName,
                            domain: generatedDomain,
                            expiryTime: generatedExpiry
                        ) {
                            selectedID = store.importMoeMailEmail(email)
                        }
                        isGeneratingEmail = false
                    }
                } label: {
                    Label(isGeneratingEmail ? "生成中" : "生成并导入", systemImage: "plus.circle")
                }
                .disabled(isGeneratingEmail || generatedDomain.isEmpty)
            }
            .buttonStyle(.bordered)

            Button {
                isCreatingRegistration = true
                Task {
                    if let id = await store.createMoeMailRegistrationCandidate(
                        apiKey: apiKey,
                        domain: generatedDomain,
                        expiryTime: generatedExpiry
                    ) {
                        selectedID = id
                    }
                    isCreatingRegistration = false
                }
            } label: {
                Label(isCreatingRegistration ? "创建中" : "创建注册候选账号", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCreatingRegistration || generatedDomain.isEmpty)

            if store.moeMailEmails.isEmpty {
                Text("读取 MoeMail 后，可以把已有邮箱导入账号池。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.moeMailEmails.prefix(8)) { email in
                        MoeMailEmailRow(email: email) {
                            selectedID = store.importMoeMailEmail(email)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    guard let index = store.accountIndex(id: selectedID) else { return }
                    let account = store.state.accounts[index]
                    isLoadingMessages = true
                    Task {
                        await store.loadMessages(for: account, apiKey: apiKey)
                        isLoadingMessages = false
                    }
                } label: {
                    Label(isLoadingMessages ? "读取中" : "读取当前账号邮件", systemImage: "envelope.badge")
                }
                .disabled(isLoadingMessages || selectedAccount?.moeMailEmailID == nil)
            }
            .buttonStyle(.bordered)

            if !store.moeMailMessages.isEmpty {
                VStack(spacing: 8) {
                    ForEach(store.moeMailMessages.prefix(5)) { message in
                        MoeMailMessageRow(message: message)
                    }
                }
            }
        }
        .panelStyle()
        .onAppear {
            if generatedDomain.isEmpty {
                generatedDomain = store.state.settings.domains.first ?? ""
            }
        }
    }

    private var checklistPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("切换清单", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Button {
                    store.resetChecklist()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("重置清单")
            }

            ForEach(store.state.settings.checklist.indices, id: \.self) { index in
                Toggle(isOn: checklistBinding(index: index, keyPath: \.isDone)) {
                    Text(store.state.settings.checklist[index].title)
                        .font(.callout)
                        .foregroundStyle(store.state.settings.checklist[index].isRequired ? .primary : .secondary)
                }
            }

            if let next = store.nextAvailableAccountID() {
                Button {
                    selectedID = next
                    store.resetChecklist()
                } label: {
                    Label("选择下一个可用账号", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .panelStyle()
    }

    private var domainsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("邮箱域名", systemImage: "at")
                .font(.headline)

            HStack {
                TextField("添加域名", text: $newDomain)
                Button {
                    let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if !store.state.settings.domains.contains(trimmed) {
                        store.state.settings.domains.append(trimmed)
                        store.state.settings.domains.sort()
                        store.save()
                    }
                    newDomain = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], spacing: 8) {
                ForEach(store.state.settings.domains, id: \.self) { domain in
                    Text(domain)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .panelStyle()
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("状态", systemImage: "info.circle")
                .font(.headline)
            Text(store.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("账号数据保存在本机 Application Support，MoeMail 密钥保存在 macOS 钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let result = store.state.lastAutomationResult {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("最近自动换号", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                    Text(result.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.status == .completed ? .green : .orange)
                    Text(result.markdown)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.markdown, forType: .string)
                        store.statusMessage = "已复制最近自动换号结果"
                    } label: {
                        Label("复制自动化结果", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.openLastAutomationBrowserSession()
                    } label: {
                        Label("打开新账号会话", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!result.canOpenBrowserSession)

                    Button {
                        Task {
                            if let id = await store.retryLastAutomation() {
                                selectedID = id
                            }
                        }
                    } label: {
                        Label(
                            store.isRunningAutomaticReplacement ? "重试中" : "重试最近自动化",
                            systemImage: "arrow.clockwise.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!result.canRetry || store.isRunningAutomaticReplacement)
                }
            }
            HStack(spacing: 8) {
                Button {
                    store.openDataFolder()
                } label: {
                    Label("打开数据", systemImage: "folder")
                }

                Button {
                    store.copyDataPath()
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)

            Button {
                store.copyTypelessEnvironmentReport()
            } label: {
                Label("复制 Typeless 环境", systemImage: "terminal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.copyDeviceInfoReport()
            } label: {
                Label("复制设备信息", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.captureLoginSnapshotManifest()
                } label: {
                    Label("生成登录态快照", systemImage: "camera.metering.matrix")
                }

                Button {
                    store.copyLatestLoginSnapshotManifest()
                } label: {
                    Label("复制快照", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)

            Button {
                store.copyTokenAuditReport()
            } label: {
                Label("复制 token 报告", systemImage: "key.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.copyTroubleshootingBundle()
            } label: {
                Label("复制完整排障包", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .panelStyle()
    }

    private var selectedAccount: Account? {
        guard let index = store.accountIndex(id: selectedID) else { return nil }
        return store.state.accounts[index]
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.settings[keyPath: keyPath] },
            set: { newValue in
                store.state.settings[keyPath: keyPath] = newValue
                store.save()
            }
        )
    }

    private func checklistBinding<Value>(index: Int, keyPath: WritableKeyPath<SwitchTask, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.settings.checklist[index][keyPath: keyPath] },
            set: { newValue in
                store.state.settings.checklist[index][keyPath: keyPath] = newValue
                store.save()
            }
        )
    }
}

struct MoeMailEmailRow: View {
    let email: MoeMailEmail
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(email.address.isEmpty ? email.displayName : email.address)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(email.domain.isEmpty ? email.id : email.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onImport()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("导入账号池")
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ReviewAccountRow: View {
    let account: Account
    let onSelect: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email.isEmpty ? account.name : account.email)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text((account.typelessUsername ?? account.domain).ifEmpty(account.domain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button {
                    onApprove()
                } label: {
                    Label("确认", systemImage: "checkmark")
                }

                Button {
                    onReject()
                } label: {
                    Label("退回", systemImage: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct DiagnosticRow: View {
    let item: DiagnosticItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.level.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(item.level.title)
                        .font(.caption)
                        .foregroundStyle(item.level.color)
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct MoeMailMessageRow: View {
    let message: MoeMailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.subject)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if !message.receivedAt.isEmpty {
                    Text(message.receivedAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !message.sender.isEmpty {
                Text(message.sender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !message.preview.isEmpty {
                Text(message.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct EmptyStateView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("还没有账号")
                .font(.title2.weight(.semibold))
            Text("先添加你已经拥有并有权使用的账号，再用这里记录额度和切换状态。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onCreate()
            } label: {
                Label("添加账号", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: $value, formatter: NumberFormatter.integer)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private extension NumberFormatter {
    static var integer: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 0
        return formatter
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct GeneratedAccountProfile {
    var displayName: String
    var username: String
    var email: String
    var domain: String
    var password: String
}

enum AccountProfileGenerator {
    private static let adjectives = [
        "clear", "swift", "bright", "quiet", "fresh", "lucky", "solid", "rapid",
        "neat", "smart", "calm", "prime", "true", "bold", "clean", "sharp"
    ]
    private static let nouns = [
        "note", "draft", "paper", "cursor", "field", "page", "signal", "orbit",
        "marker", "line", "pixel", "folder", "writer", "memo", "frame", "script"
    ]

    static func make(domain: String) -> GeneratedAccountProfile {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("example.com")
        let adjective = adjectives.randomElement() ?? "clear"
        let noun = nouns.randomElement() ?? "note"
        let suffix = String(Int.random(in: 100_000...999_999))
        let username = "\(adjective)_\(noun)_\(suffix)"
        let email = "\(adjective).\(noun).\(suffix)@\(normalizedDomain)"

        return GeneratedAccountProfile(
            displayName: "\(adjective.capitalized) \(noun.capitalized)",
            username: username,
            email: email,
            domain: normalizedDomain,
            password: PasswordGenerator.make()
        )
    }
}

enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("23456789")
    private static let symbols = Array("!@#$%*+=?")

    static func make(length: Int = 20) -> String {
        let required = [
            lowercase.randomElement() ?? "a",
            uppercase.randomElement() ?? "A",
            digits.randomElement() ?? "2",
            symbols.randomElement() ?? "!"
        ]
        let all = lowercase + uppercase + digits + symbols
        let rest = (0..<max(length - required.count, 0)).map { _ in
            all.randomElement() ?? "x"
        }
        return String((required + rest).shuffled())
    }
}

private struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func panelStyle() -> some View {
        modifier(PanelStyle())
    }
}
