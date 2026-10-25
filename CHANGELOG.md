# 更新记录

当前版本 **v2.7.4**。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## v2.7.4（2026-10-25）

自动换号阈值调回 200（按用户要求「剩余 < 200 即切换」）。

### 改动
- `SmartSwitchPolicy.defaultRemainingThreshold` 由 120 调回 **200**。安全不变式仍成立
  （200 × (urgentMultiplier−1)=600 ≥ 200 字/分语速），不会在听写中途撞 0；代价是预留占比
  回到 10%，用户主动接受该取舍。
- 新增迁移 `bumpAutoRotateThresholdTo200_v2_7_4`：存量 store 里仍是旧默认 120 的提到 200，
  手改过的阈值不碰。

### 重要说明（非阻断）
官方额度 API 自 2026-10-14 起被 Cloudflare 指纹墙挡死（HTTP 418），App 读不到实时剩余 ⇒
降级模式阈值按 3 倍放大（200→600）且走 90 分钟定时轮换，阈值本身不触发。要让「<200 就切」真正
精准生效，需接 Accessibility 读屏取 Typeless 官方窗口上的真实周额度（下一步，尚未实现）。

---

## v2.7.3（2026-10-25）

换号后桌面端「没登录好」 —— **根治设备重置误删浏览器会话目录**。

### 背景（用户报障「为什么没有登录好啊」）

v2.7.2 部署后，用户发现 Typeless 桌面端显示未登录。排查守护日志时间线：

- 13:33 之前 Typeless 登录着（`clear.line.461126`）；
- 13:36 v2.7.2 的「额度 API 不可用 → 强制轮换」触发，把会话覆盖成 `prime.pixel.108940` 并重拉；
- 13:40 起守护再也读不到登录态（"无法读取官方 App 登录态，本轮巡检跳过"）。

**根因**：静默换号的「重置设备身份」步骤（`resetTypelessDeviceIdentityForAutomaticReplacement`）
在清理 `device.cache` / keychain / `app-storage.json` 的 userData 之外，**还无差别删除了
`Local Storage` / `Cookies` / `Session Storage` / `Network` 这些 Chromium 浏览器会话目录**。
而 Typeless 2.8.3 的**真实登录态就挂在那些目录上**。删掉它们、只写回 `user-data.json` 再重拉，
2.8.3 读不到会话 → 显示为未登录，把本来登录着的账号弄掉线。

**实测验证**：退出 Typeless → 仅注入 `clear.line` 的 `user-data.json`（不重置设备）→ 重拉 →
2.8.3 原封不动接受会话（`--local-only` 读回 `clear.line.461126@8888891.xyz`，
`app-storage.json` 被填回 `userData`）。证明注入格式 2.8.3 完全认，坏就坏在设备重置的无差别清理。

### 改动

- **删除误删逻辑**：`SwitchboardStore+DeviceReset.swift` 里清理那四个 Chromium 浏览器会话目录的
  for 循环已整体移除。设备身份只认 `device.cache` + keychain + `app-storage.json` 的 userData，
  与浏览器会话目录无关，删它们纯属误伤。
- 保留 `device.cache` / keychain / `app-storage.json` 的清理 —— 既达成「轮换设备身份避免
  服务端设备号上限」的目的，又不再破坏登录态。

### 影响

- 静默换号（正常切换 + v2.7.1 强制轮换）之后，桌面端仍能保持登录，不再误退到未登录。
- 已对用户端执行受控救回：纯注入把 `clear.line` 登录态还原，浏览器会话目录完好。

---

## v2.7.2（2026-10-25）

会话令牌健康度 —— **让「能不能切过去」从黑盒变透明，并堵死僵尸号**。

### 背景（实测发现）

排查 v2.7.1 强制轮换时，解了全池 50 个号的 JWT，发现一个关键事实：

- Typeless 的 `access_token` 寿命约 **1 天**（30 个有效令牌全部当天过期）；
- 但 `refresh_token` 寿命约 **9 个月～1 年**（47/50 个号都有 refresh_token，且全部有效，
  过期日分布在 2027-07 至 2027-10）。

