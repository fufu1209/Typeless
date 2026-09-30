# 更新记录

当前版本 **v2.6.4**。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## v2.6.4（2026-09-30）

一个把界面数字对齐到真实能力的修复版。

### 修复

- **「可用账号 / 剩余额度」把「换不过去」的账号也算进去了**。
  原实现是无条件全池求和：

  ```swift
  private var totalRemaining: Int {
      store.state.accounts.reduce(0) { $0 + $1.remainingCharacters }
  }
  ```

  但选号逻辑（`QuotaCycleEngine` 的「静默就绪」池）要求账号**带静默会话**
  （`rawUserDataPayload` 非空）才会被选中 —— 没有它的账号只能重新注册/登录，
  额度**根本换不过去**。实测（2026-09-30）：界面报 **79,866**，
  真实能换过去的只有 **73,866**，多算了 2 个无会话账号的 **4,000 字**。

  这类偏差的危险不在于数字大小，而在于它**恰好落在「还能用多久」的判断上**：
  用户看到还有余量，实际可能已经换不动了。

  现在新增 `QuotaPoolSummary`（Core，纯函数），口径与选号逻辑**对齐**，
  并单独统计被排除的部分，界面上多一行说明：

  > ⚠️ 另有 2 个账号无静默会话（4,000 字未计入）

  配套测试 `runQuotaPoolSummaryChecks()` 覆盖单项分桶、真实场景，
  以及不变量「可用 + 未计入 = 所有可选且有余量账号的额度之和」（一分不多一分不少）。
  顺带给两个数字都加了 `.help()` 说明口径。

### 说明

- **`token-expired` 不等于换不过去**。access_token 只有 24 小时，账号池存的是
  「抓取那一刻」的快照，隔天必然过期；但换号时是把 `rawUserDataPayload` 写进
  Typeless 的 `user-data.json`，由**官方桌面端自己用 `refresh_token` 换发新 token**。
  所以只要 `refresh_token` 还活着（本机实测普遍剩 280–363 天），账号就能正常换过去。
  真正换不过去的只有两类：**没有会话缓存**（`no-session`）和
  **`refresh_token` 也死了**（如 `prime.draft.457706`，已废 68 天）。
- ⚠️ 后者（`refresh_token` 已死）**目前仍会被算进「剩余额度」** —— 它带着 payload，
  仅凭 payload 非空判断不出来，需要在 Swift 侧解析 JWT 的 `exp` 才能识别。
  暂未实现：会话解析逻辑的唯一来源是 App 包内的 `extract-active-session.js`，
  在 Swift 里再写一份会造成第二份真相。当前以 `scripts/audit-account-pool.js`
  的体检结果为准。

---

## v2.6.3（2026-09-30）

这一版治的是**钥匙串授权框**，以及一类刚被发现的 shell 陷阱。

### 修复

- **每次重装都会弹钥匙串授权框，不点它 GUI 与守护就双双卡死**。
  app 原先用 ad-hoc 签名（`codesign --force --deep --sign -`），签名指纹是
  `cdhash`，**每次构建都不一样**；而钥匙串条目的授权记录里存的正是
  「创建它的那个 app 的签名指纹」。于是每次重装，`SecItemCopyMatching` 都会
  重新征求许可 —— 本机实测（2026-09-30）：装完 v2.6.2 后 GUI 前台无窗口、
  守护进程在但日志一行不写，`sample` 显示两个进程都停在
  `KeychainStore.readAPIKey()`，截图确认屏幕上正是那个授权框。
  现在新增 `scripts/create-signing-identity.sh`，一次性创建一把固定的自签名
  codeSigning 证书；`build-app.sh` 检测到它就用它签名，指定要求从
  `cdhash H"…"` 变成 `identifier "…" and certificate leaf = H"…"`，**跨构建稳定**。
  装完实测：守护 60 秒一轮正常写日志、`fresh=true`、GUI 正常出窗。
  （换身份后**还会再弹一次** —— 旧条目记的是老的 ad-hoc 指纹。点「始终允许」即可。）

