# 一键自动换新积分账号设计

## 目标

把 Typeless Switchboard 从“人工注册助手”升级为“点击一次，自动准备并尽量完成新账号注册与切换”的工作流。用户点击按钮后，工具自动创建 MoeMail 邮箱、生成账号资料、保存密码、打开/驱动注册页、轮询邮件验证码、提取验证码，并在成功或需要人工兜底时保留完整状态。

## 范围

本次实现聚焦本地 macOS 工具可直接落地的自动化能力：

- 自动生成 MoeMail 邮箱和 Typeless 账号资料。
- 自动保存强密码到 macOS Keychain。
- 自动轮询当前 MoeMail 邮箱邮件并提取 4-8 位验证码。
- 自动生成并尝试运行 Playwright 注册脚本，按常见 input 语义填入 username/email/password/code。
- 如果本机没有 Node/npx 或页面选择器不匹配，工具把邮箱、用户名、密码引用、验证码和脚本路径全部留在状态里，用户可继续人工兜底。
- 注册流程完成后将账号标记为可用，并进入切换流程。

## 架构

核心纯逻辑放入 `TypelessSwitchboardCore`，包括验证码提取、自动化脚本生成和自动化状态模型；SwiftUI 主程序负责 MoeMail API、Keychain、文件写入、Process 调用和界面状态展示。测试通过 `OperationalFeatureChecks` executable target 验证，不依赖当前系统缺失的 XCTest/Testing 模块。

## 关键状态

- `RegistrationAutomationStatus`: idle/running/waitingForCode/codeFound/completed/needsAttention/failed。
- `RegistrationAutomationResult`: 记录账号 ID、邮箱、用户名、验证码、脚本路径、日志和状态。
- `VerificationCodeExtractor`: 从邮件主题、发件人、preview、body 等字段中提取验证码。
- `BrowserAutomationScriptBuilder`: 生成 Playwright JS 脚本。

## UI

新增“全自动一键换号”按钮：

- 在顶部主操作区和右侧账号池工具里可触发。
- 展示最近一次自动化状态和日志。
- 保留已有“准备切换”按钮作为人工/半自动备用。

## 验收

- 验证码提取能从中英文验证码邮件中提取数字码。
- Playwright 脚本包含目标 URL、邮箱、用户名、密码、验证码和点击提交逻辑。
- 自动化结果 markdown 不泄露真实密码，只显示密码已保存到 Keychain。
- `./scripts/test-operational-features.sh` 通过。
- `swift build` 通过。
- `./scripts/build-app.sh` 成功，`.app` 签名校验通过。