静默换号把 `access_token` + `refresh_token` 一起写进桌面端 `user-data.json`，桌面端启动时会用
`refresh_token` 续发新的 `access_token`。所以真正决定「切过去能不能用」的是 **refresh_token 是否还有效**，
而不是 access_token 当天是否过期——之前「30 个号今天到期」的担心是虚惊。

### 改动

- **Account 模型新增令牌健康度计算**（纯 computed property，不增存储字段）：
  解出 `access_token` / `refresh_token` 的 `exp`，给出三态 `sessionHealth`
  —— `healthy`（access 有效）/ `refreshable`（仅 refresh 有效，桌面端续期）/ `dead`（无可用令牌）。
  派生 `isSilentlySwitchable`（令牌未全死）作为静默换号候选的真实判据。
- **静默换号候选判定包含令牌健康度**：`smartSwitchCandidates` 与 `quotaSnapshot` 的
  `hasSilentSessionPayload` 改为 `isSilentlySwitchable`。`SmartSwitchPolicy.decide()` 本来就只把
  `hasSilentSessionPayload && 剩余 > 0` 的号当可切候选，于是**正常切换与 v2.7.1 的强制轮换都不再会
  挑到 refresh 已死的僵尸号**；若全池都死了，则如实降级到「自动注册新号」。
- **UI 可见**：账号列表行新增会话健康徽章（绿/橙/红）；账号详情新增「会话令牌健康」面板，
  列出 access / refresh 到期时间与续期说明；「复制体检报告」增加健康度分布
  （可秒切 / 仅刷新令牌有效 / 已失效 / 无会话缓存）。

### 影响

- 不改变既有换号行为：当前 47 个有效 refresh_token 全部健康，候选集与之前一致。
- 只是把「僵尸号」从候选里剔除，并在 UI 上让用户一眼看清每个号的会话状态。

---

## v2.7.1（2026-10-25）

额度耗尽不自动切换 —— **根因定位 + 降级模式兜底修复**。

### 根因（实测，已闭环）

Typeless 在 2026-10-14 起给 `/user/usage_stats` 上线 Cloudflare 指纹白名单
（HTTP 418 / `ja3_tls_code: 101010100`）。实测确认**所有外部客户端都被拦**：

- Node `https` 直连 → 418；
- `curl_cffi`（`impersonate='chrome'`，browserleaks 验证 JA3 是合法 Chrome，且能过
  cloudflare.com）→ 仍 418；
- Playwright 真 Chromium（注册链路能过 Cloudflare）→ 在该敏感路由被 bot 检测，仍 418；
- 官方 App 自己的浏览器上下文能过，但**不把周额度落盘**，且**二进制启动器拒绝
  `--remote-debugging-port` 等 Chrome 旗标** ⇒ 无法从外部或本地缓存读额度。

后果：守护每次同步都拿不到新鲜额度 ⇒ `lastQuotaSyncAt` 永远不更新 ⇒ 一直停在
降级分支；而降级分支用「最后一次成功同步的冻结 remaining」做决策，冻结值不递减 ⇒
永远 ≥ 阈值 ⇒ 永不换号，用户额度用完只能手动点「智能换号」。

### 修复

- **降级模式不再冻结**：额度 API 长期不可用（现在已是常态）时，若池内有「可静默注入会话」
  的新鲜号且距上次强制轮换已超过冷却（默认 90 分钟），则轮换过去（与手动「智能换号」等价），
  保证用户**永远不会卡在已耗尽的号上**。冷却避免守护每分钟烧一轮（用户明确要求别过度占资源）。
- 新增持久化字段 `lastForcedRotationAt` 做退避，向后兼容（旧 store.json 缺该键 → nil）。
- `extract-active-session.js` 新增 `--emit-headers` 模式（只做会话解密 + 签名头输出，不发包），
  为将来接 JA3 仿真传输层预留接口。

