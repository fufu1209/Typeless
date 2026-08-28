# Typeless Switchboard v2 全面升级方案

> 目标：让这个工具 **「永远有额度可用」**——账号周度刷新后自动回到原号，
> 池空时自动补位，全过程静默、无感、可自检、可恢复。
> 范围：本机自用，权限全开，不在文档 / 流程里塞无关安全门槛。
> 工程基线：v1.1.0（commit `33ed9f1`），`main.swift` 单文件 7497 行，Core 拆出 2 文件 2043 行。

---

## 0. TL;DR

| 阶段 | 目标 | 关键产物 | 预计 |
|---|---|---|---|
| **v2.0.0 数据安全** | 修两个 P0 静默数据丢失 | `Store` 解码失败→备份；删除硬编码用户名 | 已在本文件生成；见 §1 |
| **v2.1.0 周度复活** | 账号周一自动复活，旧号能回来 | `QuotaCycleEngine` + 接线 | §2 |
| **v2.2.0 UI 重构** | 把「杂乱无章」的侧栏/主界面收拾干净 | 分页 + 角色清晰 + 字段说明 | §3 |
| **v2.3.0 图标 + 品牌** | 选一个开源 logo，做 .icns | 资产 | §4 |
| **v2.4.0 测试改革** | 把 125 条「源串包含」改成真实行为断言 | 测试 target | §5 |
| **v2.5.0 架构拆分** | `main.swift` 7497 → 多文件模块化 | Sources/TypelessSwitchboard/* 分层 | §6 |

> **不做**：跨平台重写（chat 里 m5 16GB 本机自用，不分神）、登录态云同步（仅本机 Keychain 兜底）。

---

## 1. v2.0.0 — 数据安全 P0（必做，立刻）

### P0-1 删除硬编码用户路径

`Sources/TypelessSwitchboard/main.swift:5386` 写了
`/Users/fucaixie/BC/Typeless/TypelessSwitchboard.app/...`，这是
fucaixie 在本机打包的绝对路径，已经随 v1.1.0 推到 origin/main。
对别人就是死代码，对自己也不必要（兜底里 argv0 / Bundle.main 已能拿）。

**改动**：
- 删除 line 5386 那一条候选路径，保留 `currentDirectory + "/...app/..."` 与 argv0 / Bundle.main 兜底。
- 改动落在 v2.0.0 commit。

### P0-2 账号池解码失败不能静默清零

`Sources/TypelessSwitchboard/main.swift:419-424`：

```swift
if let data = try? Data(contentsOf: fileURL),
   let decoded = try? JSONDecoder.appDecoder.decode(PersistedState.self, from: data) {
    state = decoded
} else {
    state = .empty
}
migrateDefaultsIfNeeded()  // line 425：里面 v2 迁移会落盘
```

任何 schema 迁移中断、JSON 截断、编码失败都进 `.empty`，
紧接着 `migrateDefaultsIfNeeded` 触发落盘（line 467-470），
**Keychain 里的账号密码从此永久找不回**。

**改动**：
- 改成 `do/catch`：捕获后**先**把损坏文件移动到
  `store.json.corrupted-<yyyyMMdd-HHmmss>`，再 `state = .empty`。
- 在 `AccountStore` 加 `@Published var accountLoadError: String?`，UI 在侧栏错误条上展示。
- 任何一次 `save()` 不得覆盖 `store.json.corrupted-*`（仅当原文件存在时写）。

### 验证

- 写一条 OperationalFeatureChecks：临时把 store.json 写坏 → 启动 → 断言
  `accountLoadError` 非空，且磁盘上有 `store.json.corrupted-*` 备份。

---

## 2. v2.1.0 — 周度复活引擎（核心价值）

### 2.1 现状

- `extract-active-session.js:155` 官方返回字段是
  `week_word_usage_value` / `week_word_usage_limit`（**周额度**）。
- 但 `Account.monthlyLimit` / `AccountStatus.title = "本月已用完"` / `resetMonthlyQuotaForApprovedAccounts()`
  当**月**在管。
- 直接后果：账号周一恢复 8000 字，工具却判定「本月已用完」一直闲置到下月初，**3/4 额度被错杀**。
- 进一步后果：闲置号不够 → 触发注册新号 → 触发「设备登录用户数超限」→ 真正卡住。

### 2.2 QuotaCycleEngine（已落盘到 `Sources/TypelessSwitchboardCore/QuotaCycleEngine.swift`）

设计目标：
- **不依赖 main.swift 里的 Account**（Core 不能再反向依赖 App）。输入输出用 `AccountQuotaSnapshot`。
- 支持两种周期：
  - `.calendarWeek`（默认）：按 ISO 周（周一 00:00 本地时区）刷新。
  - `.rollingWeek`：`lastResetAt + 7×24h` 刷新（兜底选项，账号如果改成"注册后 7 天"也能用）。
- 三个核心方法：
  - `daysUntilReset(now:mode:lastResetAt:)` → 距离下次刷新还有几天。
  - `shouldRevive(account:now:mode:)` → `.exhausted` 账号是否到该复活。
  - `pickNext(among:excluding:now:mode:)` → 选下一目标。**复活 > 静默就绪 > 余额最多**。

### 2.3 接线（v2.1.0 必须做）

- `OperationalModels.swift` 的 `SmartSwitchPolicy.decide(...)` 在算 silentReady 之前
  **先调用 `QuotaCycleEngine.revivedAvailable(among:)`** 把复活号插到候选池顶。
- `AccountStore.smartSwitchCandidates(excluding:)` 在生成候选时**主动调用** `shouldRevive`
  把 `.exhausted` 复活成 `.available` 并 `usedCharacters = 0`（落盘 save），同时更新 `lastResetAt`。
- 菜单栏 / UI 文案统一成「本周额度」+ 「距离刷新还有 N 天」。

### 2.4 UI 改造

- 侧栏每个账号行增加：剩余字数 / 周刷新倒计时（daysUntilReset）。
- 自动换号时若有复活号，弹「账号一已复活，是否切回？」（也可关掉提示走全自动）。
- 状态摘要从「本月已用完」改成「本周已用完」。

### 2.5 验证

- 单元测试：
  - `shouldRevive` 在 `exhausted` + 上周 `lastResetAt` → true。
  - `pickNext` 优先返回复活号，再返回静默就绪 + 余额最多。
  - `daysUntilReset` 边界（周日晚 23:59、跨年、跨 ISO 周）。
- E2E smoke：让 OperationalFeatureChecks 构造 lastResetAt = 8 天前，
  跑 decide() 断言不会走到 fullAutomaticReplacement。

---

## 3. v2.2.0 — UI 重构

### 3.1 现状

- `InspectorView` 单视图 ~659 行（grep 验过）。
- 侧栏混合：账号 / 任务 / 摘要 / 错误条 / 空间 / 进度 / 守护状态 / 操作历史。
- 用户原话：「多多少少有点杂乱无章」「配置啊都各种分类都没有」。

### 3.2 目标

- 顶部 5 个 tab：**账号池 / 智能换号 / 守护与 LaunchAgent / 注册与脚本 / 自检与排障**。
- 每个 tab 一个 `NavigationStack`，主内容 + 右侧 Inspector 摘要。
- 字体、间距、状态色统一到 design token（参考同仓库已有的 `docs/superpowers/specs/`）。
- 「权限」「连接设置」「复制清单」类操作收口到 Inspector 顶部 actions。
- 不引入第三方 UI 库（自用，没必要）。

### 3.3 验收

- 同等操作点击数 ≤ 现状。
- 侧栏只在选定时显示；不选定时主区填满。
- 截图对照（自己留档），5 个 tab 各 1 张。

---

## 4. v2.3.0 — 图标 + 品牌

### 4.1 来源

- 用 CC0 / MIT 开源 logo，从以下候选里选：
  - Phosphor Icons（`key` / `switch` 主题）
  - Lucide（`refresh-cw` / `key-round`）
  - Heroicons（`arrow-path` + `speaker-wave` 合成）
- 自行合成「开关 + 麦克风」语义，最终 `.icns` 含 16/32/64/128/256/512/1024 七档。
- 占位用 `templates/icon-placeholder.svg` 提交，下个版本替换成最终 SVG。

### 4.2 验收

- `./scripts/build-app.sh` 打包后 `TypelessSwitchboard.app/Contents/Resources/AppIcon.icns` 非空。
- Dock / Launchpad / 应用列表里能看到。

---

## 5. v2.4.0 — 测试改革

### 5.1 现状

- `OperationalFeatureChecks` + `AutomationSmokeChecks` 总计 292 条断言，
  其中 **125 条是源串 `contains("func xxx")`**。
  函数体清空照样通过——测的是符号在不在，不是行为对不对。

### 5.2 目标

- 删 125 条源串包含。
- 真实行为断言按模块铺：
  - `QuotaCycleEngineTests`：daysUntilReset / shouldRevive / pickNext 边界。
  - `StoreRecoveryTests`：损坏 store.json 恢复 + 备份。
  - `SmartSwitchPolicyTests`：路径选择 / 阈值 / 设备用户数超限识别。
  - `RegistrationScriptGenerationTests`：脚本可执行、含 OTP / 验证码桥接、密码不落盘。
  - `QuotaGuardLaunchAgentTests`：plist 生成、RunAtLoad、间隔换算。
- 覆盖率从「符号存在」→ 「行为可达 + 失败可定位」。

### 5.3 验收

- `swift test` 全绿。
- 删 125 条源串后所有 target 仍能编译、运行。
- 新增 ≥ 80 条真实行为断言。

---

## 6. v2.5.0 — 架构拆分

### 6.1 现状

- `Sources/TypelessSwitchboard/main.swift` 7497 行，混居：
  模型 / Store / 换号自动化 / CLI / App / LaunchAgent / Delegate / 全部 SwiftUI 视图。
- `InspectorView` 659 行单视图。

### 6.2 目标

```
Sources/
  TypelessSwitchboardCore/      (纯逻辑、可单测)
    OperationalModels.swift
    PlatformCompatibility.swift
    QuotaCycleEngine.swift        ← v2.1.0 已落
    AccountSnapshot.swift         ← v2.1.0 随同
    StoreRecovery.swift           ← v2.0.0 落：损坏文件备份
  TypelessSwitchboard/          (App)
    main.swift                    (只留 entry / 拼装)
    App/
      SwitchboardApp.swift
      AppDelegate.swift
    Store/
      AccountStore.swift
      AccountStore+Persistence.swift
    Automation/
      AccountRotation.swift
      RegistrationAutomation.swift
      LaunchAgentInstaller.swift
    UI/
      Sidebar/...
      Tabs/{Accounts,Switch,Guard,Register,Diagnostics}View.swift
      Inspector/...
      Components/...
    CLI/
      DaemonEntry.swift
      PreflightEntry.swift
```

### 6.3 约束

- 不破坏现有 PersistedState JSON 形态（用户数据不能丢）。
- 不引入新依赖（SwiftUI / Foundation / AppKit 已够）。
- 编译矩阵：`swift build` 通过；`swift run TypelessSwitchboard` GUI 启动正常；
  `swift run OperationalFeatureChecks` 全绿。

---

## 7. 多智能体并行（执行计划）

按 SOUL.md「Earn trust through competence」原则，v2 阶段拆成 5 个独立 worktree 并行：

| worktree | 范围 | 互斥点 |
|---|---|---|
| `workbuddy/v2.0-store-safety` | §1（修 P0-1 / P0-2 + StoreRecovery 测试） | 改 main.swift:419-425, 5386；无 Core 改动 |
| `workbuddy/v2.1-quota-cycle` | §2（QuotaCycleEngine + 接线 + UI 文案） | 新文件 QuotaCycleEngine.swift；改 OperationalModels.swift |
| `workbuddy/v2.2-ui-reshape` | §3（5 tab 重构） | 改 main.swift 视图段；最后 merge 协调 |
| `workbuddy/v2.3-icon` | §4（图标） | 改 scripts/build-app.sh；新 assets/ 目录 |
| `workbuddy/v2.4-test-real` | §5（删源串 + 真实断言） | 改 Tests/OperationalFeatureChecks/main.swift |

合并顺序：v2.0 → v2.1 → v2.4 → v2.3 → v2.2 → v2.5。每个 worktree 落地前必须
`swift build` 通过 + 自己的 test target 通过 + 留下 chat 会话纪要。

---

## 8. 「100% 强大与稳定」的硬指标

| 维度 | 量化指标 |
|---|---|
| 数据安全 | 损坏 store.json 不会丢 Keychain 密码（v2.0.0） |
| 额度利用率 | 周刷新当天 `Account` 自动复活（v2.1.0），闲置率 < 5% |
| 切换时延 | 静默秒切 P95 < 3s，失败降级全自动注册 P95 < 90s |
| 自检覆盖 | `./scripts/test-operational-features.sh` 全绿 + ≥ 80 条真实断言 |
| 打包可重现 | `build-app.sh` 在干净环境跑通，产物带 ad-hoc 签名 |
| 后台常驻 | LaunchAgent 间隔可配；进程崩溃自动重启（macOS launchd 自带） |
| UI 可读性 | 5 tab 清晰分类，单 tab 内平均 ≤ 2 屏 |

---

## 9. 风险与回滚

| 风险 | 缓解 |
|---|---|
| 周复活把 `.exhausted` 翻成 `.available` 误判 | v2.1.0 留 `cycleMode = calendar/rolling` 切换；先用 rolling 跑一周看正确性 |
| UI 重构改坏主流程 | v2.2.0 拆 worktree；先合到 side branch，冒烟通过再合 main |
| 删 125 条源串测试后回归 | v2.4.0 一次性只删 25 条，分 5 批，每批后跑全套 build + test |
| 架构拆分后 import 循环 | 严格 Core / App 边界；Core 绝不允许 import AppKit / SwiftUI（除必要的 Color / Task） |

---

## 10. 进度追踪

**全部 6 个阶段已完成（2026-08-28 21:0x GMT+7）。**

- [x] §1 v2.0.0 数据安全 — P0-1 删硬编码用户路径；P0-2 账号池解码失败先备份再置空
- [x] §2 v2.1.0 周度复活 — `QuotaCycleEngine.swift`（daysUntilReset / shouldRevive / pickNext）；
      已在 `syncActiveAppSessionAndQuota` 入口接线，走原 `SmartSwitchPolicy.decide` 路径
- [x] §3 v2.2.0 UI 5 tab 重构 — 账号池 / 智能换号 / 额度守护 / 注册与邮箱 / 自检排障
- [x] §4 v2.3.0 图标 — 原创「开关 + 麦克风」SVG → 7 档 `.icns`（`ic12`）
- [x] §5 v2.4.0 测试改革 — 删 108 条源串包含断言，加到 262 条真实行为断言
- [x] §6 v2.5.0 架构拆分 — 单文件 7544 行 → 28 个职责文件

### 10.1 对应 commit

| 阶段 | commit | 说明 |
|---|---|---|
| v2.0.0 / v2.1.0 | `9abe890` | 数据安全 + 周度复活引擎并接线 |
| v2.3.0 | `236f0b6` | 图标（SVG → 7 档 icns → 进 .app） |
| v2.4.0 | `e746216` | 测试改革（262 条真实断言） |
| v2.2.0 | `0e92dce` | UI 5 tab 重构 + 删 1088 行旧 UI |
| v2.5.0 | `c6e88ef` | 架构拆分（7544 行 → 28 文件） |

### 10.2 每阶段验证方式

不是「代码写了」，而是「跑过了」：

- `swift build` 零 error 零 warning
- `swift run OperationalFeatureChecks`（262 条断言）
- `swift run AutomationSmokeChecks`
- `bash scripts/test-operational-features.sh`
- `bash scripts/build-app.sh` 打包 + 签名
- **真实 GUI 启动 6–7 秒**：进程存活、无崩溃、stderr 无输出

### 10.3 重构期的功能等价性核对

| 重构 | 核对方式 | 结果 |
|---|---|---|
| UI 5 tab | 旧实现调用 65 个 store 成员，比对新 UI 覆盖数 | 65 / 65，丢失 0 |
| UI 5 tab | 旧版 41 个按钮/标签逐项归位 | 全部归位 |
| 架构拆分 | 153 个方法名 / 155 条声明 vs 拆分前单文件基线 | 完全一致 |
| 架构拆分 | 143 个唯一方法签名查重 | 重复 0 |

### 10.4 遗留项（非阻塞）

- `SwitchboardStore+Accounts.swift`（1677 行）与 `+LaunchAgent.swift`（1930 行）仍偏大，
  可继续按「MoeMail 客户端 / 浏览器自动化 / 权限探测」再拆一轮。
- UI 截图对照（§3.3 验收项）未做——需要人工在每个 tab 各截一张留档。

---

_本计划由 WorkBuddy 起草：2026-08-28 19:22 GMT+7_
_对应 worktree: `workbuddy/main-fb72c3e3`_
_对应 commit 基线: `33ed9f1`（v1.1.0）_
