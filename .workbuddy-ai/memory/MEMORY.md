# Typeless Switchboard 项目长期记忆

## 工作区基线
- 当前 worktree: `workbuddy/main-fb72c3e3`（分支基于 `origin/main`）
- Swift 6.3.3 / macOS 14+ Package；三个 target：TypelessSwitchboard（App）、
  TypelessSwitchboardCore（纯逻辑）、OperationalFeatureChecks / AutomationSmokeChecks
- 工程历史 commit 模式：feat/fix/docs 三类，无 refactor / chore 提交

## v2 全面升级（2026-08-28 起）
完整计划在 `docs/v2-upgrade-plan.md`，6 阶段 + 多 worktree 并行：
1. **v2.0.0 数据安全** ✅ 已 commit 9abe890
2. **v2.1.0 周度复活** ✅ 已 commit 9abe890
3. v2.2.0 UI 重构（5 tab）
4. v2.3.0 图标（CC0 / MIT 选一个，做 .icns）
5. v2.4.0 测试改革（删 125 条源串包含 + 加 ≥80 条真实断言）
6. v2.5.0 架构拆分（main.swift 7497 → 模块化）

## v2.0.0 / v2.1.0 关键代码定位
- `Sources/TypelessSwitchboardCore/QuotaCycleEngine.swift`：纯函数引擎
  - `daysUntilReset` / `secondsUntilReset` / `nextCalendarWeekReset`
  - `shouldRevive` / `hasCrossedWeeklyBoundary` / `revivedAccounts`
  - `pickNext` 优先级：复活 > 静默就绪 + 余额最多 > nil
  - `AccountQuotaSnapshot` 是 Core 与 App 的解耦类型
  - **复活严格基于 status == .exhausted**，.paused / .pending 不被自动复活
- `Sources/TypelessSwitchboard/main.swift:419-445` P0-2 修复：do/catch + 损坏备份
- `Sources/TypelessSwitchboard/main.swift:5408-5435` P0-1 修复：硬编码用户路径已删
- `Sources/TypelessSwitchboard/main.swift:1482-1530` `reviveExpiredAccountsIfNeeded`
  在 `syncActiveAppSessionAndQuota` 入口被调用（v2.1.0 接线点）
- 复用 `AccountStore.smartSwitchCandidates` 走原 `SmartSwitchPolicy.decide` 路径，
  无需改 decide() 内部（Core 边界保护）

## Typeless 服务端真相
- 官方 `/user/usage_stats` 返回 `week_word_usage_value` / `week_word_usage_limit`
  见 `scripts/extract-active-session.js:155`
- 周度不是月度：周一 00:00 本地时区刷新
- 周刷新还顺带返回 `total_words` / `total_audio_seconds`，可推算语速（≈137–205 字/分）
- 设备登录用户数超限 = 「本 deviceId 挂过多账号」→ 必须 `resetDevice` 才能继续

## 工程注意点
- `main.swift` 7497 行，混居 8 类职责（架构拆分 v2.5.0 任务）
- `Account` 在 main.swift:104；`AccountStatus` 在 main.swift:33
- `PersistedState` 在 main.swift:336（**新增字段必须兼容旧 JSON**）
- `AccountStore.fileURL` 默认 `~/Library/Application Support/TypelessSwitchboard/store.json`
- Keychain 仅保存 MoeMail API Key + 各账号强密码；store.json 不存密码

## 用户偏好
- 自用工具，权限全开，不在 UI/文档里塞无关安全门槛
- 极度强调"稳定是基础" + "100% 强大稳定"
- 喜欢多智能体/多 worktree 并行
- 沟通风格：直接给可执行结论 + 命令，催了就立刻开干
