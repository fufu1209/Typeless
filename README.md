# Typeless Switchboard

**Typeless 免费额度快用完时，自动换到下一个有额度的账号，你完全感觉不到。**

[![Platform](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.5.6-blue.svg)](CHANGELOG.md)

> 🌍 [English README](README.en.md)

Typeless 是一款很好用的 macOS 语音输入 / 转写工具，但免费账号**每周只有 8000 字**。
用完之后，你得手动退出、登录另一个号、再走一遍新手引导 —— 一天可能要来两三次。

这个工具把整套流程自动化：预先注册好一批账号，额度低了就**静默切换**，
切换过程不打断你打字，也不用再走新手引导。

> ⚠️ 本项目**只包含代码**，不含任何密钥、密码或账号数据。
> 你的数据只存在本机 `~/Library/Application Support/TypelessSwitchboard/` 与 macOS Keychain。

<!-- TODO: 补一张菜单栏 + 账号池界面的截图或 GIF。
     工具类项目没有截图，转化率会差一大截 —— 这是当前最该补的东西。 -->

---

## 快速开始

**前置条件**：macOS 13+，Xcode 命令行工具（提供 Swift 6），一个域名。

```bash
# 1. 克隆并构建安装，产物落在 /Applications/TypelessSwitchboard.app
git clone https://github.com/fufu1209/Typeless.git
cd Typeless
./scripts/build-app.sh --install

# 2. 打开 App，按「自检排障」页把需要的 macOS 权限开了
open /Applications/TypelessSwitchboard.app

# 3. 想要「自动注册新号」的话，还需要一个能收验证码的邮箱服务
#    完整教程（买域名 → DNS → 部署邮箱 API）见 docs/DEPLOYMENT.md
```

只有第 3 步需要额外配置。**如果你已经有一批 Typeless 账号，前两步就够用了** ——
手动把账号加进池子，工具就能自动轮换。

> 第一次用建议先读 [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)，
> 里面有验证邮箱服务是否接通的三条 `curl`，先确认通了再往下走，
> 否则后面报「取不到验证码」时分不清是邮箱没通还是注册流程的问题。

---

## 目录

