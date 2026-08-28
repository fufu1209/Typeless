# Typeless 桌面端「新手引导」补丁 —— 实测真相

> 记录时间：2026-08-28 · Typeless 桌面端 **2.4.0**（Electron 33.4.11）
> 相关代码：`Sources/TypelessSwitchboard/Store/SwitchboardStore+OnboardingPatch.swift`

## 一、两个配置文件，命运完全不同

Typeless 桌面端把引导状态分散在两个 JSON 里，只有第一个能被本地持久改写。

| 文件 | 作用 | 本地改了会不会被冲掉 | 备注 |
|---|---|---|---|
| `~/Library/Application Support/Typeless/app-onboarding.json` | **引导向导真正的开关**（`isCompleted` / `step` / `setUpStep`） | ❌ 不会 | 重启后 Typeless 是**合并**，只追加 `__internal__.migrations.version`，保留我们写的值 |
| `~/Library/Application Support/Typeless/app-storage.json` → `userData.is_new_user` | 服务端下发的「是否新用户」 | ✅ **会** | 每次启动联网同步时被服务端真值覆盖 |

### 实测记录

```
23:12  本工具执行 --skip-onboarding
       → 补丁写入两个文件
       → app-onboarding.json: isCompleted=false → true, step=0 → 99
       → app-storage.json:    is_new_user=true → false，7 平台 onboarding 全 true

23:12:24  Typeless 重启

23:13  app-storage.json 被服务端同步覆盖
       → is_new_user 打回 true，7 平台 onboarding 打回 false
       app-onboarding.json 保持不变（isCompleted=true, step=99）
       → 只多出 "__internal__": { "migrations": { "version": "2.4.0" } }

再次 quit + relaunch，等待 35 秒后复查：
       app-onboarding.json: isCompleted=true, step=99, setUpStep=99  ✅ 稳定
       app-storage.json:    is_new_user=true                          （服务端真值）
```

**结论**：`is_new_user` 不该、也不可能靠本地改文件长期压住——账号今天刚注册，服务端确实认为它是新号，每次联网都会同步回来。真正决定「弹不弹引导向导」的是 `app-onboarding.json`，而这个文件我们改得动、且能跨重启持久。

## 二、v2.5.3 之前为什么「越改越差」

三个缺陷叠加，且互相掩盖：

### 1. fail-closed（最致命）
旧实现：
```swift
let readiness = await waitForTypelessDesktopStorage(...)
if let email = readiness.email {
    guard email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
        return ["桌面 App 当前账号不是新邮箱…暂不改新手引导"]   // ← 整段放弃
    }
}
```
一旦「检测到的邮箱 ≠ 期望邮箱」，**两个文件一个都不写**。Typeless 于是保持新用户态并弹引导。

修复后：按**桌面端实际登录的邮箱**打补丁；`app-onboarding.json` 是 App 级配置、与账号无关，无条件写；邮箱不一致只记一条提示日志。

### 2. 只挂在全自动注册路径上
全工程只有 `AutomaticReplacement.swift` 一个调用点，且嵌在
`if automationComplete { if !preserveCurrentAccount {` 双重条件里。

| 路径 | 旧版是否打补丁 |
|---|---|
| 全自动一键换号（新注册成功） | ✅ |
| 无感换号（池内静默注入） | ❌ |
| 智能换号 / 自动轮换 | ❌ |
| 手动「准备切换」 | ❌ |

修复后：在 `reinjectSessionPayload` 里，**写入会话缓存之后、拉起 Typeless 之前**调用
`writeTypelessDesktopOnboardingFiles`，让 Typeless 冷启动第一次读盘就是「非新用户」，
全程不出现引导向导 —— 这才是真正的无感。

### 3. Typeless 2.4.0 换了 schema
`onboarding` 平台枚举从 4 个扩到 **7 个**：
```
旧：ios, android, macos, windows
新：ios, android, macos, windows, linux, harmony, webpage
```
且 `macos` 节点新增 `app_version` / `completed_at`。旧补丁只写 4 个，剩下 3 个仍是 `false`。

修复后：平台列表 = **文件里已有的键 ∪ 7 个官方枚举**。以后官方再加平台（如 visionos）自动兼容，不用改代码。已存在的 `app_version` / `completed_at` 保留不被覆盖。