### 仍待确认（非阻断）

精确「额度耗尽即换」目前无法靠外部读取实现（被 Cloudflare 堵死）。若要恢复精确触发，
可行路径是**读官方 App 屏幕上显示的周额度**（App 自身是可信源，已在显示给用户看），
即由 Switchboard 用 Accessibility 抓取 App 窗口里的「剩余 X / 已用 Y」，作为额度来源接入
`syncActiveAppSessionAndQuota`。该路径需要结合正在运行的 App UI 验证，列为下一步。

---

## v2.7.0（2026-10-25）

账号池扩容 + 批量注册管线加固。用户原话：「账号怎么就只有 21 个？……像我们这种深度使用，
最少也得搞 50 个或者 100 个左右。你继续弄完，因为除了日常用，我们还要做高压测试」、
「也不要加太多，控制在合理范围内，别过度占用资源」。

### 新增

- **CLI 批量注册上限 5 → 100**（`--auto-switch-count`）。

  旧上限是「批量测试别玩太大」的保守值，与「承载运维测试和抗压、池子要 50 个左右」
  的实测需求冲突。真正的安全阀不是这个硬帽，而是：
  ① 数量必须由用户显式传入；② 任一轮未 completed 就整体停，不硬闯；
  ③ 新增轮次间隔与热备模式（见下）。

- **`--auto-switch-preserve-current` 热备模式**。

  只往池子里加号，**绝不碰用户桌面登录态**：跳过 Chrome/桌面会话清理与 handoff、
  不弹任何授权窗、不改当前使用账号。账号池扩容用这个模式跑，
  用户侧无感（正在听写的会话不被打断）。

- **`--auto-switch-delay-seconds` 轮次间隔**（默认 30 秒）。

  连续注册会对 MoeMail / Typeless 形成注册速率压力，也给每轮 Playwright
  留出干净的退出时间。冒烟测试可传 0。

### 说明

- 批量注册仍走 App 内 Playwright 管线：自建 MoeMail（mail.8888891.xyz）与官方
  Typeless 注册都在 Cloudflare 浏览器完整性校验后面（JA3 指纹拦截，实测
  `curl`/`urllib` 直连 403 error code 1010），只有真浏览器能过 —— 这正是
  v2.6.7 起额度通道降级、注册链路保留 Playwright 的原因。
- 新账号密码沿用 v2.6.8 边车密源：注册时 `SecItemAdd` 落钥匙串并镜像边车，
  后台进程读边车，不再有钥匙串 ACL 卡死风险。

---

## v2.6.9（2026-10-25）

选号算法审查 + 稳定化。用户原话：「不知道为什么每次总是搞来搞去，包括功能上也有问题」。

### 审查结论（先看证据再动手）

翻完 7069 行守护日志后的结论：**选号算法本身并不抖** —— 12 天里真正的切换只有 2 次
（10-14、10-15 各一次静默切换），其余全是「持续监控，暂不换号」。
用户感知到的「搞来搞去」实际来自三处，前两处已修：

| 现象 | 根因 | 状态 |
|---|---|---|
| 该换不换 / 换了没反应 | 额度 API 被 JA3 拦，决策永久跳过 | v2.6.7 已修（降级估算） |
| App 冻住 / 守护停摆 | 钥匙串授权卡死 + 双开巡检 | v2.6.8 已修（边车密源） |
| 「池子里还有号却老是去注册新的」 | **自动注册无退避 + 往低于阈值的死号里切** | 本版修 |

### 修复

- **自动注册失败后不再每分钟重烧资源**（用户明确要求「别过度占用资源」）。

  旧逻辑：注册失败（MoeMail 不可用 / Typeless 拒绝注册 / Playwright 挂）后，
  下一轮巡检（60 秒后）会**原样再试一次** —— 每轮新建一个 MoeMail 地址、
  跑一遍 Playwright。持续故障一天就是 1440 个废地址 + 1440 次浏览器会话，
  而且每次都在 store.json 里留一个 pending 账号，池子被垃圾填满。

  现在：指数退避 **5 → 10 → 20 → 40 → 60 分钟封顶**（连续失败计数持久化，
  成功一次即归零）。瞬时故障 5 分钟后恢复；持续故障最多一小时一次。
  退避状态写进巡检文案，用户看得到为什么没注册。

