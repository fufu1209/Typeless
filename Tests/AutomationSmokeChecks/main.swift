import Foundation
import Darwin
import TypelessSwitchboardCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func runCommand(_ executable: String, _ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment, currentDirectory: URL? = nil, timeoutSeconds: TimeInterval = 60) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = currentDirectory
    var env = environment
    let pathAdditions = [
        NSHomeDirectory() + "/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]
    let currentPath = env["PATH"] ?? ""
    env["PATH"] = (pathAdditions + currentPath.split(separator: ":").map(String.init))
        .reduce(into: [String]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        .joined(separator: ":")
    process.environment = env
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
        let timedOut = group.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 2)
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: String.Encoding.utf8) ?? ""
        if timedOut {
            return (-9, output + "\nProcess timed out after \(timeoutSeconds)s")
        }
        return (process.terminationStatus, output)
    } catch {
        return (-1, error.localizedDescription)
    }
}

@main
struct AutomationSmokeChecks {
    static func main() throws {
        let timeoutProbe = runCommand("sleep", ["1"], timeoutSeconds: 0.1)
        check(timeoutProbe.status != 0 && timeoutProbe.output.contains("timed out"), "runCommand enforces timeout and reports it")

        let node = runCommand("node", ["--version"])
        check(node.status == 0, "node is available for browser automation smoke: \(node.output)")

        let npm = runCommand("npm", ["--version"])
        check(npm.status == 0, "npm is available for browser automation smoke: \(npm.output)")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeless-automation-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let htmlURL = root.appendingPathComponent("mock-register.html")
        let codeURL = root.appendingPathComponent("code.txt")
        let resultURL = root.appendingPathComponent("result.json")
        let scriptURL = root.appendingPathComponent("automation.js")

        let html = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">发送验证码</button>
            <input name="code" autocomplete="one-time-code" placeholder="验证码" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const email = document.querySelector('input[name="email"]').value;
              const username = document.querySelector('input[name="username"]').value;
              const password = document.querySelector('input[name="password"]').value;
              const code = document.querySelector('input[name="code"]').value;
              if (email && username && password && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1><p>Welcome ' + username + '</p>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try html.write(to: htmlURL, atomically: true, encoding: String.Encoding.utf8)

        let password = "SmokePassword-482913"
        let input = BrowserRegistrationAutomationInput(
            registrationURL: htmlURL.absoluteString,
            email: "smoke@example.com",
            username: "smoke_user",
            password: password,
            verificationCodeFilePath: codeURL.path,
            automationResultFilePath: resultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let script = BrowserAutomationScriptBuilder.makeRegistrationScript(input: input)
        check(!script.contains(password), "smoke script does not write raw password")
        try script.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)

        let syntax = runCommand("node", ["--check", scriptURL.path])
        check(syntax.status == 0, "smoke script passes node --check: \(syntax.output)")
        check(script.contains("await browser.close()"), "smoke script closes Chromium after automation so node can exit")

        let openSessionScriptURL = root.appendingPathComponent("open-retained-session.js")
        let openSessionScript = BrowserAutomationScriptBuilder.makeOpenSessionScript(input: BrowserSessionAutomationInput(
            targetURL: htmlURL.absoluteString,
            browserProfileDirectoryPath: root.appendingPathComponent("retained-session-profile", isDirectory: true).path,
            headless: true
        ))
        check(openSessionScript.contains("chromium.launchPersistentContext"), "open-session smoke script uses persistent browser profile")
        check(openSessionScript.contains("waitForEvent('close')"), "open-session smoke script stays alive for user session")
        try openSessionScript.write(to: openSessionScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let openSessionSyntax = runCommand("node", ["--check", openSessionScriptURL.path])
        check(openSessionSyntax.status == 0, "open-session smoke script passes node --check: \(openSessionSyntax.output)")

        guard ProcessInfo.processInfo.environment["RUN_PLAYWRIGHT_SMOKE"] == "1" else {
            print("Automation smoke quick checks passed; set RUN_PLAYWRIGHT_SMOKE=1 to run full local browser smoke")
            return
        }

        try "{\"private\":true}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: String.Encoding.utf8)
        let installPackage = runCommand("npm", ["install", "--silent", "--no-audit", "--no-fund", "playwright"], currentDirectory: root, timeoutSeconds: 120)
        check(installPackage.status == 0, "playwright package is locally installed for smoke: \(installPackage.output)")
        let installBrowser = runCommand("npm", ["exec", "--", "playwright", "install", "chromium"], currentDirectory: root, timeoutSeconds: 120)
        check(installBrowser.status == 0, "playwright chromium is available: \(installBrowser.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: codeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        var env = ProcessInfo.processInfo.environment
        env["TYPELESS_AUTOMATION_PASSWORD"] = password
        let run = runCommand("node", [scriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(run.status == 0, "smoke Playwright run exits successfully: \(run.output)")

        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: resultData)
        check(result.isLikelyRegistrationComplete, "smoke browser result is likely complete: \(result.summary)")
        check(result.title == "Typeless Dashboard", "smoke final title captured")
        check(result.url.contains("dashboard"), "smoke final URL captured")

        let persistentCodeURL = root.appendingPathComponent("persistent-code.txt")
        let persistentResultURL = root.appendingPathComponent("persistent-result.json")
        let persistentScriptURL = root.appendingPathComponent("persistent-automation.js")
        let persistentProfileURL = root.appendingPathComponent("persistent-profile", isDirectory: true)
        let persistentInput = BrowserRegistrationAutomationInput(
            registrationURL: htmlURL.absoluteString,
            email: "persistent-smoke@example.com",
            username: "persistent_smoke_user",
            password: password,
            verificationCodeFilePath: persistentCodeURL.path,
            automationResultFilePath: persistentResultURL.path,
            browserProfileDirectoryPath: persistentProfileURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let persistentScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: persistentInput)
        check(persistentScript.contains("chromium.launchPersistentContext"), "persistent smoke script uses persistent context")
        try persistentScript.write(to: persistentScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let persistentSyntax = runCommand("node", ["--check", persistentScriptURL.path])
        check(persistentSyntax.status == 0, "persistent smoke script passes node --check: \(persistentSyntax.output)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: persistentCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }
        let persistentRun = runCommand("node", [persistentScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(persistentRun.status == 0, "persistent Playwright run exits successfully: \(persistentRun.output)")
        check(FileManager.default.fileExists(atPath: persistentProfileURL.path), "persistent browser profile directory is created")
        let persistentResultData = try Data(contentsOf: persistentResultURL)
        let persistentResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: persistentResultData)
        check(persistentResult.isLikelyRegistrationComplete, "persistent browser result is likely complete: \(persistentResult.summary)")

        let testIDHTMLURL = root.appendingPathComponent("mock-testid-register.html")
        let testIDCodeURL = root.appendingPathComponent("testid-code.txt")
        let testIDResultURL = root.appendingPathComponent("testid-result.json")
        let testIDScriptURL = root.appendingPathComponent("testid-automation.js")

        let testIDHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input data-testid="signup-email-input" />
            <input data-cy="signup-username-input" />
            <input data-testid="signup-password-input" type="password" />
            <button type="button" data-testid="signup-send-code">→</button>
            <input data-cy="signup-verification-code" />
            <button type="button" data-cy="signup-create-account">✓</button>
          </main>
          <script>
            document.querySelector('[data-testid="signup-send-code"]').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.querySelector('[data-cy="signup-create-account"]').addEventListener('click', () => {
              const email = document.querySelector('[data-testid="signup-email-input"]').value;
              const username = document.querySelector('[data-cy="signup-username-input"]').value;
              const password = document.querySelector('[data-testid="signup-password-input"]').value;
              const code = document.querySelector('[data-cy="signup-verification-code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (email && username && password && codeRequested && code === '482913') {
                document.title = 'Account created';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Account created</h1><p>Dashboard</p>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try testIDHTML.write(to: testIDHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let testIDInput = BrowserRegistrationAutomationInput(
            registrationURL: testIDHTMLURL.absoluteString,
            email: "testid@example.com",
            username: "testid_user",
            password: password,
            verificationCodeFilePath: testIDCodeURL.path,
            automationResultFilePath: testIDResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let testIDScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: testIDInput)
        try testIDScript.write(to: testIDScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let testIDSyntax = runCommand("node", ["--check", testIDScriptURL.path])
        check(testIDSyntax.status == 0, "testid smoke script passes node --check: \(testIDSyntax.output)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: testIDCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }
        let testIDRun = runCommand("node", [testIDScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(testIDRun.status == 0, "testid Playwright run exits successfully: \(testIDRun.output)")
        let testIDResultData = try Data(contentsOf: testIDResultURL)
        let testIDResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: testIDResultData)
        check(testIDResult.isLikelyRegistrationComplete, "testid browser result is likely complete: \(testIDResult.summary)")

        let steppedHTMLURL = root.appendingPathComponent("mock-stepped-register.html")
        let steppedCodeURL = root.appendingPathComponent("stepped-code.txt")
        let steppedResultURL = root.appendingPathComponent("stepped-result.json")
        let steppedScriptURL = root.appendingPathComponent("stepped-automation.js")

        let steppedHTML = """
        <!doctype html>
        <html>
        <head><title>Sign up</title></head>
        <body>
          <main>
            <section id="step-email">
              <h1>Sign up</h1>
              <input name="email" type="email" placeholder="Email" />
              <button type="button" id="continue">Continue</button>
            </section>
            <section id="step-details" hidden>
              <input name="username" autocomplete="username" placeholder="Username" />
              <input name="password" type="password" placeholder="Password" />
              <button type="button" id="send-code">Send code</button>
              <input name="code" autocomplete="one-time-code" placeholder="Code" />
              <button type="submit" id="create-account">Create account</button>
            </section>
          </main>
          <script>
            document.getElementById('continue').addEventListener('click', () => {
              document.getElementById('step-email').hidden = true;
              document.getElementById('step-details').hidden = false;
            });
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const username = document.querySelector('input[name="username"]').value;
              const password = document.querySelector('input[name="password"]').value;
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (username && password && codeRequested && code === '482913') {
                document.title = 'Typeless Workspace';
                history.pushState({}, '', '#/workspace');
                document.body.innerHTML = '<h1>Workspace</h1><p>Welcome ' + username + '</p>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try steppedHTML.write(to: steppedHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let steppedInput = BrowserRegistrationAutomationInput(
            registrationURL: steppedHTMLURL.absoluteString,
            email: "stepped@example.com",
            username: "stepped_user",
            password: password,
            verificationCodeFilePath: steppedCodeURL.path,
            automationResultFilePath: steppedResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let steppedScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: steppedInput)
        try steppedScript.write(to: steppedScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let steppedSyntax = runCommand("node", ["--check", steppedScriptURL.path])
        check(steppedSyntax.status == 0, "stepped smoke script passes node --check: \(steppedSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: steppedCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let steppedRun = runCommand("node", [steppedScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(steppedRun.status == 0, "stepped Playwright run exits successfully: \(steppedRun.output)")

        let steppedResultData = try Data(contentsOf: steppedResultURL)
        let steppedResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: steppedResultData)
        check(steppedResult.isLikelyRegistrationComplete, "stepped browser result is likely complete: \(steppedResult.summary)")
        check(steppedResult.title == "Typeless Workspace", "stepped final title captured")
        check(steppedResult.url.contains("workspace"), "stepped final URL captured")

        let confirmPasswordHTMLURL = root.appendingPathComponent("mock-confirm-password-register.html")
        let confirmPasswordCodeURL = root.appendingPathComponent("confirm-password-code.txt")
        let confirmPasswordResultURL = root.appendingPathComponent("confirm-password-result.json")
        let confirmPasswordScriptURL = root.appendingPathComponent("confirm-password-automation.js")

        let confirmPasswordHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <input name="confirmPassword" type="password" placeholder="Confirm password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const password = document.querySelector('input[name="password"]').value;
              const confirmPassword = document.querySelector('input[name="confirmPassword"]').value;
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (password && confirmPassword === password && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try confirmPasswordHTML.write(to: confirmPasswordHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let confirmPasswordInput = BrowserRegistrationAutomationInput(
            registrationURL: confirmPasswordHTMLURL.absoluteString,
            email: "confirm@example.com",
            username: "confirm_user",
            password: password,
            verificationCodeFilePath: confirmPasswordCodeURL.path,
            automationResultFilePath: confirmPasswordResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let confirmPasswordScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: confirmPasswordInput)
        try confirmPasswordScript.write(to: confirmPasswordScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let confirmPasswordSyntax = runCommand("node", ["--check", confirmPasswordScriptURL.path])
        check(confirmPasswordSyntax.status == 0, "confirm-password smoke script passes node --check: \(confirmPasswordSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: confirmPasswordCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let confirmPasswordRun = runCommand("node", [confirmPasswordScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(confirmPasswordRun.status == 0, "confirm-password Playwright run exits successfully: \(confirmPasswordRun.output)")

        let confirmPasswordResultData = try Data(contentsOf: confirmPasswordResultURL)
        let confirmPasswordResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: confirmPasswordResultData)
        check(confirmPasswordResult.isLikelyRegistrationComplete, "confirm-password browser result is likely complete: \(confirmPasswordResult.summary)")
        check(confirmPasswordResult.title == "Typeless Dashboard", "confirm-password final title captured")
        check(confirmPasswordResult.url.contains("dashboard"), "confirm-password final URL captured")

        let splitCodeHTMLURL = root.appendingPathComponent("mock-split-code-register.html")
        let splitCodeURL = root.appendingPathComponent("split-code.txt")
        let splitCodeResultURL = root.appendingPathComponent("split-code-result.json")
        let splitCodeScriptURL = root.appendingPathComponent("split-code-automation.js")

        let splitCodeHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <div id="otp">
              <input name="otp0" autocomplete="one-time-code" inputmode="numeric" maxlength="1" aria-label="Digit 1" />
              <input name="otp1" autocomplete="one-time-code" inputmode="numeric" maxlength="1" aria-label="Digit 2" />
              <input name="otp2" autocomplete="one-time-code" inputmode="numeric" maxlength="1" aria-label="Digit 3" />
              <input name="otp3" autocomplete="one-time-code" inputmode="numeric" maxlength="1" aria-label="Digit 4" />
              <input name="otp4" autocomplete="one-time-code" inputmode="numeric" maxlength="1" aria-label="Digit 5" />
              <input name="otp5" autocomplete="one-time-code" inputmode="numeric" maxlength="1" aria-label="Digit 6" />
            </div>
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = Array.from(document.querySelectorAll('#otp input')).map(input => input.value).join('');
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try splitCodeHTML.write(to: splitCodeHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let splitCodeInput = BrowserRegistrationAutomationInput(
            registrationURL: splitCodeHTMLURL.absoluteString,
            email: "split@example.com",
            username: "split_user",
            password: password,
            verificationCodeFilePath: splitCodeURL.path,
            automationResultFilePath: splitCodeResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let splitCodeScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: splitCodeInput)
        try splitCodeScript.write(to: splitCodeScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let splitCodeSyntax = runCommand("node", ["--check", splitCodeScriptURL.path])
        check(splitCodeSyntax.status == 0, "split-code smoke script passes node --check: \(splitCodeSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: splitCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let splitCodeRun = runCommand("node", [splitCodeScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(splitCodeRun.status == 0, "split-code Playwright run exits successfully: \(splitCodeRun.output)")

        let splitCodeResultData = try Data(contentsOf: splitCodeResultURL)
        let splitCodeResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: splitCodeResultData)
        check(splitCodeResult.isLikelyRegistrationComplete, "split-code browser result is likely complete: \(splitCodeResult.summary)")
        check(splitCodeResult.title == "Typeless Dashboard", "split-code final title captured")
        check(splitCodeResult.url.contains("dashboard"), "split-code final URL captured")

        let agreementHTMLURL = root.appendingPathComponent("mock-agreement-register.html")
        let agreementCodeURL = root.appendingPathComponent("agreement-code.txt")
        let agreementResultURL = root.appendingPathComponent("agreement-result.json")
        let agreementScriptURL = root.appendingPathComponent("agreement-automation.js")

        let agreementHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <label><input id="terms" type="checkbox" required /> I agree to the Terms and Privacy Policy</label>
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const agreed = document.getElementById('terms').checked;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (agreed && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try agreementHTML.write(to: agreementHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let agreementInput = BrowserRegistrationAutomationInput(
            registrationURL: agreementHTMLURL.absoluteString,
            email: "agreement@example.com",
            username: "agreement_user",
            password: password,
            verificationCodeFilePath: agreementCodeURL.path,
            automationResultFilePath: agreementResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let agreementScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: agreementInput)
        try agreementScript.write(to: agreementScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let agreementSyntax = runCommand("node", ["--check", agreementScriptURL.path])
        check(agreementSyntax.status == 0, "agreement smoke script passes node --check: \(agreementSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: agreementCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let agreementRun = runCommand("node", [agreementScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(agreementRun.status == 0, "agreement Playwright run exits successfully: \(agreementRun.output)")

        let agreementResultData = try Data(contentsOf: agreementResultURL)
        let agreementResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: agreementResultData)
        check(agreementResult.isLikelyRegistrationComplete, "agreement browser result is likely complete: \(agreementResult.summary)")
        check(agreementResult.title == "Typeless Dashboard", "agreement final title captured")
        check(agreementResult.url.contains("dashboard"), "agreement final URL captured")

        let roleButtonHTMLURL = root.appendingPathComponent("mock-role-button-register.html")
        let roleButtonCodeURL = root.appendingPathComponent("role-button-code.txt")
        let roleButtonResultURL = root.appendingPathComponent("role-button-result.json")
        let roleButtonScriptURL = root.appendingPathComponent("role-button-automation.js")

        let roleButtonHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <div role="button" id="send-code" tabindex="0">Send code</div>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <div role="button" id="create-account" tabindex="0">Create account</div>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const email = document.querySelector('input[name="email"]').value;
              const username = document.querySelector('input[name="username"]').value;
              const password = document.querySelector('input[name="password"]').value;
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (email && username && password && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try roleButtonHTML.write(to: roleButtonHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let roleButtonInput = BrowserRegistrationAutomationInput(
            registrationURL: roleButtonHTMLURL.absoluteString,
            email: "role-button@example.com",
            username: "role_button_user",
            password: password,
            verificationCodeFilePath: roleButtonCodeURL.path,
            automationResultFilePath: roleButtonResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let roleButtonScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: roleButtonInput)
        try roleButtonScript.write(to: roleButtonScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let roleButtonSyntax = runCommand("node", ["--check", roleButtonScriptURL.path])
        check(roleButtonSyntax.status == 0, "role-button smoke script passes node --check: \(roleButtonSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: roleButtonCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let roleButtonRun = runCommand("node", [roleButtonScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(roleButtonRun.status == 0, "role-button Playwright run exits successfully: \(roleButtonRun.output)")

        let roleButtonResultData = try Data(contentsOf: roleButtonResultURL)
        let roleButtonResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: roleButtonResultData)
        check(roleButtonResult.isLikelyRegistrationComplete, "role-button browser result is likely complete: \(roleButtonResult.summary)")
        check(roleButtonResult.title == "Typeless Dashboard", "role-button final title captured")
        check(roleButtonResult.url.contains("dashboard"), "role-button final URL captured")

        let roleCheckboxHTMLURL = root.appendingPathComponent("mock-role-checkbox-register.html")
        let roleCheckboxCodeURL = root.appendingPathComponent("role-checkbox-code.txt")
        let roleCheckboxResultURL = root.appendingPathComponent("role-checkbox-result.json")
        let roleCheckboxScriptURL = root.appendingPathComponent("role-checkbox-automation.js")

        let roleCheckboxHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <div id="terms" role="checkbox" aria-checked="false" tabindex="0">I agree to the Terms and Privacy Policy</div>
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('terms').addEventListener('click', () => {
              document.getElementById('terms').setAttribute('aria-checked', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const agreed = document.getElementById('terms').getAttribute('aria-checked') === 'true';
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (agreed && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try roleCheckboxHTML.write(to: roleCheckboxHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let roleCheckboxInput = BrowserRegistrationAutomationInput(
            registrationURL: roleCheckboxHTMLURL.absoluteString,
            email: "role-checkbox@example.com",
            username: "role_checkbox_user",
            password: password,
            verificationCodeFilePath: roleCheckboxCodeURL.path,
            automationResultFilePath: roleCheckboxResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let roleCheckboxScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: roleCheckboxInput)
        try roleCheckboxScript.write(to: roleCheckboxScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let roleCheckboxSyntax = runCommand("node", ["--check", roleCheckboxScriptURL.path])
        check(roleCheckboxSyntax.status == 0, "role-checkbox smoke script passes node --check: \(roleCheckboxSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: roleCheckboxCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let roleCheckboxRun = runCommand("node", [roleCheckboxScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(roleCheckboxRun.status == 0, "role-checkbox Playwright run exits successfully: \(roleCheckboxRun.output)")

        let roleCheckboxResultData = try Data(contentsOf: roleCheckboxResultURL)
        let roleCheckboxResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: roleCheckboxResultData)
        check(roleCheckboxResult.isLikelyRegistrationComplete, "role-checkbox browser result is likely complete: \(roleCheckboxResult.summary)")
        check(roleCheckboxResult.title == "Typeless Dashboard", "role-checkbox final title captured")
        check(roleCheckboxResult.url.contains("dashboard"), "role-checkbox final URL captured")

        let telCodeHTMLURL = root.appendingPathComponent("mock-tel-code-register.html")
        let telCodeURL = root.appendingPathComponent("tel-code.txt")
        let telCodeResultURL = root.appendingPathComponent("tel-code-result.json")
        let telCodeScriptURL = root.appendingPathComponent("tel-code-automation.js")

        let telCodeHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="verification_code" type="tel" placeholder="Security PIN" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="verification_code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try telCodeHTML.write(to: telCodeHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let telCodeInput = BrowserRegistrationAutomationInput(
            registrationURL: telCodeHTMLURL.absoluteString,
            email: "tel-code@example.com",
            username: "tel_code_user",
            password: password,
            verificationCodeFilePath: telCodeURL.path,
            automationResultFilePath: telCodeResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let telCodeScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: telCodeInput)
        try telCodeScript.write(to: telCodeScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let telCodeSyntax = runCommand("node", ["--check", telCodeScriptURL.path])
        check(telCodeSyntax.status == 0, "tel-code smoke script passes node --check: \(telCodeSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: telCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let telCodeRun = runCommand("node", [telCodeScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(telCodeRun.status == 0, "tel-code Playwright run exits successfully: \(telCodeRun.output)")

        let telCodeResultData = try Data(contentsOf: telCodeResultURL)
        let telCodeResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: telCodeResultData)
        check(telCodeResult.isLikelyRegistrationComplete, "tel-code browser result is likely complete: \(telCodeResult.summary)")
        check(telCodeResult.title == "Typeless Dashboard", "tel-code final title captured")
        check(telCodeResult.url.contains("dashboard"), "tel-code final URL captured")

        let delayedSuccessHTMLURL = root.appendingPathComponent("mock-delayed-success-register.html")
        let delayedSuccessCodeURL = root.appendingPathComponent("delayed-success-code.txt")
        let delayedSuccessResultURL = root.appendingPathComponent("delayed-success-result.json")
        let delayedSuccessScriptURL = root.appendingPathComponent("delayed-success-automation.js")

        let delayedSuccessHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Creating workspace...';
                setTimeout(() => {
                  document.title = 'Typeless Dashboard';
                  history.pushState({}, '', '#/dashboard');
                  document.body.innerHTML = '<h1>Dashboard</h1>';
                }, 1500);
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try delayedSuccessHTML.write(to: delayedSuccessHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let delayedSuccessInput = BrowserRegistrationAutomationInput(
            registrationURL: delayedSuccessHTMLURL.absoluteString,
            email: "delayed-success@example.com",
            username: "delayed_success_user",
            password: password,
            verificationCodeFilePath: delayedSuccessCodeURL.path,
            automationResultFilePath: delayedSuccessResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let delayedSuccessScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: delayedSuccessInput)
        try delayedSuccessScript.write(to: delayedSuccessScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let delayedSuccessSyntax = runCommand("node", ["--check", delayedSuccessScriptURL.path])
        check(delayedSuccessSyntax.status == 0, "delayed-success smoke script passes node --check: \(delayedSuccessSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: delayedSuccessCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let delayedSuccessRun = runCommand("node", [delayedSuccessScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(delayedSuccessRun.status == 0, "delayed-success Playwright run exits successfully: \(delayedSuccessRun.output)")

        let delayedSuccessResultData = try Data(contentsOf: delayedSuccessResultURL)
        let delayedSuccessResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: delayedSuccessResultData)
        check(delayedSuccessResult.isLikelyRegistrationComplete, "delayed-success browser result is likely complete: \(delayedSuccessResult.summary)")
        check(delayedSuccessResult.title == "Typeless Dashboard", "delayed-success final title captured")
        check(delayedSuccessResult.url.contains("dashboard"), "delayed-success final URL captured")

        let ariaLabelHTMLURL = root.appendingPathComponent("mock-aria-label-register.html")
        let ariaLabelCodeURL = root.appendingPathComponent("aria-label-code.txt")
        let ariaLabelResultURL = root.appendingPathComponent("aria-label-result.json")
        let ariaLabelScriptURL = root.appendingPathComponent("aria-label-automation.js")

        let ariaLabelHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input id="email-address-field" type="text" aria-label="Email address" />
            <input id="display-name-field" type="text" aria-label="Username" />
            <input id="new-password-field" type="password" aria-label="New password" />
            <button type="button" id="send-code">Send code</button>
            <input id="verification-code-field" type="text" aria-label="Verification code" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const email = document.getElementById('email-address-field').value;
              const username = document.getElementById('display-name-field').value;
              const password = document.getElementById('new-password-field').value;
              const code = document.getElementById('verification-code-field').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (email && username && password && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try ariaLabelHTML.write(to: ariaLabelHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let ariaLabelInput = BrowserRegistrationAutomationInput(
            registrationURL: ariaLabelHTMLURL.absoluteString,
            email: "aria-label@example.com",
            username: "aria_label_user",
            password: password,
            verificationCodeFilePath: ariaLabelCodeURL.path,
            automationResultFilePath: ariaLabelResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let ariaLabelScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: ariaLabelInput)
        try ariaLabelScript.write(to: ariaLabelScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let ariaLabelSyntax = runCommand("node", ["--check", ariaLabelScriptURL.path])
        check(ariaLabelSyntax.status == 0, "aria-label smoke script passes node --check: \(ariaLabelSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: ariaLabelCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let ariaLabelRun = runCommand("node", [ariaLabelScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(ariaLabelRun.status == 0, "aria-label Playwright run exits successfully: \(ariaLabelRun.output)")

        let ariaLabelResultData = try Data(contentsOf: ariaLabelResultURL)
        let ariaLabelResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: ariaLabelResultData)
        check(ariaLabelResult.isLikelyRegistrationComplete, "aria-label browser result is likely complete: \(ariaLabelResult.summary)")
        check(ariaLabelResult.title == "Typeless Dashboard", "aria-label final title captured")
        check(ariaLabelResult.url.contains("dashboard"), "aria-label final URL captured")

        let staleNoCodeHTMLURL = root.appendingPathComponent("mock-stale-no-code-register.html")
        let staleNoCodeURL = root.appendingPathComponent("stale-no-code.txt")
        let staleNoCodeResultURL = root.appendingPathComponent("stale-no-code-result.json")
        let staleNoCodeScriptURL = root.appendingPathComponent("stale-no-code-automation.js")

        let staleNoCodeHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try staleNoCodeHTML.write(to: staleNoCodeHTMLURL, atomically: true, encoding: String.Encoding.utf8)
        try "NO_CODE".write(to: staleNoCodeURL, atomically: true, encoding: String.Encoding.utf8)

        let staleNoCodeInput = BrowserRegistrationAutomationInput(
            registrationURL: staleNoCodeHTMLURL.absoluteString,
            email: "stale-no-code@example.com",
            username: "stale_no_code_user",
            password: password,
            verificationCodeFilePath: staleNoCodeURL.path,
            automationResultFilePath: staleNoCodeResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let staleNoCodeScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: staleNoCodeInput)
        try staleNoCodeScript.write(to: staleNoCodeScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let staleNoCodeSyntax = runCommand("node", ["--check", staleNoCodeScriptURL.path])
        check(staleNoCodeSyntax.status == 0, "stale-no-code smoke script passes node --check: \(staleNoCodeSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: staleNoCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let staleNoCodeRun = runCommand("node", [staleNoCodeScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(staleNoCodeRun.status == 0, "stale-no-code Playwright run exits successfully: \(staleNoCodeRun.output)")

        let staleNoCodeResultData = try Data(contentsOf: staleNoCodeResultURL)
        let staleNoCodeResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: staleNoCodeResultData)
        check(staleNoCodeResult.isLikelyRegistrationComplete, "stale-no-code browser result is likely complete: \(staleNoCodeResult.summary)")
        check(staleNoCodeResult.title == "Typeless Dashboard", "stale-no-code final title captured")
        check(staleNoCodeResult.url.contains("dashboard"), "stale-no-code final URL captured")

        let labeledFieldsHTMLURL = root.appendingPathComponent("mock-labeled-fields-register.html")
        let labeledFieldsCodeURL = root.appendingPathComponent("labeled-fields-code.txt")
        let labeledFieldsResultURL = root.appendingPathComponent("labeled-fields-result.json")
        let labeledFieldsScriptURL = root.appendingPathComponent("labeled-fields-automation.js")

        let labeledFieldsHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <label for="field-a">Email address</label>
            <input id="field-a" type="text" />
            <label for="field-b">Username</label>
            <input id="field-b" type="text" />
            <label for="field-c">New password</label>
            <input id="field-c" type="text" />
            <button type="button" id="send-code">Send code</button>
            <label for="field-d">Verification code</label>
            <input id="field-d" type="text" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const email = document.getElementById('field-a').value;
              const username = document.getElementById('field-b').value;
              const password = document.getElementById('field-c').value;
              const code = document.getElementById('field-d').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (email && username && password && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try labeledFieldsHTML.write(to: labeledFieldsHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let labeledFieldsInput = BrowserRegistrationAutomationInput(
            registrationURL: labeledFieldsHTMLURL.absoluteString,
            email: "labeled-fields@example.com",
            username: "labeled_fields_user",
            password: password,
            verificationCodeFilePath: labeledFieldsCodeURL.path,
            automationResultFilePath: labeledFieldsResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let labeledFieldsScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: labeledFieldsInput)
        try labeledFieldsScript.write(to: labeledFieldsScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let labeledFieldsSyntax = runCommand("node", ["--check", labeledFieldsScriptURL.path])
        check(labeledFieldsSyntax.status == 0, "labeled-fields smoke script passes node --check: \(labeledFieldsSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: labeledFieldsCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let labeledFieldsRun = runCommand("node", [labeledFieldsScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(labeledFieldsRun.status == 0, "labeled-fields Playwright run exits successfully: \(labeledFieldsRun.output)")

        let labeledFieldsResultData = try Data(contentsOf: labeledFieldsResultURL)
        let labeledFieldsResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: labeledFieldsResultData)
        check(labeledFieldsResult.isLikelyRegistrationComplete, "labeled-fields browser result is likely complete: \(labeledFieldsResult.summary)")
        check(labeledFieldsResult.title == "Typeless Dashboard", "labeled-fields final title captured")
        check(labeledFieldsResult.url.contains("dashboard"), "labeled-fields final URL captured")

        let cookieBannerHTMLURL = root.appendingPathComponent("mock-cookie-banner-register.html")
        let cookieBannerCodeURL = root.appendingPathComponent("cookie-banner-code.txt")
        let cookieBannerResultURL = root.appendingPathComponent("cookie-banner-result.json")
        let cookieBannerScriptURL = root.appendingPathComponent("cookie-banner-automation.js")

        let cookieBannerHTML = """
        <!doctype html>
        <html>
        <head>
          <title>Create account</title>
          <style>
            #cookie-banner {
              position: fixed;
              inset: 0;
              z-index: 9999;
              background: rgba(255,255,255,0.96);
              display: flex;
              align-items: center;
              justify-content: center;
              flex-direction: column;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <aside id="cookie-banner">
            <p>We use cookies to improve Typeless.</p>
            <button type="button" id="accept-cookies">Accept all</button>
          </aside>
          <script>
            document.getElementById('accept-cookies').addEventListener('click', () => {
              document.getElementById('cookie-banner').remove();
            });
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try cookieBannerHTML.write(to: cookieBannerHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let cookieBannerInput = BrowserRegistrationAutomationInput(
            registrationURL: cookieBannerHTMLURL.absoluteString,
            email: "cookie-banner@example.com",
            username: "cookie_banner_user",
            password: password,
            verificationCodeFilePath: cookieBannerCodeURL.path,
            automationResultFilePath: cookieBannerResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let cookieBannerScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: cookieBannerInput)
        try cookieBannerScript.write(to: cookieBannerScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let cookieBannerSyntax = runCommand("node", ["--check", cookieBannerScriptURL.path])
        check(cookieBannerSyntax.status == 0, "cookie-banner smoke script passes node --check: \(cookieBannerSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: cookieBannerCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let cookieBannerRun = runCommand("node", [cookieBannerScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(cookieBannerRun.status == 0, "cookie-banner Playwright run exits successfully: \(cookieBannerRun.output)")

        let cookieBannerResultData = try Data(contentsOf: cookieBannerResultURL)
        let cookieBannerResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: cookieBannerResultData)
        check(cookieBannerResult.isLikelyRegistrationComplete, "cookie-banner browser result is likely complete: \(cookieBannerResult.summary)")
        check(cookieBannerResult.title == "Typeless Dashboard", "cookie-banner final title captured")
        check(cookieBannerResult.url.contains("dashboard"), "cookie-banner final URL captured")

        let continueThenCodeHTMLURL = root.appendingPathComponent("mock-continue-then-code-register.html")
        let continueThenCodeURL = root.appendingPathComponent("continue-then-code.txt")
        let continueThenCodeResultURL = root.appendingPathComponent("continue-then-code-result.json")
        let continueThenCodeScriptURL = root.appendingPathComponent("continue-then-code-automation.js")

        let continueThenCodeHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <section id="details-step">
              <h1>Create account</h1>
              <input name="email" type="email" placeholder="Email" />
              <input name="username" autocomplete="username" placeholder="Username" />
              <input name="password" type="password" placeholder="Password" />
              <button type="button" id="continue-to-verification">Continue</button>
            </section>
            <section id="verification-step" hidden>
              <button type="button" id="send-code">Send code</button>
              <input name="code" autocomplete="one-time-code" placeholder="Code" />
              <button type="submit" id="create-account">Create account</button>
            </section>
          </main>
          <script>
            document.getElementById('continue-to-verification').addEventListener('click', () => {
              const email = document.querySelector('input[name="email"]').value;
              const username = document.querySelector('input[name="username"]').value;
              const password = document.querySelector('input[name="password"]').value;
              if (email && username && password) {
                document.getElementById('details-step').hidden = true;
                document.getElementById('verification-step').hidden = false;
              }
            });
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try continueThenCodeHTML.write(to: continueThenCodeHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let continueThenCodeInput = BrowserRegistrationAutomationInput(
            registrationURL: continueThenCodeHTMLURL.absoluteString,
            email: "continue-then-code@example.com",
            username: "continue_then_code_user",
            password: password,
            verificationCodeFilePath: continueThenCodeURL.path,
            automationResultFilePath: continueThenCodeResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let continueThenCodeScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: continueThenCodeInput)
        try continueThenCodeScript.write(to: continueThenCodeScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let continueThenCodeSyntax = runCommand("node", ["--check", continueThenCodeScriptURL.path])
        check(continueThenCodeSyntax.status == 0, "continue-then-code smoke script passes node --check: \(continueThenCodeSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: continueThenCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let continueThenCodeRun = runCommand("node", [continueThenCodeScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(continueThenCodeRun.status == 0, "continue-then-code Playwright run exits successfully: \(continueThenCodeRun.output)")

        let continueThenCodeResultData = try Data(contentsOf: continueThenCodeResultURL)
        let continueThenCodeResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: continueThenCodeResultData)
        check(continueThenCodeResult.isLikelyRegistrationComplete, "continue-then-code browser result is likely complete: \(continueThenCodeResult.summary)")
        check(continueThenCodeResult.title == "Typeless Dashboard", "continue-then-code final title captured")
        check(continueThenCodeResult.url.contains("dashboard"), "continue-then-code final URL captured")

        let enterSubmitHTMLURL = root.appendingPathComponent("mock-enter-submit-register.html")
        let enterSubmitCodeURL = root.appendingPathComponent("enter-submit-code.txt")
        let enterSubmitResultURL = root.appendingPathComponent("enter-submit-result.json")
        let enterSubmitScriptURL = root.appendingPathComponent("enter-submit-automation.js")

        let enterSubmitHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.querySelector('input[name="code"]').addEventListener('keydown', event => {
              if (event.key !== 'Enter') return;
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try enterSubmitHTML.write(to: enterSubmitHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let enterSubmitInput = BrowserRegistrationAutomationInput(
            registrationURL: enterSubmitHTMLURL.absoluteString,
            email: "enter-submit@example.com",
            username: "enter_submit_user",
            password: password,
            verificationCodeFilePath: enterSubmitCodeURL.path,
            automationResultFilePath: enterSubmitResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let enterSubmitScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: enterSubmitInput)
        try enterSubmitScript.write(to: enterSubmitScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let enterSubmitSyntax = runCommand("node", ["--check", enterSubmitScriptURL.path])
        check(enterSubmitSyntax.status == 0, "enter-submit smoke script passes node --check: \(enterSubmitSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: enterSubmitCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let enterSubmitRun = runCommand("node", [enterSubmitScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(enterSubmitRun.status == 0, "enter-submit Playwright run exits successfully: \(enterSubmitRun.output)")

        let enterSubmitResultData = try Data(contentsOf: enterSubmitResultURL)
        let enterSubmitResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: enterSubmitResultData)
        check(enterSubmitResult.isLikelyRegistrationComplete, "enter-submit browser result is likely complete: \(enterSubmitResult.summary)")
        check(enterSubmitResult.title == "Typeless Dashboard", "enter-submit final title captured")
        check(enterSubmitResult.url.contains("dashboard"), "enter-submit final URL captured")

        let inputButtonHTMLURL = root.appendingPathComponent("mock-input-button-register.html")
        let inputButtonCodeURL = root.appendingPathComponent("input-button-code.txt")
        let inputButtonResultURL = root.appendingPathComponent("input-button-result.json")
        let inputButtonScriptURL = root.appendingPathComponent("input-button-automation.js")

        let inputButtonHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <input type="button" id="send-code" value="Send code" />
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <input type="submit" id="create-account" value="Create account" />
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try inputButtonHTML.write(to: inputButtonHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let inputButtonInput = BrowserRegistrationAutomationInput(
            registrationURL: inputButtonHTMLURL.absoluteString,
            email: "input-button@example.com",
            username: "input_button_user",
            password: password,
            verificationCodeFilePath: inputButtonCodeURL.path,
            automationResultFilePath: inputButtonResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let inputButtonScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: inputButtonInput)
        try inputButtonScript.write(to: inputButtonScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let inputButtonSyntax = runCommand("node", ["--check", inputButtonScriptURL.path])
        check(inputButtonSyntax.status == 0, "input-button smoke script passes node --check: \(inputButtonSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: inputButtonCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let inputButtonRun = runCommand("node", [inputButtonScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(inputButtonRun.status == 0, "input-button Playwright run exits successfully: \(inputButtonRun.output)")

        let inputButtonResultData = try Data(contentsOf: inputButtonResultURL)
        let inputButtonResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: inputButtonResultData)
        check(inputButtonResult.isLikelyRegistrationComplete, "input-button browser result is likely complete: \(inputButtonResult.summary)")
        check(inputButtonResult.title == "Typeless Dashboard", "input-button final title captured")
        check(inputButtonResult.url.contains("dashboard"), "input-button final URL captured")

        let continueWithEmailHTMLURL = root.appendingPathComponent("mock-continue-with-email-register.html")
        let continueWithEmailCodeURL = root.appendingPathComponent("continue-with-email-code.txt")
        let continueWithEmailResultURL = root.appendingPathComponent("continue-with-email-result.json")
        let continueWithEmailScriptURL = root.appendingPathComponent("continue-with-email-automation.js")

        let continueWithEmailHTML = """
        <!doctype html>
        <html>
        <head><title>Welcome to Typeless</title></head>
        <body>
          <main>
            <section id="entry-step">
              <h1>Welcome to Typeless</h1>
              <button type="button" id="continue-with-email">Continue with email</button>
            </section>
            <section id="register-step" hidden>
              <h1>Create account</h1>
              <input name="email" type="email" placeholder="Email" />
              <input name="username" autocomplete="username" placeholder="Username" />
              <input name="password" type="password" placeholder="Password" />
              <button type="button" id="send-code">Send code</button>
              <input name="code" autocomplete="one-time-code" placeholder="Code" />
              <button type="submit" id="create-account">Create account</button>
            </section>
          </main>
          <script>
            document.getElementById('continue-with-email').addEventListener('click', () => {
              document.getElementById('entry-step').hidden = true;
              document.getElementById('register-step').hidden = false;
              document.title = 'Create account';
            });
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try continueWithEmailHTML.write(to: continueWithEmailHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let continueWithEmailInput = BrowserRegistrationAutomationInput(
            registrationURL: continueWithEmailHTMLURL.absoluteString,
            email: "continue-with-email@example.com",
            username: "continue_with_email_user",
            password: password,
            verificationCodeFilePath: continueWithEmailCodeURL.path,
            automationResultFilePath: continueWithEmailResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let continueWithEmailScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: continueWithEmailInput)
        try continueWithEmailScript.write(to: continueWithEmailScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let continueWithEmailSyntax = runCommand("node", ["--check", continueWithEmailScriptURL.path])
        check(continueWithEmailSyntax.status == 0, "continue-with-email smoke script passes node --check: \(continueWithEmailSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: continueWithEmailCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let continueWithEmailRun = runCommand("node", [continueWithEmailScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(continueWithEmailRun.status == 0, "continue-with-email Playwright run exits successfully: \(continueWithEmailRun.output)")

        let continueWithEmailResultData = try Data(contentsOf: continueWithEmailResultURL)
        let continueWithEmailResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: continueWithEmailResultData)
        check(continueWithEmailResult.isLikelyRegistrationComplete, "continue-with-email browser result is likely complete: \(continueWithEmailResult.summary)")
        check(continueWithEmailResult.title == "Typeless Dashboard", "continue-with-email final title captured")
        check(continueWithEmailResult.url.contains("dashboard"), "continue-with-email final URL captured")

        let linkControlsHTMLURL = root.appendingPathComponent("mock-link-controls-register.html")
        let linkControlsCodeURL = root.appendingPathComponent("link-controls-code.txt")
        let linkControlsResultURL = root.appendingPathComponent("link-controls-result.json")
        let linkControlsScriptURL = root.appendingPathComponent("link-controls-automation.js")

        let linkControlsHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <a href="#" id="send-code">Send code</a>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <a href="#" id="create-account">Create account</a>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', event => {
              event.preventDefault();
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', event => {
              event.preventDefault();
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try linkControlsHTML.write(to: linkControlsHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let linkControlsInput = BrowserRegistrationAutomationInput(
            registrationURL: linkControlsHTMLURL.absoluteString,
            email: "link-controls@example.com",
            username: "link_controls_user",
            password: password,
            verificationCodeFilePath: linkControlsCodeURL.path,
            automationResultFilePath: linkControlsResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let linkControlsScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: linkControlsInput)
        try linkControlsScript.write(to: linkControlsScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let linkControlsSyntax = runCommand("node", ["--check", linkControlsScriptURL.path])
        check(linkControlsSyntax.status == 0, "link-controls smoke script passes node --check: \(linkControlsSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: linkControlsCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let linkControlsRun = runCommand("node", [linkControlsScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(linkControlsRun.status == 0, "link-controls Playwright run exits successfully: \(linkControlsRun.output)")

        let linkControlsResultData = try Data(contentsOf: linkControlsResultURL)
        let linkControlsResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: linkControlsResultData)
        check(linkControlsResult.isLikelyRegistrationComplete, "link-controls browser result is likely complete: \(linkControlsResult.summary)")
        check(linkControlsResult.title == "Typeless Dashboard", "link-controls final title captured")
        check(linkControlsResult.url.contains("dashboard"), "link-controls final URL captured")

        let hiddenDuplicateHTMLURL = root.appendingPathComponent("mock-hidden-duplicate-register.html")
        let hiddenDuplicateCodeURL = root.appendingPathComponent("hidden-duplicate-code.txt")
        let hiddenDuplicateResultURL = root.appendingPathComponent("hidden-duplicate-result.json")
        let hiddenDuplicateScriptURL = root.appendingPathComponent("hidden-duplicate-automation.js")

        let hiddenDuplicateHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <div id="unused-template" hidden>
            <input name="email" type="email" placeholder="Email" autocomplete="email" />
            <input name="username" placeholder="Username" autocomplete="username" />
            <input name="password" type="password" placeholder="Password" autocomplete="new-password" />
            <input name="code" placeholder="Code" autocomplete="one-time-code" />
          </div>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <button type="submit" id="create-account">Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const visibleInputs = document.querySelectorAll('main input');
              const email = visibleInputs[0].value;
              const username = visibleInputs[1].value;
              const password = visibleInputs[2].value;
              const code = visibleInputs[3].value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (email && username && password && codeRequested && code === '482913') {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try hiddenDuplicateHTML.write(to: hiddenDuplicateHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let hiddenDuplicateInput = BrowserRegistrationAutomationInput(
            registrationURL: hiddenDuplicateHTMLURL.absoluteString,
            email: "hidden-duplicate@example.com",
            username: "hidden_duplicate_user",
            password: password,
            verificationCodeFilePath: hiddenDuplicateCodeURL.path,
            automationResultFilePath: hiddenDuplicateResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let hiddenDuplicateScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: hiddenDuplicateInput)
        try hiddenDuplicateScript.write(to: hiddenDuplicateScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let hiddenDuplicateSyntax = runCommand("node", ["--check", hiddenDuplicateScriptURL.path])
        check(hiddenDuplicateSyntax.status == 0, "hidden-duplicate smoke script passes node --check: \(hiddenDuplicateSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: hiddenDuplicateCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let hiddenDuplicateRun = runCommand("node", [hiddenDuplicateScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(hiddenDuplicateRun.status == 0, "hidden-duplicate Playwright run exits successfully: \(hiddenDuplicateRun.output)")

        let hiddenDuplicateResultData = try Data(contentsOf: hiddenDuplicateResultURL)
        let hiddenDuplicateResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: hiddenDuplicateResultData)
        check(hiddenDuplicateResult.isLikelyRegistrationComplete, "hidden-duplicate browser result is likely complete: \(hiddenDuplicateResult.summary)")
        check(hiddenDuplicateResult.title == "Typeless Dashboard", "hidden-duplicate final title captured")
        check(hiddenDuplicateResult.url.contains("dashboard"), "hidden-duplicate final URL captured")

        let delayedEnableHTMLURL = root.appendingPathComponent("mock-delayed-enable-register.html")
        let delayedEnableCodeURL = root.appendingPathComponent("delayed-enable-code.txt")
        let delayedEnableResultURL = root.appendingPathComponent("delayed-enable-result.json")
        let delayedEnableScriptURL = root.appendingPathComponent("delayed-enable-automation.js")

        let delayedEnableHTML = """
        <!doctype html>
        <html>
        <head><title>Create account</title></head>
        <body>
          <main>
            <h1>Create account</h1>
            <input name="email" type="email" placeholder="Email" />
            <input name="username" autocomplete="username" placeholder="Username" />
            <input name="password" type="password" placeholder="Password" />
            <button type="button" id="send-code">Send code</button>
            <input name="code" autocomplete="one-time-code" placeholder="Code" />
            <button type="submit" id="create-account" disabled>Create account</button>
          </main>
          <script>
            document.getElementById('send-code').addEventListener('click', () => {
              document.body.setAttribute('data-code-requested', 'true');
            });
            document.querySelector('input[name="code"]').addEventListener('input', () => {
              setTimeout(() => {
                document.getElementById('create-account').disabled = false;
              }, 800);
            });
            document.getElementById('create-account').addEventListener('click', () => {
              const code = document.querySelector('input[name="code"]').value;
              const codeRequested = document.body.getAttribute('data-code-requested') === 'true';
              if (codeRequested && code === '482913' && !document.getElementById('create-account').disabled) {
                document.title = 'Typeless Dashboard';
                history.pushState({}, '', '#/dashboard');
                document.body.innerHTML = '<h1>Dashboard</h1>';
              } else {
                document.title = 'Verification failed';
              }
            });
          </script>
        </body>
        </html>
        """
        try delayedEnableHTML.write(to: delayedEnableHTMLURL, atomically: true, encoding: String.Encoding.utf8)

        let delayedEnableInput = BrowserRegistrationAutomationInput(
            registrationURL: delayedEnableHTMLURL.absoluteString,
            email: "delayed-enable@example.com",
            username: "delayed_enable_user",
            password: password,
            verificationCodeFilePath: delayedEnableCodeURL.path,
            automationResultFilePath: delayedEnableResultURL.path,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD",
            headless: true
        )
        let delayedEnableScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: delayedEnableInput)
        try delayedEnableScript.write(to: delayedEnableScriptURL, atomically: true, encoding: String.Encoding.utf8)
        let delayedEnableSyntax = runCommand("node", ["--check", delayedEnableScriptURL.path])
        check(delayedEnableSyntax.status == 0, "delayed-enable smoke script passes node --check: \(delayedEnableSyntax.output)")

        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            try? "482913".write(to: delayedEnableCodeURL, atomically: true, encoding: String.Encoding.utf8)
        }

        let delayedEnableRun = runCommand("node", [delayedEnableScriptURL.path], environment: env, currentDirectory: root, timeoutSeconds: 120)
        check(delayedEnableRun.status == 0, "delayed-enable Playwright run exits successfully: \(delayedEnableRun.output)")

        let delayedEnableResultData = try Data(contentsOf: delayedEnableResultURL)
        let delayedEnableResult = try JSONDecoder().decode(BrowserAutomationResultPayload.self, from: delayedEnableResultData)
        check(delayedEnableResult.isLikelyRegistrationComplete, "delayed-enable browser result is likely complete: \(delayedEnableResult.summary)")
        check(delayedEnableResult.title == "Typeless Dashboard", "delayed-enable final title captured")
        check(delayedEnableResult.url.contains("dashboard"), "delayed-enable final URL captured")

        print("Automation full browser smoke checks passed")
    }
}