## 三、现在的入口

| 入口 | 用途 |
|---|---|
| 账号详情 →「跳过新手引导」按钮 | 图形界面，随时可点，不依赖换号流程 |
| `TypelessSwitchboard --skip-onboarding` | 终端一键，App 卡住时兜底 |
| 换号流程自动 | 新注册完成 / 无感切换，都会自动打 |

日志落在 `~/Library/Application Support/TypelessSwitchboard/Logs/onboarding-patch.log`。

## 四、排查口诀

下次再报「又有新手引导」，按这个顺序看：

```bash
# 1. 看真正的开关（这个文件说了算）
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/Library/Application Support/Typeless/app-onboarding.json')));print(d.get('isCompleted'),d.get('step'))"
# 期望：True 99。若是 False 0 → 补丁没跑到，看 onboarding-patch.log

# 2. 看服务端真值（这个文件被覆盖是正常的，不用管）
python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/Typeless/app-storage.json')))['userData'].get('is_new_user'))"

# 3. 直接重打一次
/Applications/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard --skip-onboarding
```

## 五、教训

- **功能保真审计按「store 成员集合」比对，漏掉了两类东西**：Core 里的 static 方法
  （`QuotaCycleEngine`）和调用链变化（onboarding 补丁的调用点从 1 个变成 1 个但语义变了）。
  纯符号比对看不出「接线断了」。
- **验证必须跨越被测对象的重启**。第一次验证读的是补丁后、Typeless 覆盖前的文件，
  结论「7 平台全 true」看着漂亮，其实是假阳性。

---

## 六、v2.5.5 补强（2026-08-29）

### 新发现的两个缺口

1. **「文件缺失」被误判为「已完成」**（最严重）。
   v2.5.4 的 `desktopOnboardingIsIncomplete()` 在**读不到文件时返回 false**，
   理由是「没装 Typeless 的机器上不该误报警」。但这把另一种情况一起放过了：
   **装了 Typeless、文件却被升级/重装删掉** —— 补丁因此永不触发，
   而 Typeless 冷启动又会按默认值重建这个文件，重新变回未完成，白等一整轮。
   修法：状态判定拆成 `.complete / .incomplete / .missing` 三态，
   「缺失」只有在 **Typeless 已安装**（`/Applications/Typeless.app` 存在）时才算需要处理。

2. **自愈只写 `app-onboarding.json`，不写 `app-storage.json`**。
   虽然 `is_new_user` 是服务端真值、联网会被覆盖，但 Typeless **没在跑**时补写，
   能让冷启动第一次读盘就判定为非新用户。现在是 best-effort：
   缺 `userData`（从未登录）就跳过，不算失败。

### 补丁新增的三道保险

- **写前备份**：首次改写前把原文件存成 `app-onboarding.json.switchboard-orig.bak`，
  只留第一份（每次都覆盖的话备份本身就失去意义）。
- **回读校验**：写完立刻重读，仍不是完成态就记一条告警日志 ——
  写成功不等于生效，磁盘满 / 权限 / Typeless 退出 flush 都可能让写入落空。
- **5 分钟常驻巡检**（v2.5.5 新增）：启动自愈只在冷启动跑一次，覆盖不到
  「App 连开好几天，期间 Typeless 升级把标记重置了」。

### 实测（2026-08-29 00:12）

构造故障现场：删掉 `app-onboarding.json`，然后启动 2.5.5。

```
[2026-08-28T17:12:44Z] 启动自检：检测到 Typeless 桌面端新手引导未完成
```

这行日志本身就是结论 —— **v2.5.4 在这个场景下不会打任何日志**（它认为文件缺失 = 已完成）。
当时 Typeless 正在运行，所以补丁按设计**没有写盘**（写了也会被退出时 flush 覆盖），
只标记状态等横幅提示。写入路径与 v2.5.4 完全共用，无需重复验证。

### 仍然成立的铁律

- **Typeless 运行时绝不写盘**。它内存里持有 `isCompleted=false`，
  退出时会把我们写的值覆盖回去，白写还可能造成状态打架。
- **验证必须跨越被测对象的重启**（详见第五节）。