- **自治切换只切到能越过阈值的备用号**（`SmartSwitchPolicy.decide`）。

  旧逻辑「有就切」：当前号剩 90、备用号剩 100 也切。但一次切换并不免费 ——
  轮换设备身份、重写桌面会话、等桌面端读盘（热启动 5～10 秒，冷启动实测到过
  120 秒），期间用户正在听写；原账号还被标记成 exhausted 白烧额度。
  切到一个**同样低于阈值**的目标只是把问题搬家。

  现在：额度巡检（自治）只在目标能越过阈值时才静默切换；整个池都探不过阈值时
  走全自动注册拿一个新号，而不是在死号之间搬运。**手动「智能换号」保持原语义** ——
  用户显意要求切换时，「有个能用的」比「没有」好，代价由用户自己承担。
  不允许自动注册时，reason 会明说「池内 N 个可注入备用号都低于阈值，切换无收益」，
  不再是静默换一个最满的死号。

### 测试

`OperationalFeatureChecks` 新增 12 条断言：新决策路径 4 条（含手动/自治分治）、
退避曲线 8 条（0 失败放行、无记录放行、5/10/20/40/60 分钟、冷却完毕放行、文案）。

---

## v2.6.8（2026-10-25）

修一个比 JA3 更致命的静默失效：**守护进程卡死在钥匙串读取上，整个额度守护从 10-22 起就没再跑过一轮**。

### 修复

- **守护进程（LaunchAgent）全员卡死，launchd 却显示一切正常**

  现象：`quota-guard-daemon.log` 最后一条正常巡检停在 `2026-10-22 05:39:45Z`，
  此后 launchd 里 job 一直是 `state = running`、每分钟到点，`sample` 抓到的栈却是：
  `runDaemonQuotaGuardOnceIfRequested → KeychainStore.readAPIKey →
  SecItemCopyMatching → SecurityServer::ClientSession::decrypt → mach_msg` ——
  每一轮都永久挂在等 securityd 回消息上。job 占着位不退出，后续轮次再也不跑。

  根因：本 App 是 **ad-hoc 签名**（`codesign --sign -`）。钥匙串条目的 ACL 默认
  只信任**创建时那个二进制**（按 designated requirement 匹配，ad-hoc 签名即 cdhash）。
  v2.6.6 在 10-22 13:40 装上（重签 ⇒ cdhash 变了），当分钟起守护读 API Key
  就要重新授权；而守护是 launchd 以 `ProcessType=Background` 拉起的**无界面进程**，
  授权框弹不出来，`SecItemCopyMatching` 就永远等下去。
  （对照组：账号密码条目用 `security` CLI 读同样挂死；API Key 条目却能秒读 ——
  两条路径的 ACL 状态不同，但都不该由后台进程依赖。）

  这与 v2.6.0 / v2.6.7 是**同一失效模式的第四次重演**：界面无异常、日志不再增长、
  功能静默停摆。区别是前三次至少还留了「跳过换号决策」的日志，
  这次连日志都没有 —— job 卡在第一行之前。

  修复分三层：

  1. **守护不再碰钥匙串**：新增 `DaemonSecretStore` 边车文件
     （`~/Library/Application Support/TypelessSwitchboard/daemon-secrets.json`，0600），
     存 API Key 与账号密码。GUI 仍以钥匙串为权威源，每次成功读取/保存都镜像进边车
     （值已到手，镜像不引入新的授权面）；守护与 CLI 只读边车，
     没有弹框问题，也没有「登录钥匙串睡眠锁定」问题。
     边车缺失时守护降级为「仅静默切换」并明确记日志，不猜不骗。
  2. **看门狗兜底**：守护启动即武装 20 分钟硬上限（正常巡检 1-2 秒，
     最慢一次全自动注册 735 秒），到点直接记日志 `exit(70)`，
     launchd 下一轮自然重启。看门狗走 detached Task + 直接写文件，
     **不依赖 MainActor** —— 主线程可能卡在 Mach 消息里。
  3. **密源解析按运行模式分流**：GUI 走钥匙串（可弹授权，读成功后自动镜像边车），
     `daemonOnce` / `cliAutoSwitch` 走边车。原先是全局直接读钥匙串，
     守护传空 Key 时还会在 `performAutoRotateCheck` 里二次踩雷。

  ⚠️ 顺带排查并**放弃**了一个方案：给钥匙串条目设「无限定 ACL」
  （`SecAccessCreate(desc, nil)`）让任何进程免授权读。沙箱内无法用第二个二进制
  验证其语义（python3 读任何条目都挂，`security` CLI 又始终有特权），
  而万一语义与预期相反（空列表 = 谁也不许读），新保存的密码将全部读不出 ——
  风险不可接受，留待以后在有 GUI 授权的环境里验证。