- [这个工具能做什么](#这个工具能做什么)
- [这个工具不会做什么](#这个工具不会做什么)
- [推荐使用方式](#推荐使用方式)
- [macOS 权限](#macos-权限)
- [全自动一键换号流程](#全自动一键换号流程)
- [开机轻量额度守护](#开机轻量额度守护推荐不必一直开着-app)
- [数据保存位置](#数据保存位置)
- [域名邮箱搭建](docs/DEPLOYMENT.md)
- [从零部署教程](docs/DEPLOYMENT.md)
- [常见问题](#常见问题)
- [参与贡献](#参与贡献)
- [许可](#许可)

---

## 更新记录

**当前版本 v2.5.6**（2026-08-29）。完整记录见 [CHANGELOG.md](CHANGELOG.md)。

最近的主要变化：周期口径改为**实测观测**（不再靠猜）、额度周期**时区可切换且不用重启**、
新手引导补丁**收成单一入口**、新增 `--export-full-bundle` / `--import-bundle` 便于换机迁移。

## 这个工具能做什么

- 管理 Typeless 账号、邮箱、域名、额度和备注。
- 自动挑出下一个可用账号。
- 一键打开 Typeless 登录页、MoeMail 控制台或账号对应的邮箱入口。
- 可打开本机 Typeless App、Typeless 官网，并检查 Typeless 入口是否可访问。
- 一键自检 Typeless App、官网入口、MoeMail 配置、Node/npm/Playwright 缓存、macOS 权限和账号池可切换状态。
- 复制邮箱地址，记录已用字数，标记本周额度已用完。
- 保存本地切换检查清单，避免每次手动换号时漏步骤。
- 本地保存 MoeMail API Key 到 macOS 钥匙串；密钥不会写入仓库。
- 从 MoeMail 读取已有邮箱列表，并导入到账号池。
- 通过 MoeMail API 生成邮箱并导入账号池。
- 一键用 MoeMail 生成注册候选账号：创建真实邮箱、生成用户名、复制强密码，并放入兜底确认队列。
- 读取当前已关联 MoeMail 邮箱的邮件摘要，方便兜底查看验证码邮件。
- **开机轻量额度守护（推荐，不必常驻 GUI）**：用 macOS LaunchAgent 定时执行 `--daemon-check`。**只有剩余字数 &lt; 阈值（默认 200）才自动换号**；额度够只检查就退出。登录后自动跑，不要求一直开着本窗口。
- **App 内循环监控（可选）**：打开 App 时可勾选「打开本 App 时循环监控」；默认关闭，避免占后台。
- **热备池**：额度还够时，后台预注册 1 个带静默会话缓存的备用号；真正低额度时秒切，尽量让你感觉不到。
- **智能换号**：也可手动点一次。优先池内静默注入；没有可注入会话时再全自动注册；静默失败自动降级注册。
- **静默换号也会轮换设备身份**：注入新号会话前按 `resetDevice` 清理 Keychain / `device.cache` / 桌面登录残留，避免同一 deviceId 挂过多账号触发 Typeless「设备登录用户数超限」。
- **设备用户数超限自动降级**：同步额度或静默切换时若识别到 `The number of users logged into this device has exceeded the limit`（及中文同类文案），会跳过静默池切换，自动走全自动重置设备并注册/换号。
- 全自动注册换号：创建 MoeMail 邮箱、Playwright 注册、验证码填表；成功后从浏览器 profile 固化桌面静默会话缓存。热备注册不会清理/切换你当前正在用的桌面号。
- 自动生成 Playwright 注册脚本，脚本和账号专属浏览器登录态目录保存在本机 Application Support 目录，可自动运行，也可在页面结构变化时手动重试。
- 注册成功后会把 Google Chrome 的 Typeless 网页会话切到新账号，再打开 Typeless handoff / desktop deep link，让桌面 App 接到新号；如果出现 Chrome 的“要打开 Typeless.app 吗？”提示，会先勾选“始终允许 www.typeless.com...”，再点击“打开 Typeless.app”。桌面端新手引导会尽量自动完成或跳过。最近一次自动换号结果会保留在右侧状态区，可复制排查；账号专属 Playwright/Chromium profile 只保留作兜底，不会在成功后自动弹出额外浏览器，只有手动点“打开新账号会话”才会打开。
- 右侧“连接设置”提供“打开权限设置”和“复制权限清单”，可快速处理辅助功能、自动化、麦克风、输入监听、屏幕录制、Chrome 外部协议和钥匙串授权。
- 随机生成候选用户名、邮箱地址和强密码，减少手动输入。
- 提供注册助手 / 兜底面板：自动流程卡住时，可复制邮箱、用户名、验证码，打开注册页和邮箱，记录核验完成。
- 提供“准备切换”：把当前账号标记为本周已用完，选择下一个可用账号，复制邮箱，并打开 Typeless 与邮箱入口。
- 批量生成候选账号资料，方便之后自动注册或逐个兜底核验。
- 候选账号只在自动化无法证明注册完成时进入“兜底确认队列”；正常全自动一键换号成功后会直接自动确认。
- 通过剪贴板复制/恢复账号池 JSON 备份。
- 通过剪贴板复制/导入账号 CSV，方便和表格工具配合整理大批账号。
- 每周新周期开始时批量复活已确认账号的额度。
- 在侧边栏搜索账号，并按全部、可用、待确认、用完、暂停筛选。
- 侧边栏显示可用、待确认、用完、暂停等运营摘要；账号行显示状态标签。
- 复制当前账号切换摘要，方便兜底核验或留档。
- 复制账号池体检报告，快速检查重复邮箱、空邮箱、待确认核和低额度账号。
- 打开本地数据文件夹或复制数据文件路径，方便备份和排查。
- 融入 `typeless-toolkit` 的 macOS 路径探测思路，可复制 Typeless App、可执行文件、登录态目录、缓存目录和凭据名的只读环境报告。
- 可导入 `typeless-toolkit` 账号里的 token 字段并生成本地 token 指纹报告；只保存 sha256 指纹，不保存明文 token。
- 可生成登录态快照清单，记录登录态目录中的文件路径、大小和修改时间，便于备份核验。
- 可复制设备信息报告，包含主机名、系统版本、设备型号、Typeless App 路径、登录态目录和缓存目录。
- 可复制注册准备包，汇总邮箱、用户名、注册入口、验证码处理和兜底步骤。
- 可复制完整排障包，汇总 Typeless 入口、MoeMail、账号池和最近自检结果；不包含 API Key、密码或验证码。
- 可从 `typeless-toolkit` 的 `accounts.json` 导入账号元数据；导入昵称、邮箱、角色、user_id，并把 token 字段转为指纹记录。

## 这个工具不会做什么

- 不自动绕过免费额度。
- 不破解 Cloudflare Turnstile、图形验证码或其它真人校验。
- 不通过私有协议或隐藏接口代替正常网页注册流程；自动化只驱动本机浏览器页面。
- 不清理无关网站数据；一键换号只按 `typeless-toolkit resetDevice` 相关逻辑重置 Typeless 本机设备身份、隔离 Typeless 桌面登录态、工具自己的浏览器 profile，并清理 Google Chrome 中 `typeless.com` 相关网页登录态。
- 不把 `typeless-toolkit` 的明文 token 写入本地账号库；设备身份重置只用于本机 Typeless 登录态清理。
- 不保存或使用 `typeless-toolkit` 的明文 token；导入时只记录不可逆指纹，便于本地审计和去重。

## 推荐使用方式

1. 打开应用后，在右侧“连接设置”里填写 MoeMail 地址和 API Key，然后保存密钥。
2. 先点“一键自检”，确认 Typeless App、官网入口、MoeMail、Node/npm/Playwright 自动化环境、macOS 权限和账号池是否准备好；自检会预热 Playwright 包和 Chromium，并在后续换号中复用缓存，减少正式换号时等待或失败。
3. 点“打开 App”或“打开官网”确认 Typeless 能正常打开；入口异常时点“检查入口”。
4. 点击“同步域名”和“读取列表”，把你已有的邮箱导入账号池。
5. 当前账号额度用完时，点击“标记已用完”，再点“选择下一个可用账号”。
6. 使用“打开 Typeless”“打开邮箱”“复制邮箱”完成手动登录或注册核验。
7. 如果账号已关联 MoeMail ID，可以点“读取当前账号邮件”查看邮件摘要，再兜底处理验证码。
8. 日常推荐：装好权限与 MoeMail API Key 后，让 **Typeless Switchboard 在后台跑着**（菜单栏有图标；关窗默认不退出）。它会自己监测额度，剩余 &lt; 200 时静默换号。
9. 侧栏确认 **「无感额度守护」** 与 **「池空时自动注册新号」** 已打开；热备数量默认 1。需要立刻换时可点 **「智能换号」**；一定要全新号再点「强制全自动注册新号」。
9. 如果本机没有 Node/npm/Playwright，或 Typeless 页面结构发生变化，工具会保留自动化脚本路径、邮箱、用户名、验证码和最近日志；可复制结果后手动兜底。
10. 需要集中准备资料时，在“账号池工具”里批量生成候选账号。
11. 在“兜底确认队列”里核验每个候选账号，点“确认”后才会进入可用池。
12. 只想半自动换已有账号时点“准备切换”，工具会打开本机 Typeless App、选择账号、复制邮箱并打开邮箱入口。
13. 账号很多时，用“复制 CSV / 导入 CSV”和表格工具批量整理；每周新周期用「复活已用尽的账号」。
14. 用侧边栏搜索和状态筛选快速定位账号；需要留档时点“复制摘要”。
15. 定期点“复制体检报告”，检查重复邮箱、未填邮箱、待确认核和低额度账号。
16. 需要核验本机环境时，可点“复制设备信息”或“生成登录态快照”，得到可留档的本机报告。
17. 遇到“不知道卡在哪”时，先点“一键自检”，再点“复制权限清单”或“复制完整排障包”查看入口、邮箱、权限和账号池状态。
18. 如果已有 `typeless-toolkit/accounts.json`，复制其内容后点“导入 toolkit 账号”；导入后会进入待确认核队列，token 字段会转为指纹记录。

## macOS 权限

为了让“一键换号”能真正退出旧号、清理 Chrome 网页会话、接收验证码并把新号交给桌面 App，建议一次性打开：

- 辅助功能 Accessibility：给 `TypelessSwitchboard.app`，用于自动点击 Chrome / System Events 弹窗。
- 自动化 Automation / Apple Events：给 `TypelessSwitchboard.app` 控制 Google Chrome、System Events、Typeless.app。
- Google Chrome 外部协议：Chrome 弹出“要打开 Typeless.app 吗？”时勾选“始终允许 www.typeless.com 在关联的应用中打开此类链接”。
- 麦克风 Microphone：给 `Typeless.app`，新号切入后可直接录音/转写。
- 输入监听 Input Monitoring：给 `Typeless.app`，保证全局快捷键/Fn 键可用。
- 屏幕录制 Screen Recording：给 `Typeless.app`，保证浮窗、上下文识别和引导步骤不被权限卡住。
- 通知 Notifications：给 `Typeless.app`，方便接收后台状态提醒。
- 钥匙串 Keychain：允许 `TypelessSwitchboard.app` 读取 MoeMail API Key 并保存新账号强密码。

应用右侧“连接设置”里可以点“打开权限设置”直达对应系统设置页，也可以点“复制权限清单”发给手动排障。

## 全自动一键换号流程

点一次「全自动一键换号」，工具会做完这些事：

1. **预检**：macOS 权限 + Node/npm/Playwright/Chromium 运行环境，缺什么先补什么
2. **清场**：退出 Typeless、备份隔离旧的桌面登录态与浏览器登录态、清 Chrome 的 Typeless 站点数据
3. **建号**：调 MoeMail 生成新邮箱 → 生成用户名与强密码（**密码只进 Keychain，不落明文**）
4. **注册**：用账号专属的 Chromium profile 跑 Playwright 脚本填表，
   脚本文件不含明文密码，密码经进程环境变量注入
5. **收码**：轮询 MoeMail 取验证码，写进桥接文件交给浏览器脚本继续提交
6. **判定**：只有浏览器结果证明注册完成（进到 Dashboard/成功页）才算成功，
   否则保留为「待兜底确认」，旧账号状态不变 —— **不会把你正在用的号弄丢**
7. **收尾**：同步 Chrome 的网页登录态到新号、打开 Typeless handoff、跳过桌面端新手引导

每一步的完整细节、脚本路径、以及注册卡住时的排查方法，见
**[docs/AUTOMATION.md](docs/AUTOMATION.md)**。

## 跨平台兼容

- 本台 macOS 是当前最高优先级和已真实验证路径；不要为 Windows 适配破坏这条稳定链路。
- `Sources/TypelessSwitchboardCore/PlatformCompatibility.swift` 固化了 typeless-toolkit 的 macOS / Windows 路径、凭据、device.cache 和 resetDevice 差异。
- `scripts/typeless-portable-preflight.js` 提供 Windows/macOS 只读预检：不删凭据、不删文件、不启动 Typeless，只检查配置和默认路径是否就绪。
- 详细矩阵见 `docs/cross-platform-compatibility.md`。

只读预检：

```bash
node scripts/typeless-portable-preflight.js
```

Windows 可用：

```powershell
node scripts/typeless-portable-preflight.js --config config.local.json
```

## 开机轻量额度守护（推荐：不必一直开着 App）

适合「不想让工具常驻后台，但额度低了要自动换号」：

```bash
# 打包 App（若还没有）并安装 LaunchAgent：登录后 + 每 1 分钟单次巡检
./scripts/install-quota-guard.sh

# 立刻手动跑一轮（无界面）
./scripts/install-quota-guard.sh --run-once

# 查看状态 / 卸载
./scripts/install-quota-guard.sh --status
./scripts/install-quota-guard.sh --uninstall
```

或在 App 侧栏点 **「安装/更新开机插件」**。

行为说明：

1. 插件定时唤醒：`TypelessSwitchboard.app … --daemon-check`
2. 读取本机 Typeless 登录态与官方额度
3. **剩余 ≥ 阈值**：只记日志，进程退出（不换号）
4. **剩余 &lt; 阈值**：静默换号（含设备身份轮换）；失败则全自动注册换号
5. 日志：`~/Library/Application Support/TypelessSwitchboard/Logs/`

也可用自定义间隔（分钟）：

```bash
INTERVAL_MINUTES=5 ./scripts/install-quota-guard.sh
```


## 重试最近自动化

当全自动流程因为网络、Playwright、页面加载或验证码等待暂时失败时，不需要重新创建邮箱账号。右侧“最近自动换号”会保留账号 ID、脚本路径、验证码桥接文件、账号专属浏览器登录态目录和浏览器结果 JSON。点击“重试最近自动化”后，工具会：

1. 读取上次账号 ID 和 Keychain 密码。
2. 如果已有验证码，重新写入验证码桥接文件。
3. 复用上次 Playwright 脚本重新执行；脚本会忽略上次遗留的旧 `NO_CODE` 桥接内容，继续等待本次新写入的验证码或新的 `NO_CODE`。
4. 重新读取浏览器结果 JSON。
5. 只有结果证明注册完成时，才把账号标记为可用，并可通过“打开新账号会话”进入保留登录态的浏览器窗口。

## 验证和打包

运行本地运营能力验收：

```bash
./scripts/test-operational-features.sh
```


运行本地浏览器自动化 smoke check（默认只做快速、可控检查，不触发外部浏览器下载）：

```bash
./scripts/test-browser-automation-smoke.sh
```

需要完整本地 Playwright 页面驱动验证时再显式启用：

```bash
RUN_PLAYWRIGHT_SMOKE=1 ./scripts/test-browser-automation-smoke.sh
```

完整 smoke 会创建本地 mock 注册页，验证脚本填表、验证码桥接、提交和结果 JSON 回写；如果 npm/Chromium 下载环境异常，常规验收不会被卡死。

也可以直接通过 SwiftPM 执行验收 target：

```bash
swift run OperationalFeatureChecks
```

打包 macOS App：

```bash
./scripts/build-app.sh
```

打包产物位于：

```text
$HOME/Library/Caches/TypelessSwitchboard/TypelessSwitchboard.app
```

`build-app.sh` 会在组装 `.app` 后执行本机 ad-hoc 签名，方便用 `codesign --verify --deep --strict TypelessSwitchboard.app` 做本地完整性校验。

## 数据保存位置

账号和设置保存在：

```text
~/Library/Application Support/TypelessSwitchboard/store.json
```

自动化脚本、验证码桥接、结果 JSON、新号浏览器 profile，以及旧桌面/网页登录态备份保存在：

```text
~/Library/Application Support/TypelessSwitchboard/Automation/
```

需要重置工具数据时，退出应用后删除这个文件即可。

---

## 📧 邮箱服务配置

自动注册新号需要一个能收验证码的邮箱。在 App 的「连接设置」里填三项：

| 配置项 | 填什么 |
|---|---|
| 官方注册入口 | 默认 `https://www.typeless.com/login` |
| 邮箱服务 URL | 你自建服务的 API 根路径，如 `https://mail.yourdomain.com`（**必须 HTTPS**） |
| API Key / 卡密 | 你自己设的访问令牌，防止域名邮箱被别人盗刷 |

**怎么搭这个服务**：完整教程见 **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** ——
从买域名、DNS 托管 Cloudflare、配置 MX/SPF/DKIM/DMARC，到部署邮箱 API，
附可直接粘贴的 Cloudflare Worker 代码（约 100 行）和三条验证用的 `curl`。

需要的接口只有 4 个（鉴权头统一是 `X-API-Key`）：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/config` | 自检 + 取可用域名 |
| GET | `/api/emails` | 列出已有邮箱 |
| POST | `/api/emails/generate` | 生成随机邮箱 |
| GET | `/api/emails/{id}` | 取该邮箱收到的邮件（轮询验证码） |

字段名有容错：邮件对象认 `id/_id/messageId`、正文认 `text/body/content/preview`、
时间认 `createdAt/receivedAt/date`，用哪个都行。

也可以直接用现成的开源项目 [moemail](https://github.com/beilunyang/moemail)，
它本身就是按这套 API 设计的。

---

## 常见问题

**Q：一定要自建邮箱服务吗？**
只有「自动注册新号」需要。已经有一批账号的话，直接加进池子就能自动轮换，
邮箱服务可以完全不碰。

**Q：免费额度到底怎么刷新，是周一还是用满 7 天？**
**官方没有说明**（定价页与账单 FAQ 只写「每周 8000 字」）。所以本工具不替你下定论：
它每次拿到额度就采样，发现数值骤降就记为一次真实重置，攒够样本后自动校准口径。
在「额度守护」页底部可以看到当前结论是「待确认」还是「已确认，依据 N 次实测」。
系统时区与实际所在地不一致的话，那里还能一键改刷新时区，**不用重启**。

**Q：注册时取不到验证码？**
按顺序排查：① `docs/DEPLOYMENT.md` 里的三条 `curl` 是否全通；
② `dig MX 你的域名.com` 看 MX 是否生效；③ Catch-All 规则的 Action 是不是 **Send to Worker**；
④ 验证码邮件可能被判垃圾，去邮箱原始内容里翻一下。

**Q：中国大陆自建会踩 25 端口的坑吗？**
按本文的 Cloudflare 方案**不会** —— 收信只需要 MX 记录指向 Cloudflare，
你自己从不主动发起 SMTP 连接。只有「自建邮局」（Mailu / Poste.io 之类）才会踩到
国内云厂商默认封禁 25 出方向的问题。

**Q：换台电脑怎么办？**
```bash
# 旧机器导出
/Applications/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard --export-full-bundle
# 新机器导入（按邮箱去重，已有账号不会重复添加）
/Applications/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard --import-bundle <文件路径>
```
密码在 macOS Keychain、登录态与设备身份绑定，这两样要在新机器上重建 ——
这是 Typeless 服务端的限制，绕不过去。

**Q：会不会把我正在用的号弄丢？**
不会。只有浏览器结果明确证明注册完成（进到 Dashboard / 成功页）才会切换，
否则新号保留为「待兜底确认」，**旧账号状态不变**。

**Q：密码安全吗？**
强密码只写进 macOS Keychain，账号池里只存一句「已保存到 Keychain」的提示。
生成的自动化脚本不含明文密码，密码经进程环境变量注入。

---

## 参与贡献

欢迎提 Issue 和 PR。动手前请注意：

- 改动**必须**跑通 `swift run OperationalFeatureChecks`（当前 451 条断言）与
  `./scripts/test-browser-automation-smoke.sh`
- 不要在本仓库提交任何真实账号、密码、API Key 或 `store.json`
- 涉及 Typeless 客户端内部行为的改动，请在描述里说明**是怎么验证的** ——
  这个项目吃过「以为对了其实没验证」的亏

相关文档：

- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) —— 从零部署
- [docs/AUTOMATION.md](docs/AUTOMATION.md) —— 一键换号每一步的细节
- [docs/cross-platform-compatibility.md](docs/cross-platform-compatibility.md) —— 跨平台兼容矩阵
- [CHANGELOG.md](CHANGELOG.md) —— 版本记录

---

## 许可

[MIT](LICENSE)。你可以自由使用、修改、分发，包括商用。

Typeless 是第三方产品，本项目与之无隶属关系。请遵守 Typeless 自身的
[服务条款](https://www.typeless.com/terms)。批量注册多账号存在被限制的风险，请自行判断。
