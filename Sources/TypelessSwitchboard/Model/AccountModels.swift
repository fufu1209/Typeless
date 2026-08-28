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