### 已知事项

- 存量 21 个账号的密码仍只在钥匙串里（ACL 信任的是 10-22 之前的二进制）。
  不影响自动换号主链路（静默切换不需要密码）；需要时打开一次 App 触发读取，
  成功后即自动镜像进边车。
- 设备重置路径会删 Typeless 官方 App 的钥匙串条目（`deleteTypelessDeviceCredentialsFromKeychain`），
  与我们的签名无关，暂未改动；守护从未实测过该路径，列此备查。

---

## v2.6.7（2026-10-25）

这一版治两件事：**自动换号因额度接口失效而停摆**，以及**注册页点了不注册**。
两者都是「看起来在运行、实际链路断了」的同一类问题。

### 修复

- **额度接口失效后自动换号永久停摆**（用户报障：额度没了得手动点「智能换号」）。

  Typeless 服务端自 **2026-10-14** 起对 `/user/usage_stats` 上线 **JA3/TLS 指纹白名单**：
  带正确签名的 Node 请求返回 HTTP **418 / `code 101010100` / `ja3_tls_code`**；
  不带签名的 curl 则是 403 `20006 "This client is not supported"`。
  两条放一起才能定性 —— **签名层已经过了，卡在新加的 TLS 指纹层**，
  所以这不是 v2.6.0 那类密钥轮换问题，改签名救不了。
  （密钥本身仍在自动跟上：本机 Typeless 已 2.8.3，`client-profile.json`
  显示 `source: asar`，v2.6.0 的现场提取机制依然有效。）

  而 `performAutoRotateCheck` 的旧逻辑是「API 不新鲜就跳过换号决策」——
  这在 API **偶尔**抖动时是对的（避免陈旧数字误触发），但 API **持续**失效时
  会让自动换号一直停摆。本机实测：从 10-14 停到 10-24 共 **11 天**，
  守护日志 **7055 行里 3182 条「跳过换号决策」**，且**日志里一个 418/ja3 字样都没有**
  —— 失败原因被静默吞掉。这与 v2.6.0 记载的「9124 条跳过、两周无人察觉」
  是**同一失效模式的第三次重演**。

  现在区分两种情形：

  | 情形 | 处置 |
  |---|---|
  | 数据还不太陈旧（距上次成功同步 < 10 分钟） | 继续保守跳过，不用陈旧数字做决策 |
  | 持续失效（距上次成功同步 ≥ 10 分钟） | **降级到本地缓存估算**继续驱动换号，UI 标注「估算模式」 |

  判据用**时间**而不是「连续失败次数」：守护是 launchd 拉起的**单次进程**
  （`--daemon-check` 跑完就退），内存里的失败计数每次重启归零，永远攒不到阈值；
  而 `lastQuotaSyncAt` 是持久化字段（v2.6.6 加入 `PersistedState`），
  天然跨进程累积 ——「多久没拿到新鲜数据」正是这句话的本意。

  ⚠️ 降级口径必须保守：本地 `remainingCharacters` 是上次成功同步的快照
  （本机为 10-14），此后的真实消耗没有记录 ⇒ 会**高估**剩余。
  所以降级时换号阈值按 `quotaDegradedThresholdMultiplier`（3）放大，
  宁可早换，不可该换不换。状态栏会明确写出
  「⚠️ 估算模式（官方额度 API 不可用，阈值为正常 3 倍）」。

  客户端指纹被拒（403/20006）**不降级** —— 那是「本地无解、必须升级 App」的状态，
  靠降级掩盖只会让用户以为还在自动保护中。

  ⚠️ **JA3 拦截本身尚未解决**，本版只是让功能不再停摆。借道官方 Electron 的几条路
  都已验证走不通：自建 Electron bridge（clone 的 app 被 `com.apple.provenance`
  导致 Launch Constraint 静默拦截，且该属性删不掉）、给官方 app 传
  `--remote-debugging-port`（launcher 把 flag 交给 Node CLI，报 bad option）、
  读官方 UI 额度（需辅助功能/屏幕录制授权，且 UI 一变就脆）。
  可行的方向是让用户在系统设置里给 App 一次性授权后读官方界面，留待后续版本。