- **`create-signing-identity.sh` 自己的两个坑**（都在编写过程中实测踩到并修掉）：
  ① 不能用 PKCS#12 —— OpenSSL 3.x 默认 SHA-256 MAC + AES PBE 导出，超出 macOS
  `security` 的解析能力，报 `MAC verification failed during PKCS12 import`；
  加 `-macalg sha1` 也不够（本机 OpenSSL 3.6.4 实测仍失败）。改为**证书与私钥
  分别以 PEM 导入**。
  ② 检测身份不能用 `security find-identity -v` —— 自签名证书**不受系统信任**，
  `-v` 只列「有效」身份，永远返回 0 个，会把已存在的身份误判成「没有」。
  改用 `security find-certificate -c "<CN>"`（`build-app.sh` 里的检测同步改掉）。
  另外导入时加 `-A` 即可免掉 `set-key-partition-list`，整个流程**无需输入任何密码**。

- **三个 shell 脚本里的同一个陷阱：`$变量` 后面紧跟中文，变量名被吞掉**。
  本机 bash 在 `LANG=C.UTF-8` 下会把紧跟其后的多字节字符当成变量名的一部分，
  于是 `"$NAME」，无需重建"` 里的变量名变成 `NAME」`，在 `set -u` 下直接
  `unbound variable` 中止脚本。修掉的三处：

  | 文件 | 原写法 | 触发条件 |
  |---|---|---|
  | `scripts/create-signing-identity.sh` | `"…「$NAME」，…"` | 身份已存在时的幂等分支 |
  | `scripts/build-app.sh` | `"…$SIGN_IDENTITY（…"` | **每次用稳定身份签名后**，会中止整个构建 |
  | `scripts/install-quota-guard.sh` | `"未找到 $APP_BIN，…"` | App 未打包时的自动打包分支 |

  统一改成 `"${NAME}」"` 这类带花括号的写法。仓库内已用正则全量扫过，无同类残留。

- **会话复活会被 GUI 静默覆盖，脚本却照报成功**（第五类静默失效）。
  `store.json` 是**整份覆写**：GUI 与额度守护 `--daemon-check` 是两个独立进程，
  各持一份内存 `state`，`save()` 时整份落盘，**没有任何合并或写前重读**。
  于是复活脚本刚写进去的新会话，撞上其中任何一个进程的一次落盘就被还原 ——
  而脚本仍会打印「✓ 已写回账号池」，官方接口那一刻也真的验证通过，人却用不了。
  实测（2026-09-30）：17 个账号复活后只剩 5 个还在，且活下来的恰好**每 3 个一个**
  （#5/#8/#11/#14/#17），正是覆写周期的指纹；退出 GUI 后 `store.json` 的 mtime
  连续 65 秒纹丝不动，确认它就是覆盖者。
  现在 `scripts/revive-account-sessions.js` 补两道护栏：① **开工前检查并发写者**
  （GUI 在跑 / 守护已加载就拒绝开工，并打印停止与恢复的确切命令；`--force` 可越过）；
  ② **收尾回读账号池校验落盘**，逐账号比对写回内容是否还在，被覆盖就点名报出。
  同一原因也解释了为什么「复活成功数」和「实际可用数」会对不上。

---

## v2.6.2（2026-09-29）

一个纯修复版：把三处**会静默骗过使用者**的缺陷堵上。

### 修复

- **安装时可能触发系统签名校验崩溃**（`EXC_CRASH (SIGKILL (Code Signature Invalid))`
  / `Namespace CODESIGNING, Code 4, Launch Constraint Violation`）。
  `scripts/build-app.sh` 装新包用的是 `rm -rf` + `cp -R`，中间有几秒窗口期；
  而额度守护是 `StartInterval=60` 的 launchd 任务，随时可能被拉起 ——
  一旦它恰好落在这几秒里，就会从「写了一半的 app 包」加载二进制，
  被内核的 Launch Constraint 直接 kill，并往 `DiagnosticReports` 扔一份崩溃报告。
  现在安装前后会先 `launchctl bootout` 停掉守护、退出 GUI，装完再 `bootstrap` 恢复。
  顺带把安装后的启动从裸 `open` 改成走 Finder 的 Apple Event
  （`open` 在受限 shell 里会静默失效）。

