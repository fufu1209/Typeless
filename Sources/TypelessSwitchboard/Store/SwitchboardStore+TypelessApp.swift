import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func macModelIdentifier() -> String {
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

    func typelessAppPath() -> String? {
        let candidates = [
            "/Applications/Typeless.app",
            "\(NSHomeDirectory())/Applications/Typeless.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func typelessExecutablePath() -> String? {
        let candidates = [
            "/Applications/Typeless.app/Contents/MacOS/Typeless",
            "\(NSHomeDirectory())/Applications/Typeless.app/Contents/MacOS/Typeless"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func firstExistingAppSupportPath(_ names: [String]) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in names {
            let url = appSupport.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return appSupport.appendingPathComponent(names.first ?? "Typeless")
    }

    func typelessUserDataDir() -> URL {
        firstExistingAppSupportPath(["Typeless.exe", "Typeless"])
    }

    func typelessDeviceCacheDir() -> URL {
        let candidates = typelessDeviceCacheDirectories()
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    func typelessDeviceCacheDirectories() -> [URL] {
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

    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
