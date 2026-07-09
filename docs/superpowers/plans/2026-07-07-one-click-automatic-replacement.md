# One-click Automatic Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a one-click automatic replacement workflow that creates a new MoeMail-backed Typeless account, stores its password, extracts email verification codes, drives browser registration where possible, and switches to the new account.

**Architecture:** Put deterministic automation models in `TypelessSwitchboardCore`; keep network, Keychain, file, Process, and SwiftUI orchestration in `Sources/TypelessSwitchboard/main.swift`. Verify via the existing executable acceptance target because this Command Line Tools installation does not provide XCTest or Swift Testing modules.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Security Keychain, MoeMail REST API, optional Playwright via `npx playwright`.

## Global Constraints

- macOS 13 minimum stays unchanged.
- Do not write MoeMail API keys or raw passwords to README, scripts, logs, or JSON exports.
- Passwords are stored in macOS Keychain; app state stores only a password hint.
- If browser automation cannot complete, leave a recoverable state and copy the next useful value to clipboard.
- No XCTest/Testing dependency because current `/Library/Developer/CommandLineTools` lacks those modules.

---

### Task 1: Core automation models and acceptance checks

**Files:**
- Modify: `/Users/fucaixie/BC/Typeless/Sources/TypelessSwitchboardCore/OperationalModels.swift`
- Modify: `/Users/fucaixie/BC/Typeless/Tests/OperationalFeatureChecks/main.swift`

**Interfaces:**
- Produces: `VerificationCodeExtractor.extract(from:) -> String?`
- Produces: `BrowserAutomationScriptBuilder.makeRegistrationScript(input:) -> String`
- Produces: `RegistrationAutomationResult.markdown`

- [x] Add failing acceptance checks for code extraction, script generation, and redacted result markdown.
- [x] Run `./scripts/test-operational-features.sh` and confirm it fails because new symbols do not exist.
- [x] Add the minimal core models and functions.
- [x] Run `./scripts/test-operational-features.sh` and confirm it passes.

### Task 2: Keychain account password support

**Files:**
- Modify: `/Users/fucaixie/BC/Typeless/Sources/TypelessSwitchboard/main.swift`

**Interfaces:**
- Consumes: account email/UUID.
- Produces: `KeychainStore.saveAccountPassword(_:accountID:)`, `KeychainStore.readAccountPassword(accountID:)`.

- [x] Add account-scoped Keychain helpers without changing MoeMail API Key storage.
- [x] Wire generated registration passwords into Keychain.
- [x] Ensure status/log output says “password saved to Keychain” and never prints the raw password.

### Task 3: One-click store workflow

**Files:**
- Modify: `/Users/fucaixie/BC/Typeless/Sources/TypelessSwitchboard/main.swift`

**Interfaces:**
- Consumes: `createMoeMailRegistrationCandidate`, `loadMessages`, `prepareSwitch`, `BrowserAutomationScriptBuilder`.
- Produces: `runOneClickAutomaticReplacement(apiKey:domain:expiryTime:from:) async -> UUID?`.

- [x] Create or select a target replacement account.
- [x] Save password to Keychain.
- [x] Generate Playwright script under Application Support.
- [x] Try to run `npx playwright` script.
- [x] Poll MoeMail messages and extract verification code.
- [x] Mark account approved/available if automation reaches a recoverable or completed state.
- [x] Fall back to clipboard + opened pages when Process execution is unavailable.

### Task 4: UI and docs

**Files:**
- Modify: `/Users/fucaixie/BC/Typeless/Sources/TypelessSwitchboard/main.swift`
- Modify: `/Users/fucaixie/BC/Typeless/README.md`

**Interfaces:**
- Consumes: `runOneClickAutomaticReplacement`.
- Produces: visible “全自动一键换号” controls and status panel.

- [x] Add button to top toolbar and account-pool panel.
- [x] Display last automation result markdown/log summary.
- [x] Document the automatic workflow and fallback behavior.

### Task 5: Final verification

**Files:**
- No code changes expected.

- [x] Run `./scripts/test-operational-features.sh`.
- [x] Run `swift build`.
- [x] Run `./scripts/build-app.sh`.
- [x] Run `plutil -lint TypelessSwitchboard.app/Contents/Info.plist`.
- [x] Run `codesign --verify --deep --strict --verbose=2 TypelessSwitchboard.app`.
- [x] Scan for leaked known keys and TODO/FIXME markers.
