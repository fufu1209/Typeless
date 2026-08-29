import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

/// 账号池首次创建时预填的邮箱域名。
///
/// 这里只放**中性占位值**，不要放任何人的真实域名 ——
/// 这个仓库是公开的，硬编码真实域名等于把自建邮箱服务入口、
/// 以及域名里可能带的姓名/生日信息一并公布出去。
/// 用户在 App「注册与邮箱」页填自己的域名即可，会持久化到 store.json。
let defaultDomains = [
    "example.com"
]

let typelessOfficialURL = "https://www.typeless.com/"
let typelessDefaultLoginURL = "https://www.typeless.com/login"
let oldTypelessLoginURL = "https://app.typeless.com"
let typelessCredentialTarget = "now.typeless.desktop.deviceIdentifier"
let typelessCredentialAccount = "now.typeless.desktop.security.auth_key"
let typelessLegacyCredentialTarget = "Typeless.deviceIdentifier"
let typelessAutomationPasswordEnvironmentKey = "TYPELESS_AUTOMATION_PASSWORD"
let typelessAppQuitGraceSeconds: TimeInterval = 2.5
let chromeSessionJavaScriptDelaySeconds = 1