- **会话复活脚本会把失败判成成功**。`scripts/revive-account-sessions.js` 原先只要
  检测到 `user-data.json` 的 mtime 变化，就宣布「桌面端已换发新 token」。
  实测（2026-09-29）证明这个判据站不住脚：`access_token` 已过期 66 天的账号，
  桌面端同样会在 +2.6s 重写文件，但随后发现自己也换不动 token，
  就把会话清空、退回登录页 —— mtime 确实变了，人却用不了。
  现在改成四重校验：静置 8 秒后 ① 会话仍可解密、② `access_token` 确实换成了新的、
  ③ 换回来的 `user_id` 与目标账号一致（防止把别的账号写回池子）、
  ④ 新 token 未过期；最后仍以官方 `/user/usage_stats` 返回 200 为准。

- **额度守护（LaunchAgent）会把自己干掉，而且界面不告诉你**。守护原来会按
  「近阈值加速」把 plist 的 `StartInterval` 从 60 秒压到 20 秒，再
  `launchctl bootout` + `bootstrap` 让改动生效 —— 但**守护自己就运行在这个 job 里**，
  bootout 把 job 连同调用者一起停掉，紧随其后的 `bootstrap` 永远执行不到。
  结果：plist 还在（界面据此报「已安装」），launchd 里却空无一物。
  本机实测从 09-29 16:05 静默失效到 09-30 16:38，整整 24 小时无人察觉。
  现在的三条规矩：① 守护从 job 内调用一律**拒绝重载**，改间隔只由 GUI 执行；
  ② 重载必须**校验**（`launchctl print` 查得到才算成功）并重试；
  ③ 界面区分「plist 在」与「launchd 真的在跑」，未运行时显式报
  「⚠️ 已安装但未在运行」，并在 App 打开时**自动自愈**
  （重新 `bootstrap` + 把间隔校正回配置值）。
  顺带把守护对官方额度接口的调用量从「近阈值时 3 倍」降回 1 倍，对账号更安全。

---

## v2.6.1（2026-09-29）

这一版把「**新注册账号自带 3 天 Pro 试用**」这个此前没被记录的事实，变成了工具里
看得见、算得准的东西。

### 新增

- **账号档位识别（Pro 试用 / 免费）**。实测确认：Typeless 给每个新注册账号发
  `role = pro_trial`，`insert_time` → `exp_time` **恰好 3 天**，期间周额度 **23333**；
  3 天后降为 `role = free`，周额度 **2000**（2026-09 之前是 8000）。
  而 `/user/usage_stats` 会直接下发 `week_word_usage_limit`，
  **每个账号拿自己的 token 就能问、不必换号** —— 于是档位可以直接从额度反推。
  账号列表现在会为试用档打出「Pro 试用 · 剩 N 天」徽章；免费档不打，避免列表被徽章塞满。
  试用到期时间用 `createdAt + 3 天` 本地推算，与服务端 `insert_time` 吻合到 21 秒以内。
- **`scripts/sync-account-quotas.js`**：把账号池里的 `monthlyLimit` / `usedCharacters`
  刷成服务端真实值。此前这两个字段只在「该账号恰好是当前活跃账号」时才刷新，
  其余账号长期存着入池那一刻的快照 —— 实测抓到了
  **本地记 2000、服务端真实 23333** 的偏差（两个新注册账号都是），
  偏差会直接误导 UI 的「剩余额度」与「该用哪个号」的判断。