- **注册页点了不自动注册**（用户报障：点击打开注册页之后没有自动去注册账号）。

  根因：「注册与邮箱」页的「创建注册候选账号」只走完整链路的第 4 步 ——
  `createMoeMailRegistrationCandidate` 建好候选账号就返回，
  后面 8 步（准备 Node/npm/Playwright、清理旧会话、生成注册脚本、启动 Playwright、
  轮询 MoeMail 验证码、写桥接文件、等浏览器结果、固化静默会话）一步都没走。
  而 `runPlaywrightScript` 全仓库只有「自动换号补充」和守护两处调用，
  UI 上没有任何入口 —— 用户能点的按钮全部到不了它。

  现在补上真正的入口：**「一键注册新账号（全自动）」**，走完整 12 步链路，
  用**热备模式**（`preserveCurrentAccount: true`）注册 —— 只往池子里加新号，
  **不切换用户当前正在用的账号**。按钮旁有进度条与实时状态，
  `.help()` 说明它会做什么。

### 运维

- 当天盘点发现本机 **TypelessSwitchboard.app 未安装在 /Applications**，
  GUI 实际从 `TypelessSwitchboard_Archive/2026-10-22_134030/` 运行，
  且 `~/Library/LaunchAgents/` 下**没有任何 launchd plist**（守护已消失）。
  这三个问题本版不自动修，交由 `build-app.sh --install` 走正规安装链路处理
  （它会先停守护、退出 GUI、装完再 bootstrap 并校验）。

---

## v2.6.6（2026-09-30）

这一版的主题是「**不再静默**」，两件事：

1. **写入不再被静默丢弃** —— v2.6.5 修的是**账号字段**，这一版修的是**状态级字段**和
   **没人读的幽灵字段**。
2. **会制造静默失效的操作不再被放行** —— 换号验证的 light 模式批量跑，会静默污染本机
   设备身份，最终表现为「额度一切正常、桌面端却登录不了」，排查成本极高。

### 修复

- **`store.lastQuotaSyncAt` 写进去就没了**。`scripts/sync-account-quotas.js` 一直在写这个键，
  用来记录「最近一次成功拉到本周额度」的时刻；但 `PersistedState` 里**没有这个字段**，
  `SwitchboardStore.lastQuotaSyncAt` 当时只是个运行时 `@Published`。于是那份 JSON 被解码时
  该键被直接忽略、GUI 下一次落盘又把它抹掉 —— 而界面的额度摘要行
  （`weeklyQuotaSummaryLine`）恰好要显示这个时刻，结果脚本明明同步成功了，
  界面照样显示「—」，重启后更是彻底丢失。

  现在把它加进 `PersistedState`：加载时读回运行时属性；落盘前与磁盘上的值**取较新者**
  （脚本同步和 App 同步都是「同步事件」，谁晚谁准），再写回文件。

  ⚠️ `lastQuotaSyncFresh`（本次会话最近一次同步**是否成功**）**故意不持久化**：
  重启后还没验证过新鲜度，落盘一个 `true` 就是谎报。

