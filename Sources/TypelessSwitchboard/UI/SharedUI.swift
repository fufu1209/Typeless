import SwiftUI
import TypelessSwitchboardCore

// MARK: - 五个主分类
//
// 原来所有控件都堆在侧边栏一个 400 行 VStack 里、以及右侧 680 行嵌套 DisclosureGroup 里，
// 用户反馈「杂乱无章、配置没有分类」。这里把功能面按**用户任务**切成 5 个 tab，
// 每个 tab 只回答一个问题，互不混杂。

enum SwitchboardTab: String, Hashable, CaseIterable, Identifiable {
    case pool
    case rotate
    case quotaGuard
    case registration
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pool: return "账号池"
        case .rotate: return "智能换号"
        case .quotaGuard: return "额度守护"
        case .registration: return "注册与邮箱"
        case .diagnostics: return "自检排障"
        }
    }

    var symbolName: String {
        switch self {
        case .pool: return "person.3.fill"
        case .rotate: return "bolt.horizontal.fill"
        case .quotaGuard: return "shield.lefthalf.filled"
        case .registration: return "envelope.badge.fill"
        case .diagnostics: return "stethoscope"
        }
    }

    /// tabItem 下方的短注解，让每个 tab 的用途一眼可辨。
    var subtitle: String {
        switch self {
        case .pool: return "增删改查 · 导入导出"
        case .rotate: return "切号 · 阈值 · 决策"
        case .quotaGuard: return "开机插件 · 自动巡检"
        case .registration: return "MoeMail · 批量注册"
        case .diagnostics: return "权限 · 日志 · 排障包"
        }
    }
}

// MARK: - 共享小组件

/// 每个 tab 顶部统一的「这一页是干什么的」说明条。
struct TabHeading: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }
}

/// 统一卡片容器：标题 + 可选脚注 + 内容，替代原来层层嵌套的 DisclosureGroup。
struct SettingsCard<Content: View>: View {
    let title: String
    let symbolName: String
    var footnote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbolName)
                .font(.headline)

            content

            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

/// 一行「标签 = 值」的只读信息行，用于状态展示。
struct InfoLine: View {
    let label: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// 一行可换行的提示文本。
struct NoteLine: View {
    let text: String
    var color: Color = .secondary
    var lineLimit: Int = 3

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