- **`scripts/verify-silent-switch.js`**：静默换号的**真机**端到端验证。
  逐个账号走一遍「退出 → 写会话 → 拉起 → 观察 → 打官方接口」，并采集四条证据：
  ① 进程启动时间晚于会话写入；② 观察窗口后会话仍存活且仍是目标账号；
  ③ 桌面端是否**主动重写**了 `user-data.json`（换发新 token 的硬证据）；
  ④ 官方额度接口返回 200。第 ③ 条只在 `access_token` 过期时才会出现，缺失不算失败。

### 说明

- 上一版把阈值从 200 调到 120 时，`LegacyQuotaRescale` 只对「恰好等于旧默认值」的数据
  做换算；本次的档位识别沿用同一原则：**未登记过的额度一律判为 unknown 并原样显示**，
  不硬塞进已知档位，官方哪天改数字也不会被误标。

---

## v2.6.0（2026-09-29）

这一版的主线只有一句话：**把「额度接口静默失效两周没人发现」这类问题从根上堵掉**，
并顺手把 Typeless 2.7.0 / 2.8.0 带来的免费额度缩水（8000 → 2000 字/周）适配好。

### 修复

- **额度接口全线失效（最严重）**。Typeless 2.4.0 → 2.7.0 轮换了签名密钥、
  并把 `X-Authorization` 从 HMAC-SHA1 摘要换成了 AES-256-CBC 加密负载。
  旧代码把接口返回的 HTTP 403 `code:20006` 归类成「额度没刷新」**静默跳过** ——
  结果守护日志 9/20–9/28 记了 **9124 条「跳过换号决策」、0 条成功**，连续两周没人察觉。
  现在按 2.7.0 协议重写签名，并改为**从本机 `app.asar` 现场提取密钥**
  （按 `[0-9a-f]{56}` 的形状捞，不写死具体值），下次官方再轮换密钥不必改代码。
- **密钥轮换自动跟上（本版发布前刚被验证过一次）**。Typeless 2.7.0 → **2.8.0**
  又轮换了一次密钥（`1a0b8ae1…` → `3fa18880…`），工具靠现场提取零改动恢复可用。
  顺带把过期的兜底常量与 `FALLBACK_APP_VERSION` 更新到 2.8.0，
  并把 20006 的重试从「只重试一次」改成**四段递进阶梯**
  （换角色 ↔ 强制重新提取），覆盖「角色猜反 + 密钥轮换」同时发生的组合。
- **静默换号在冷启动场景 100% 误判失败**。`silentInjectSettleSeconds` 原本是 **2 秒**，
  加上 8 轮 × 2 秒校验合计最多 18 秒；而 Typeless 是 Electron 应用，
  冷启动到读盘完成实测需要约 **120 秒**。等待不足 → 报「注入后未能确认目标账号已生效」，
  上层把已经写好的会话当成失败、继续换下一个号，白白烧掉一个账号的额度。
  现在上限提到 120 秒，且由**死等改为轮询**：只要本地能解出目标账号就立刻返回
  （热启动实测 5～10 秒），只有真正的冷启动才吃满上限。
- **会话/额度脚本存在两份实现并已分叉**。仓库 `scripts/extract-active-session.js`
  与 Swift 源码里的内嵌字符串各演化一份，线上跑的那份和仓库里已经不是同一个东西。
  现收敛为 App 包内 `Resources/extract-active-session.js` 单一来源。
- **自动化子进程调用在系统高负载下假超时**。`runProcess` 把 `waitUntilExit()`
  丢到 `DispatchQueue.global` 上，**每调一次就永久占用一个线程池线程**；
  自动化流程里子进程调用非常密集（node → npm → osascript → playwright 层层嵌套），
  叠上 Typeless 冷启动的 CPU 压力，线程池被这些「只为等待而存在」的线程占满，
  后提交的 block 排不上队 —— 于是明明 **0.03 秒**就跑完的 `node --check`
  也会被判成「命令超时」。实测后果：全自动注册第 2 个账号因此中断（`needsAttention`），
  而生成的脚本本身完全正常。现已改为全程内核回调
  （`terminationHandler` / `readabilityHandler`），不再占用线程池线程。
  同时把「预检命令的判定语义」下沉为 Core 的 `PreflightVerdict`：
  **超时 ≠ 失败**，`unverified` 不拦流程，只有真正 `failed` 才中止。
