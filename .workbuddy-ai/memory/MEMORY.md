# Typeless Switchboard 项目长期记忆

## 工作区基线
- 当前 worktree: `workbuddy/main-fb72c3e3`（分支基于 `origin/main`）
- Swift 6.3.3 / macOS 14+ Package；三个 target：TypelessSwitchboard（App）、
  TypelessSwitchboardCore（纯逻辑）、OperationalFeatureChecks / AutomationSmokeChecks
- 工程历史 commit 模式：feat/fix/docs 三类，无 refactor / chore 提交

## v2 全面升级（2026-08-28 起）
完整计划在 `docs/v2-upgrade-plan.md`
1. v2.0.0 数据安全 ✅ 9abe890
2. v2.1.0 周度复活 ✅ 9abe890
3. v2.2.0 UI 重构（5 tab）✅
4. v2.3.0 图标 ✅
5. v2.4.0 测试改革（删源串包含 + 加真实断言）✅
6. v2.5.0 架构拆分（main.swift 7497 → 模块化）✅
7. **v2.5.3** 新手引导回归修复 + 下次可用接线 + 单实例锁 ✅ aa89300
8. **v2.5.4** 周期看门狗 + 启动自愈引导 + 旧副本清理 ✅ 07f7f54
9. **v2.5.5** 引导补丁补强 + 周期时区可配 + 日志轮转 ✅ **205f5c6（当前版本）**

### v2.5.5 关键代码定位
- `Sources/TypelessSwitchboardCore/QuotaCycleClock.swift`（新）
  周期日历**唯一来源**，NSLock 保护，`.iso8601` 日历天然周一为首日。
  UI 倒计时 / 复活判定 / 看门狗排程三处都取 `QuotaCycleClock.shared.calendar`，
  不再各拿 `Calendar.current`（本机 +0700、用户 +0800 会差 1 小时）
- `Sources/TypelessSwitchboardCore/LogFileRotator.swift`（新）
  **必须原地截断**（seek+write+truncateFile），绝不能 `write(to:atomically:)` 换 inode
  —— launchd 的 stdout 重定向持有老 fd，换文件会让它往已删除的 inode 写
- `Store/SwitchboardStore+OnboardingPatch.swift`
  `desktopOnboardingState()` 三态 `complete/incomplete/missing`；
  `backupDesktopOnboardingFileIfNeeded()` 只留第一份备份；
  自愈写完回读校验；`startOnboardingGuardIfNeeded()` 5 分钟巡检
- `Model/AppSettings.swift` `quotaCycleTimeZoneIdentifier`（空串=跟随系统，老 JSON 无需迁移）
  UI 在 `QuotaGuardTabView` 底部；改完调 `setQuotaCycleTimeZoneIdentifier` 立即生效

### v2.5.4 关键代码定位
- `Store/SwitchboardStore+SmartSwitch.swift`
  - `startQuotaCycleWatchdogIfNeeded()` / `stopQuotaCycleWatchdog()`
    周期看门狗：与 `isAutoRotateEnabled` 解耦，纯本地算 `secondsUntilReset`
    后精确休眠（clamp 到 [60s, 一周]），跨周一自动复活
  - `performWeeklyRevivalIfNeeded(reason:)` 统一复活入口，
    额度同步 / 启动 / 看门狗 / 手动四处都走它，记 lastWeeklyRevivalAt
- `Store/SwitchboardStore+OnboardingPatch.swift`
  - `autoHealDesktopOnboardingIfSafe()` **只在 Typeless 未运行时**静默写盘
    （它运行时写了也会被退出时 flush 内存态覆盖）
  - `refreshDesktopOnboardingState()` / `desktopOnboardingIsIncomplete()`
  - `appendOnboardingPatchLog()` 写 Logs/onboarding-patch.log
- `App/AppDelegate.swift` bind() 里接看门狗 + 自愈；quitApp() 里停看门狗
- `Model/Account+QuotaCycle.swift` Account↔快照唯一桥接点（v2.5.3）
- `App/AppEntry.swift` `SingleInstanceGuard`（flock LOCK_EX\|LOCK_NB）

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

