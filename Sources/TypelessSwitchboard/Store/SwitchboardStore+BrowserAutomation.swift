import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func prepareRetainedTypelessBrowserSessionsForAutomaticReplacement() async -> [String] {
        var log: [String] = []
        log.append(await terminateRetainedTypelessBrowserSessions())

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


    func resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement() async -> [String] {
        let result = await approveChromeTypelessAppPrompt()
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


    func closePersonalChromeTypelessTabsBeforeReplacement() async -> [String] {
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
        let result = await runInlineAppleScript(
            script,
            label: "close-personal-chrome-typeless-tabs",
            timeoutSeconds: 10
        )
        if result.status == 0 {
            return ["已关闭 Google Chrome 里的旧 Typeless 标签：\(result.output.ifEmpty("closed 0 typeless tabs"))"]
        }
        return ["关闭 Google Chrome 旧 Typeless 标签失败：\(result.output.ifEmpty("退出码 \(result.status)"))"]
    }


    func preparePersonalChromeTypelessWebSessionForAutomaticReplacement() async -> [String] {
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

        let result = await runJavaScriptInPersonalChrome(
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


    func syncPersonalChromeTypelessWebSession(account: Account, profileDirectoryPath: String) async -> [String] {
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

        let syncResult = await runJavaScriptInPersonalChrome(
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
        _ = await runJavaScriptInPersonalChrome(
            openDesktopScript,
            label: "open-typeless-desktop-from-personal-chrome",
            targetURL: "https://www.typeless.com/login/app/success",
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        _ = await approveChromeTypelessAppPrompt()

        return ["已把 Google Chrome 的 Typeless 网页会话切到新账号：\(account.email)"]
    }


    func handoffRetainedTypelessProfileToDesktopOnce(profileDirectoryPath: String, expectedEmail: String) async -> String {
        if let tokenInfo = extractTypelessTokenInfo(fromBrowserProfile: profileDirectoryPath, expectedEmail: expectedEmail),
           let authURL = makeTypelessDesktopAuthURL(fromTokenInfo: tokenInfo) {
            await forceLaunchTypelessBeforeAuthProtocol()
            let firstOpen = await openTypelessAuthProtocol(authURL)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let secondOpen = await openTypelessAuthProtocol(authURL)
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
            // 该脚本会启动 Playwright 并在页面中点击 handoff，可能在后台线程执行，避免冻结主线程。
            let result = await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["node", scriptURL.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: 45
                )
            }.value
            if result.status == 0 {
                return "已后台触发新账号 Typeless 桌面端 handoff：\(result.output.ifEmpty("无输出"))"
            }
            return "后台触发 Typeless 桌面端 handoff 未完成：\(result.output.ifEmpty("退出码 \(result.status)"))"
        } catch {
            return "后台触发 Typeless 桌面端 handoff 失败：\(error.localizedDescription)"
        }
    }


    func forceLaunchTypelessBeforeAuthProtocol() async {
        if let path = typelessAppPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            // 给 Electron 冷启动留时间，但用可取消 sleep，不再硬冻结主线程。
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }


    func openTypelessAuthProtocol(_ authURL: String) async -> Bool {
        let result = await Task.detached(priority: .utility) {
            SwitchboardStore.runProcess(
                arguments: ["open", authURL],
                environment: SwitchboardStore.automationEnvironment(),
                timeoutSeconds: 15
            )
        }.value
        return result.status == 0
    }


    func makeTypelessDesktopAuthURL(fromTokenInfo tokenInfo: String) -> String? {
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


    func makeDesktopHandoffScript(profileDirectoryPath: String) -> String {
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


    func runInlineAppleScript(
        _ appleScript: String,
        label: String,
        timeoutSeconds: TimeInterval
    ) async -> (status: Int32, output: String) {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).applescript")
            try appleScript.write(to: url, atomically: true, encoding: .utf8)
            // osascript 可能被自动化授权弹窗/系统挂起拖住，必须在后台线程执行，避免冻结主线程。
            return await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["osascript", url.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: timeoutSeconds
                )
            }.value
        } catch {
            return (-1, error.localizedDescription)
        }
    }


    func runJavaScriptInPersonalChrome(
        _ javaScript: String,
        label: String,
        targetURL: String,
        delayBeforeJavaScriptSeconds: Int,
        timeoutSeconds: TimeInterval
    ) async -> (status: Int32, output: String) {
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
            // Chrome AppleScript 可能等待页面加载 / 自动化授权，必须在后台线程执行，避免冻结主线程。
            return await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["osascript", appleScriptURL.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: timeoutSeconds
                )
            }.value
        } catch {
            return (-1, error.localizedDescription)
        }
    }


    func approveChromeTypelessAppPrompt() async -> (status: Int32, output: String) {
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
            // 该脚本可能被 Chrome 弹窗 / 自动化授权卡住，必须在后台线程执行，避免冻结主线程。
            return await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["osascript", url.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: 10
                )
            }.value
        } catch {
            return (-1, error.localizedDescription)
        }
    }


    func extractTypelessTokenInfo(fromBrowserProfile profileDirectoryPath: String, expectedEmail: String) -> String? {
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


    nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }


    nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
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


    func accountForLastAutomationResult() -> Account? {
        guard let accountID = state.lastAutomationResult?.accountID,
              let index = accountIndex(id: accountID) else {
            return nil
        }
        return state.accounts[index]
    }


    func openRetainedBrowserSession(profileDirectoryPath: String, targetURL: String) -> String {
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

}