- **macOS 27 SDK 下编译失败**。系统 SDK 把 SwiftUI 改成了宏实现
  （`SwiftUIMacros.StateMacro`），而宏插件只随完整 Xcode 分发，
  只装 Command Line Tools 的机器 `swift build` 必失败。
  `build-app.sh` 现在会自动回退到 `MacOSX26.*.sdk`。

### 变更

- **免费周额度 8000 → 2000 字**，阈值随之下调：
  `defaultRemainingThreshold` 200 → **120**，`urgentRemainingMultiplier` 2 → **4**。
  阈值不由周额度决定，而由「消耗速度 × 巡检间隔」决定，
  安全不变式 `阈值 × (紧急倍率 − 1) ≥ 每分钟最大消耗字数`
  （120 × 3 = 360 ≥ 实测语速 200）已写进 `runThresholdBoundaryChecks` 一起验。
  顺带把预留占比从 200/2000 = 10% 压到 120/2000 = 6%。
- **「客户端指纹过期」不再和「网络抖动」混为一谈**。新增
  `isClientNotSupportedError`，UI 会显性提示 `⚠️ 客户端指纹已过期`，
  而不是继续显示「额度同步中」。这类错误重试一万次也没用，必须让人看见。
- 迁移 `didRescaleQuotaFor2000WeeklyLimit_v1` 自动把存量账号的阈值与 `monthlyLimit` 改过来。

### 新增

- **`scripts/revive-account-sessions.js` —— 会话复活**。
  `access_token` 只有 24 小时有效期，账号池里存的是「抓取那一刻」的快照，隔天就过期；
  而官方对 `/oauth/refresh_access_token` 做了 JA3/TLS 指纹白名单
  （Node、curl、Chromium 全部过不去，只有官方 Electron 在名单内）。
  但**官方桌面端自己刷得动**：它启动时会拿 `refresh_token` 换一个新的 24h token 并写回文件。
  这个脚本就是走这条路：写入目标会话 → 拉起 Typeless → 等它自己换新 token →
  读回 → 调官方额度接口验证 → 写回账号池 → 恢复原活跃账号。
  带自动备份（`Logs/revive-backups/<时间戳>/`），支持
  `--dry-run` / `--limit N` / `--email X` / `--keep-last`。
  本机实测：16 个僵尸账号复活 **15 个**，池子剩余额度从 0 回到约 28,670 字。
- **`scripts/audit-account-pool.js` 重写**：判定细分为
  `usable` / `exhausted` / `token-expired` / `dead` / `no-session` / `device-limit` /
  `unreachable` / `payload-corrupt` / `payload-incomplete` / `email-mismatch`，
  能准确回答「这个号现在能不能正常换上去」。

---

## v2.5.6（2026-08-29）

### 修复

- **脱敏配置包泄漏真实信息**。导出「脱敏配置包」本意是能安全分享，实测两处漏网：
  `settings` 整个照搬导致 `moeMailBaseURL` 带着真实的邮箱服务地址；
  `typelessUsername` 原样保留，而它由真实邮箱推导而来 —— 邮箱脱敏了但用户名还在，等于没脱。
- **README 的自建邮箱示例接口写错**。示例只给了 `/api/messages`，
  而本工具实际调用 `/api/config`、`/api/emails`、`/api/emails/generate`、`/api/emails/{id}`。
- **版本号漂移**。导出的配置包里 `appVersion` 曾写成 `2.0.0`（裸二进制读不到 Info.plist，
  回落到一个早已过期的硬编码值），实际跑的是 2.5.x。现改为 Core 里的单一事实来源。