- **两个幽灵字段写入被删掉**。`scripts/revive-account-sessions.js` 与
  `scripts/sync-account-quotas.js` 都在写 `lastSyncedAt`，但 `Account` 模型里没有这个字段、
  JS 侧也没有任何一处读它 ⇒ 纯粹是「写了等于没写」。删掉，不再制造这种假象。
  （每账号的同步时刻由状态级的 `store.lastQuotaSyncAt` 统一表达，那个字段现在真的持久化了。）

- **设备重置漏删 `device.cache`** —— v2.6.6 挖出的第二个静默失效，也是当天「额度一切正常、
  桌面端却登录不了」的真凶。`scripts/verify-silent-switch.js` 的设备重置只查
  `Typeless/device.cache` 一个路径，而真实文件在 `now.typeless.desktop/device.cache`；
  该路径**从来不存在**，`fs.existsSync` 为 false 就**静默跳过**，连一行日志都不留。
  于是「重置设备身份」看起来成功（keychain 条目确实按新时间重建了），
  实际 deviceId 一个字没变，桌面端重启后继续拿旧设备身份登录，
  服务端照样按「同一设备挂过太多用户」拒绝。

  现在遍历全部候选目录（与 App 侧 `typelessDeviceCacheDirectories()` 对齐），
  删到哪条就把完整路径写进日志；**一个都没删到时显式告警**，绝不静默。

  实测对照：修复前 `device.cache` 恒为 `D1439342-…`（17:50 起没动过）；
  修复后一次重置即变为 `B884D38D-…`，桌面端随即恢复正常、不再弹超限。

### 新增

- **字段契约守卫**（`Tests/OperationalFeatureChecks`）。这组断言从 Swift 源码里解析出
  `Account` / `PersistedState` 的**存储属性**集合（计算属性会被排除），再扫维护脚本里对
  持久化对象的字段赋值，逐个核对字段名是否真实存在。将来加字段若忘了同步 Swift 模型，
  测试会直接红，而不是等线上发现「脚本说写好了、文件里没有」。

  同时断言这两个幽灵字段不得再出现 —— 且**跳过注释行**，不允许用注释绕过。

### 新增（续）：换号验证的「设备身份护栏」

`scripts/verify-silent-switch.js` 默认的 light 模式**保留设备身份**（脚本自己的日志就写着
「静默注入（保留设备身份）」），而 Typeless 服务端对「同一台设备登录过多少个用户」有上限。

2026-09-30 实测：三轮 light 批量验证（3 + 18 + 18 = **39 个账号**）把本机设备身份挂爆，
Typeless 桌面端随即弹 `The number of users logged into this device has exceeded the limit.`。
这个失败形态**极其隐蔽** —— 额度接口一切正常、守护每 63 秒都能读到剩余额度，只有桌面端
登录被拒；App 自己的静默换号不受影响（它传 `resetDeviceIdentity: true`，每换一次就是一台
新设备），出问题的只有验证脚本的默认模式。

现在 light 模式**单次最多验证 3 个账号**，超了就拒绝执行并指明正确路径（`--full`）；
确实要越权得显式加 `--allow-light-batch`。护栏排在 `--dry-run` 之后（只读操作不该被拦）、
并发守卫之前，并加了源码级断言防止它被后续改动悄悄删掉。

顺带修掉一个文档错误：帮助文本写 `--observe 40`，但该参数单位是**毫秒**，40 会被钳到
下限 5 秒 —— 改成 `--observe 40000`，并在传了过小值时给出提示。

### 运维

