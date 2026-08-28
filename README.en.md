# Typeless Switchboard

**Free unlimited Typeless on macOS** — a native Swift menu bar app that automatically rotates
multiple accounts when the free **8,000 words/week** quota runs low.

[![Platform](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.5.6-blue.svg)](CHANGELOG.md)

> 🌏 [中文版 README](README.md) — the Chinese one is more detailed.

---

## The problem

[Typeless](https://www.typeless.com) is a great voice-to-text app for macOS, but the free plan
gives you only **8,000 words per week**. Once it's gone you have to sign out, sign in with
another account, and walk through the onboarding wizard again — possibly a few times a day.

## What this does

You register a pool of accounts once. When the active account's quota gets low, the tool
**silently switches** to the next one that still has quota:

- **Silent switching** — injects the saved desktop session, no password typing, no onboarding wizard
- **Quota guard** — a lightweight LaunchAgent watches the quota even when the app is closed
- **Batch signup** — creates accounts automatically using a self-hosted catch-all email service
- **Weekly quota tracking** — shows how much is left and when it refills

Everything stays on your machine: accounts live in
`~/Library/Application Support/TypelessSwitchboard/`, passwords in macOS Keychain.
**This repository contains code only — no keys, no passwords, no account data.**

<!-- TODO: add a screenshot / short GIF of the menu bar and the account pool here -->

---

## Quick start

**Requires**: macOS 13+, Xcode Command Line Tools (Swift 6).

```bash
git clone https://github.com/fufu1209/Typeless.git
cd Typeless
./scripts/build-app.sh --install     # installs to /Applications/TypelessSwitchboard.app
open /Applications/TypelessSwitchboard.app
```

Then grant the permissions listed in the app's **Diagnostics** tab
(Accessibility, Automation, Input Monitoring, Microphone, Screen Recording).

**That's it if you already have several Typeless accounts** — add them to the pool and the
tool will rotate them for you.

### Want automatic signup for new accounts?

You'll need an email service that can receive verification codes. Three options:

| Route | Cost | Effort | Notes |
|---|---|---|---|
| [moemail](https://github.com/beilunyang/moemail) (open source) | domain only | ~1 h | Recommended — this tool's API contract matches it |
| ~100-line Cloudflare Worker (code in [DEPLOYMENT.md](docs/DEPLOYMENT.md)) | domain only | ~30 min | Minimal, does exactly what's needed |
| Skip it entirely | free | none | Manual account management still works |

Full walkthrough — buying a domain, DNS on Cloudflare, MX/SPF/DKIM/DMARC records,
deploying the API, and three `curl` commands to verify it works — in
**[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**.

> Run those three `curl` checks **before** going further. Otherwise when signup later says
> "no verification code found", you won't know whether email is broken or the flow is.

### Choosing your email route

```
Do you already have several Typeless accounts?
├─ YES → skip email setup; add accounts manually; rotation works now
└─ NO  → Do you own a domain?
         ├─ YES → deploy moemail or the Worker (see DEPLOYMENT.md)
         └─ NO  → buy one (~$5-10/yr for .xyz), then deploy
```

---

## How the quota cycle works

**Typeless does not document how the weekly quota resets** — the pricing page and billing FAQ
only say "8,000 words per week". So this tool doesn't guess for you. It **observes**:
every time it fetches a fresh quota reading it records a sample; a sharp drop counts as a real
reset. After enough samples it tells you whether resets land on Monday 00:00 or are scattered
across the week.

The Quota Guard tab shows the current verdict honestly — either
*"cycle not yet confirmed (N resets observed)"* or *"confirmed weekly (Monday 00:00), based on N
observations"*. You can also pin the refresh timezone there if your system clock doesn't match
where you actually are; it takes effect immediately, no restart.

---

## Safety notes

- A switch only commits when the browser result **proves** signup succeeded
  (reached a dashboard / success page). Otherwise the new account is kept as
  "needs manual confirmation" and **your current account is left untouched**.
- Generated passwords go straight to macOS Keychain. The pool only stores a
  "saved to Keychain" note, never the password itself.
- Automation scripts don't contain plaintext passwords — they're injected via environment variables.

---

## Docs

- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — from zero to running (domain, DNS, email API)
- [docs/AUTOMATION.md](docs/AUTOMATION.md) — what each step of one-click switching does *(Chinese)*
- [CHANGELOG.md](CHANGELOG.md) — release notes

## Contributing

Issues and PRs welcome. Before opening a PR, please run
`swift run OperationalFeatureChecks` (451 assertions) and
`./scripts/test-browser-automation-smoke.sh`. Never commit real accounts, passwords, or API keys.

## License

[MIT](LICENSE).

Typeless is a third-party product; this project is not affiliated with it. Please respect
[Typeless's terms of service](https://www.typeless.com/terms). Bulk-registering accounts carries
a risk of being rate-limited — use your own judgement.