- **周期观测不持久化**。观测原先只在内存里，App 一重启就清零；
  而判定「自然周还是滚动 7 天」需要两三次真实重置（两三周），
  每天开关机的用户永远攒不够样本。现已落盘，启动时在任何同步之前读回。

### 变更

- **周期口径不再靠猜，改为实测观测**。官方 `/user/usage_stats` 不返回任何重置时间戳，
  工具现在每次拿到新鲜额度就采样，数值骤降即记为一次真实重置，攒够样本后自动校准口径。
  UI 会如实显示「周期口径待确认（已观测 N 次）」，确认后才说「已确认，依据 N 次实测」。
- **额度周期时区可在「额度守护」页切换**，改完立即生效，不用重启。
  同时修复了 LaunchAgent 守护进程不读该设置、以及看门狗改时区后不重新排程两个问题。
- **新增 CLI**：`--export-full-bundle` / `--export-public-bundle` / `--import-bundle <路径>`，
  换机备份与迁移可以脚本化，不必开窗口点按钮。

### 新增

- `docs/DEPLOYMENT.md`：从零部署教程（域名 → DNS → 邮箱 API → 安装配置）。
- `MIGRATION.md`（私有库）：换机迁移步骤。

---

## v2.5.5（2026-08-29）

- **新手引导补丁收成单一入口** `ensureOnboardingCompleted(reason:mode:)`。
  原先三套并行 API 各写各的写盘逻辑，备份 / 校验 / 补 storage 复制了三份，改一处漏一处。
  现在只有两种模式：`.silent`（Typeless 在跑就不写，只点亮横幅）、`.interactive`（可退出重启）。
- **引导补丁写入层下沉到 Core**（`OnboardingPatchWriter`），写盘路径首次获得完整测试覆盖。
- **修复「文件缺失被误判为已完成」**：装了 Typeless 但 `app-onboarding.json` 被升级删掉时，
  补丁永不触发，而 Typeless 冷启动又会重建这个文件重新变回未完成。
- **周期时区可配置**，本机时区与实际所在地不一致时可显式锁定。
- **新增日志轮转**：守护日志曾堆到 24MB，现自动维持在 2MB 以内。

## v2.5.4（2026-08-28）

- 新增**周额度周期看门狗**，与「无感守护」开关解耦 —— 关掉守护或整个周末不开 App，
  周一 00:00 之后也能自动复活账号。
- 新增**启动自愈引导标记**（Typeless 未运行时静默写盘）。
- 清理旧副本，Spotlight 只保留唯一一份 `/Applications/TypelessSwitchboard.app`。

## v2.5.3（2026-08-28）

- 修复新手引导回归（原来是 fail-closed：邮箱不匹配就整段放弃，两个文件一个都不写）。
- 接上「下次可用」倒计时 —— `QuotaCycleEngine` 的周期方法 v2.1.0 就有了，但 UI 从未调用过。
- 新增单实例锁，避免同时跑多个副本。

## v2.5.2（2026-08-28）

- 钥匙串缓存，避免重复弹权限框。
- 全量配置包导入导出（换 Mac / 分享 / 备份）。
- 阈值边界测试。

## v2.5.1（2026-08-28）

- Store 二次拆分 + 功能保真审计，确保拆分过程没丢功能。

## v2.5.0（2026-08-28）

- 架构拆分：`main.swift` 7544 行 → 28 个职责文件。

## v2.2.0（2026-08-28）

- UI 改为 5 个 tab：账号池 / 智能换号 / 额度守护 / 注册与邮箱 / 自检排障。

## v2.1.0（2026-08-28）

- **周度复活引擎** `QuotaCycleEngine`。此前整条数据链都按月管，
  导致周一恢复的账号被闲置到下月初，约 3/4 额度被错杀。

## v2.0.0（2026-08-28）

- 数据安全：账号池解码失败时保留损坏备份，不再静默吞错导致 Keychain 密码永久找不到。
