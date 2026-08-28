import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

let defaultDomains = [
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

let typelessOfficialURL = "https://www.typeless.com/"
let typelessDefaultLoginURL = "https://www.typeless.com/login"
let oldTypelessLoginURL = "https://app.typeless.com"
let typelessCredentialTarget = "now.typeless.desktop.deviceIdentifier"
let typelessCredentialAccount = "now.typeless.desktop.security.auth_key"
let typelessLegacyCredentialTarget = "Typeless.deviceIdentifier"
let typelessAutomationPasswordEnvironmentKey = "TYPELESS_AUTOMATION_PASSWORD"
let typelessAppQuitGraceSeconds: TimeInterval = 2.5
let chromeSessionJavaScriptDelaySeconds = 1