- 当天重置了本机设备身份，把服务端记的「本设备 39 个账号」清零。
  ⚠️ **第一次重置是假成功** —— 就是上面那条 `device.cache` 漏删：钥匙串条目确实按新时间
  重建了，但 `device.cache` 没动，桌面端仍被判超限。修好脚本后再重置一次才真正生效。
  最终判据是 **`device.cache` 的值发生变化**（`D1439342-…` → `B884D38D-…`），
  而不是「脚本打印了 ✓」—— 后者在漏删路径上照样会打印成功。

---

## v2.6.5（2026-09-30）

这一版把 v2.6.3 里靠「运维纪律」规避的两个问题，**从代码上堵掉**。

### 修复

- **GUI 落盘会把维护脚本的成果整份还原**（v2.6.3 只是加了「跑脚本前先停 GUI」的纪律）。
  `store.json` 是整份覆写，而 GUI 常驻数小时、内存里拿着启动那一刻的副本 ⇒
  脚本写进去的会话复活 / 额度同步结果，撞上 GUI 任意一次落盘就被还原，
  而脚本那一侧打印的是「✓ 已写回账号池」、官方接口当场也验证通过。

  现在 `save()` 在落盘前先看一眼磁盘，把外部改动采纳回来。规则不搞通用 merge
  （那要给每个字段加时钟，侵入面太大），只处理外部脚本**真正会改**的三个字段
  `rawUserDataPayload` / `usedCharacters` / `monthlyLimit`，其余字段一律以 GUI 为准。

  判据是一份**加载时基线**：

  | 磁盘 vs 基线 | 内存 vs 基线 | 含义 | 处置 |
  |---|---|---|---|
  | 变了 | 没变 | 外部脚本改的 | **采纳磁盘** |
  | 变了 | 也变了 | GUI 自己改的（如刚换完号） | 以内存为准，不采纳 |
  | 没变 | — | 没有外部改动 | 无需采纳 |

  基线在**加载并迁移之后、任何 GUI 改动之前**采集。这一点不能图省事改成
  「首次 save 时懒采」—— 那会把 GUI 刚换完号写进内存的 payload 当成基线，
  于是磁盘上的旧 payload 反而被判定为「外部更新」而采纳回来，**换号被静默回退**。

  顺带处理了外部**新增**账号（如 CLI 注册流程写入的新号）：基线里没有、内存里也没有
  ⇒ 追加；基线里有而内存里没有 ⇒ 是用户自己删的，不复活。

  性能：没有外部写入时开销只是一次 `stat`（比对文件指纹），不会在逐字符输入触发的
  `save()` 里反复读 50 KB 的文件。

- **换号验证会被 GUI 的自动换号污染，产生假失败**。
  `verify-silent-switch.js` 原来只要求停掉额度守护，没检查 GUI。
  实测（2026-09-30）：18 个账号验证下来 2 个报「观察窗口后会话变成了 `clean.paper`」——
  看着像换号坏了，其实是 GUI 按额度自动换号把观察窗口里的目标账号换走了
  （`bold.pixel` 剩 118 < 阈值 120，`clean.paper` 是池里额度最多的号）。
  现在两个维护脚本共用引擎模块里的 `preflightConcurrentWriterGuard`：
  GUI 在跑或守护已加载就**拒绝开工**并打印处置命令，`--force` 才可越过。

  守卫抽到共享模块（`extract-active-session.js`）而不是各写一份 ——
  这类「同一道关写两遍」正是 v2.6.0 之前两份会话脚本分叉的老路。

### 说明

- 本版新增 `Sources/TypelessSwitchboardCore/AccountExternalFieldMerge.swift`（纯函数，
  含合并规则与基线语义的完整注释）与 `SwitchboardStore+ExternalAccountMerge.swift`
  （落盘前的采纳动作 + `Logs/external-merge.log` 留痕）。
- 测试新增 `runAccountExternalFieldMergeChecks()`（合并规则 6 种组合 + 外部新增判定），
  并把并发防护的断言扩到换号验证脚本。

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