## Typeless 桌面端 onboarding 真相（2.4.0，v2.5.3 实测）
- `~/Library/Application Support/Typeless/app-onboarding.json`
  → **引导向导真正的开关**（isCompleted / step / setUpStep）
  → 本地改得动；Typeless 重启是「合并」不是「重置」，跨重启持久
- `app-storage.json` 的 `userData.is_new_user`
  → **服务端真值**，每次联网同步都被覆盖，本地压不住，不要试图硬压
- 平台枚举 4 → 7：ios/android/macos/windows/**linux**/**harmony**/**webpage**
  macos 节点另带 app_version / completed_at
  → 补丁用「文件已有键 ∪ 官方枚举」，未来加平台自动兼容
- 补丁入口（v2.5.4 共 5 个）：账号详情按钮 / 顶部横幅 / 排障页常驻卡片 /
  CLI `--skip-onboarding` / 无感换号自动 / App 启动自愈
- 日志：`~/Library/Application Support/TypelessSwitchboard/Logs/onboarding-patch.log`
- 完整实测时间线见 `docs/onboarding-patch-truth.md`

## 账号池实况（2026-08-28）
- 18 个账号，全部 `available` + `approved`
- 16/18 带 `rawUserDataPayload`（静默会话缓存），2 个从未登录所以没有
- store.json 里 `monthlyLimit` 是历史字段名，**值 8000 = 每周额度**
- `rawUserDataPayload` 是 optional 字段，统计时必须遍历所有账号取并集，
  只看 accounts[0] 会漏判

## 工程铁律（踩过的坑）
- **验证必须跨越被测对象的重启**：补丁后立刻读文件 = 假阳性，
  必须 quit → relaunch → 等同步完 → 再读
- **功能保真审计只看 store 成员集合，看不出「接线断了」**：
  Core 的 static 方法（QuotaCycleEngine）和调用点语义变化都会漏
- **Spotlight 索引不受 .gitignore 约束**：构建产物必须落在仓库目录之外，
  否则用户会看到「好几个一样的 app」
- 本工程测试是可执行 target 的 main.swift，不是 XCTest
  → `swift test` 报 no tests found，必须 `swift run OperationalFeatureChecks`
- **清理旧 app 后必须用 `mdfind` 复核，不能只 `find`**：
  find 只看文件系统实时状态，Spotlight 索引有延迟/缓存，
  用户看到的「好几个一样的 app」来自索引
  复核命令：`mdfind "kMDItemCFBundleIdentifier == 'local.typeless.switchboard'"`
- **不要轻信用户的「好像只有一个了」**：v2.5.4 时用户这么判断，
  实测 `~/BC/Typeless/TypelessSwitchboard.app` 仍是 1.1.0 旧副本且被索引。
  必须自己跑一遍再回答
- **周期性任务不能只挂在业务回调上**：周额度复活原先只挂在额度同步里，
  守护关掉 / 周末不开 App 就漏跑。凡是「到点必须发生」的逻辑
  都要有独立的看门狗 + 统一的记录入口
- **本机时区是 Asia/Bangkok(+0700)，用户在深圳（+0800）**：
  `readlink /etc/localtime` 实测，不是猜的。v2.5.5 起周期日历统一走
  `QuotaCycleClock`，settings 可锁 UTC+8；**当前仍是空串（跟随系统），待用户决定**。
  倒计时口径是「到下周一 00:00」，不是「用尽后 7 天」，实际等待 0–7 天不等
- **「读不到文件」不能一刀切当「没问题」**：v2.5.4 因此漏掉
  「装了 Typeless 但 app-onboarding.json 被升级删掉」这种情况。
  凡是「文件缺失」类的判定，都要区分「本来就不该有」和「本该有却没了」
- **日志必须轮转，且轮转要原地截断**：守护 60 秒一行，实测堆到 24MB。
  另外只砍一半不够，要循环砍到上限以内（15MB 砍一次还剩 7.5MB）
