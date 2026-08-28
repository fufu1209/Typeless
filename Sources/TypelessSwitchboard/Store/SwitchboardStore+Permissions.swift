import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func refreshPermissionCacheIfNeeded(force: Bool = false, probeAppleEvents: Bool = true) {
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

    func appendMacPermissionDiagnostics(to results: inout [DiagnosticItem]) {
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
    func preflightMacPermissionsBeforeAutomaticReplacement(
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

    func openMacPermissionSettingsOnce(_ settingsPaneIdentifier: String, force: Bool = false) {
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
}
