import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

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

    /// 当前档位（从服务端下发的周额度反推，见 `QuotaTier`）。
    var quotaTier: QuotaTier { QuotaTier.from(weeklyLimit: monthlyLimit) }

    /// Pro 试用的到期时刻。非试用档返回 nil。
    var trialEndsAt: Date? {
        QuotaTier.trialEndsAt(createdAt: createdAt, weeklyLimit: monthlyLimit)
    }

    /// Pro 试用剩余天数（不足一天算 1 天；已到期为 0）。非试用档返回 nil。
    var trialDaysRemaining: Int? {
        QuotaTier.trialDaysRemaining(createdAt: createdAt, weeklyLimit: monthlyLimit, now: Date())
    }

    /// 账号列表上的档位徽章文案。免费档是常态，返回 nil 以免列表被噪音塞满。
    var tierBadgeText: String? {
        QuotaTier.badgeText(weeklyLimit: monthlyLimit, createdAt: createdAt, now: Date())
    }

    var isUsable: Bool {
        (status == .available || status == .nearlySpent) && (reviewState ?? .approved) == .approved
    }

    /// 是否带静默会话 —— 换号时要把它写进 Typeless 的 `user-data.json`，
    /// 官方桌面端据此换发新 token。没有它就只能重新注册/登录，
    /// 所以它的额度**换不过去**，不该算进「剩余额度」（见 `QuotaPoolSummary`）。
    var hasSwitchableSession: Bool {
        !(rawUserDataPayload ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 会话令牌健康度（v2.7.2）
    //
    // 此前静默换号只判断「有没有存过桌面会话缓存」，从不看令牌是否还活着。
    // 实测发现 Typeless 的 access_token 寿命约 1 天、refresh_token 约 9 个月～1 年。
    // 注入时两个令牌一起交给桌面端，桌面端会用 refresh_token 续发新的 access_token——
    // 所以真正决定「切过去能不能用」的是 refresh_token 是否还有效，而不是 access_token 当天是否过期。
    //
    // 这里把健康度算出来，有两个用途：
    //   1. 让静默换号候选选择不再挑「refresh 已死」的僵尸号（见 `isSilentlySwitchable`）；
    //   2. 让用户在 UI / 体检报告里直接看到每个号的会话状态，不做黑盒。

    /// 从 `rawUserDataPayload` 解出内层 credentials 字典（含 access_token / refresh_token）。
    /// 外层是 `{"userData": "<escaped json>"}`，内层才是真正的令牌字典。
    private var decodedSessionCredentials: [String: Any]? {
        guard let payload = rawUserDataPayload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !payload.isEmpty,
              let outer = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else { return nil }
        let userData = outer["userData"]
        if let s = userData as? String, let d = s.data(using: .utf8) {
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        return userData as? [String: Any]
    }

    /// 解码 JWT 的 `exp` 字段（不验签，只读过期时间）。非 JWT / 坏格式返回 nil。
    private static func jwtExpiry(_ token: String?) -> Date? {
        guard let token, let segment = token.split(separator: ".").dropFirst().first else { return nil }
        var b64 = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder > 0 { b64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    var accessTokenExpiresAt: Date? {
        Self.jwtExpiry(decodedSessionCredentials?["access_token"] as? String)
    }

    var refreshTokenExpiresAt: Date? {
        Self.jwtExpiry(decodedSessionCredentials?["refresh_token"] as? String)
            ?? Self.jwtExpiry(decodedSessionCredentials?["refreshToken"] as? String)
    }

    /// 会话健康度三态。
    enum SessionHealth: String, CaseIterable {
        /// access_token 仍有效，切过去立即可用。
        case healthy
        /// access_token 已过期，但 refresh_token 仍有效，桌面端会在启动时续发新 access_token。
        case refreshable
        /// 没有任何可用令牌（无会话 / refresh 已死），静默换号必然失败。
        case dead
    }

    var sessionHealth: SessionHealth {
        let now = Date()
        if let at = accessTokenExpiresAt, at > now { return .healthy }
        if let rt = refreshTokenExpiresAt, rt > now { return .refreshable }
        return .dead
    }

    /// 该账号能否被静默换号真正切过去（令牌未全死）。这是 silentReady 候选的真实判据，
    /// 取代「只看过没存过会话缓存」的粗判据。
    var isSilentlySwitchable: Bool {
        hasSwitchableSession && sessionHealth != .dead
    }

    var sessionHealthTitle: String {
        switch sessionHealth {
        case .healthy: "会话有效"
        case .refreshable: "刷新令牌有效"
        case .dead: "会话已失效"
        }
    }

    var sessionHealthColor: Color {
        switch sessionHealth {
        case .healthy: .green
        case .refreshable: .orange
        case .dead: .red
        }
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
            monthlyLimit: QuotaCycleEngine.defaultWeeklyLimit,
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
