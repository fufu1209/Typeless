# Typeless Switchboard

一个兼容 macOS 的本地账号切换辅助工具，用来管理账号邮箱、每月额度状态，并完成 Typeless + Chrome + MoeMail 的全自动一键换号流程。

## 这个工具能做什么

- 管理 Typeless 账号、邮箱、域名、额度和备注。
- 自动挑出下一个可用账号。
- 一键打开 Typeless 登录页、MoeMail 控制台或账号对应的邮箱入口。
- 可打开本机 Typeless App、Typeless 官网，并检查 Typeless 入口是否可访问。
- 一键自检 Typeless App、官网入口、MoeMail 配置、Node/npm/Playwright 缓存、macOS 权限和账号池可切换状态。
- 复制邮箱地址，记录已用字数，标记本月额度已用完。
- 保存本地切换检查清单，避免每次手动换号时漏步骤。
- 本地保存 MoeMail API Key 到 macOS 钥匙串；密钥不会写入仓库。
- 从 MoeMail 读取已有邮箱列表，并导入到账号池。
- 通过 MoeMail API 生成邮箱并导入账号池。
- 一键用 MoeMail 生成注册候选账号：创建真实邮箱、生成用户名、复制强密码，并放入兜底确认队列。
- 读取当前已关联 MoeMail 邮箱的邮件摘要，方便兜底查看验证码邮件。
- 全自动一键换号：先退出并备份隔离本机 Typeless 桌面登录态、关闭并备份隔离工具旧浏览器登录态、清理 Google Chrome 里的 Typeless 网页旧账号，再创建新 MoeMail 邮箱、生成 Typeless 账号资料、保存强密码到 macOS 钥匙串、后台驱动登录/注册页、轮询邮件验证码、提取验证码并自动填表提交。
- 自动生成 Playwright 注册脚本，脚本和账号专属浏览器登录态目录保存在本机 Application Support 目录，可自动运行，也可在页面结构变化时手动重试。
- 注册成功后会把 Google Chrome 的 Typeless 网页会话切到新账号，再打开 Typeless handoff / desktop deep link，让桌面 App 接到新号；如果出现 Chrome 的“要打开 Typeless.app 吗？”提示，会先勾选“始终允许 www.typeless.com...”，再点击“打开 Typeless.app”。桌面端新手引导会尽量自动完成或跳过。最近一次自动换号结果会保留在右侧状态区，可复制排查；账号专属 Playwright/Chromium profile 只保留作兜底，不会在成功后自动弹出额外浏览器，只有手动点“打开新账号会话”才会打开。
- 右侧“连接设置”提供“打开权限设置”和“复制权限清单”，可快速处理辅助功能、自动化、麦克风、输入监听、屏幕录制、Chrome 外部协议和钥匙串授权。
- 随机生成候选用户名、邮箱地址和强密码，减少手动输入。
- 提供注册助手 / 兜底面板：自动流程卡住时，可复制邮箱、用户名、验证码，打开注册页和邮箱，记录核验完成。
- 提供“准备切换”：把当前账号标记为本月已用完，选择下一个可用账号，复制邮箱，并打开 Typeless 与邮箱入口。
- 批量生成候选账号资料，方便之后自动注册或逐个兜底核验。
- 候选账号只在自动化无法证明注册完成时进入“兜底确认队列”；正常全自动一键换号成功后会直接自动确认。
- 通过剪贴板复制/恢复账号池 JSON 备份。
- 通过剪贴板复制/导入账号 CSV，方便和表格工具配合整理大批账号。
- 月初批量重置已确认账号的本月额度。
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
8. 想换一个新的积分账号时，直接点左侧或右侧的“全自动一键换号”；工具会先处理 Google Chrome 里遗留的 Typeless.app 弹窗，再退出本机 Typeless App、隔离旧桌面登录态和工具旧网页登录态、清理 Google Chrome 里的 Typeless 旧网页账号，然后创建新邮箱、保存密码、后台驱动 Typeless 邮箱登录/注册、读取验证码并提交，成功后把 Chrome 和桌面 App 都切到新号。
9. 如果本机没有 Node/npm/Playwright，或 Typeless 页面结构发生变化，工具会保留自动化脚本路径、邮箱、用户名、验证码和最近日志；可复制结果后手动兜底。
10. 需要集中准备资料时，在“账号池工具”里批量生成候选账号。
11. 在“兜底确认队列”里核验每个候选账号，点“确认”后才会进入可用池。
12. 只想半自动换已有账号时点“准备切换”，工具会打开本机 Typeless App、选择账号、复制邮箱并打开邮箱入口。
13. 账号很多时，用“复制 CSV / 导入 CSV”和表格工具批量整理；每月新周期用“月初重置已确认账号”。
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

点击“全自动一键换号”后，工具会按顺序执行：

1. 先做 macOS 权限预检：辅助功能、自动化 Apple Events、Google Chrome 外部协议、Typeless 常用权限会在创建新邮箱前检查/触发；关键权限未开时会先暂停并打开系统设置，避免注册跑到中途才卡权限。随后准备 Node/npm/Playwright/Chromium 自动化运行环境；首次自检/首次换号会安装并写入 ready marker，后续只有在 Playwright 包和 Chromium 可执行文件都真实存在时才跳过 `npm install` 和 `playwright install`；如果失败，不创建新邮箱账号。
2. 先处理 Google Chrome 里可能遗留的“要打开 Typeless.app 吗？”弹窗：勾选“始终允许 www.typeless.com 在关联的应用中打开此类链接”，再点击“打开 Typeless.app”，避免上一次 handoff 卡住。
3. 退出本机 Typeless App，并把旧桌面登录态目录备份隔离到 `Automation/DesktopSessionBackups/<时间>/`；随后在原路径创建空目录，避免桌面 App 继续沿用旧账号。
4. 关闭本工具之前打开的 Typeless 持久浏览器窗口，并把旧 `Automation/BrowserProfiles/` 整体备份隔离到 `Automation/BrowserSessionBackups/<时间>/`；随后创建新的空 `BrowserProfiles/`，避免旧网页登录态影响新号。
5. 打开/复用 Google Chrome 的 Typeless 标签，清理 `typeless.com` 的 localStorage、sessionStorage、Cookie、IndexedDB 和 Cache，让 Chrome 也不再停留在旧 Typeless 账号。
6. 调用 MoeMail API 创建新的邮箱。
7. 生成 Typeless 用户名和强密码。
8. 把强密码保存到 macOS Keychain，账号池里只保存“已保存到 Keychain”的提示。
9. 生成 Playwright 注册脚本到：

```text
~/Library/Application Support/TypelessSwitchboard/Automation/
```

验证码桥接文件和浏览器结果 JSON 也位于同一个目录。脚本会等待验证码文件出现，避免验证码到达后重新打开页面丢失注册上下文；提交后会写回结果 JSON，App 会检查最终 URL/页面标题；只有结果像 Dashboard/工作台/成功页时才判定“完成”，否则进入“待兜底确认”。自动化脚本文件不写入明文密码，密码只从 Keychain 读取后通过当前进程环境变量传给脚本。

10. 执行前先用 `node --check` 检查脚本语法；一键自检和正式执行都会准备/复用 Playwright 运行时，所有 npm/Playwright 步骤都有超时兜底，App 会为 Finder 启动场景补充 `~/.local/bin`、Homebrew 等常见 Node 路径。
11. 在自动化目录本地安装/复用 Playwright 后，通过 `node <script>` 使用账号专属 Chromium profile 在后台填写注册页；注册前会清理该新号 profile，并尝试点击 Typeless 的 Logout/Log out/Sign out/登出/退出，避免页面残留会话影响新号注册。密码通过进程环境变量注入，脚本文件不保存明文密码。脚本兼容单页注册、多步骤 Continue/Next、确认密码、`name`/`id`/`aria-label`/`placeholder`/`label for`/`data-testid`/`data-cy` 风格输入框、分格 OTP 验证码、`verification_code`/`type=tel`/PIN 类单个验证码框、必选条款/隐私复选框、自定义 `role="checkbox"`，以及 `<button>`、`<a>` 链接、`input[type=button/submit]`、`data-testid`/`data-cy` 和 `role="button"` 风格的注册/发码/提交控件；如果页面里有隐藏模板字段或隐藏按钮排在前面，脚本会跳过不可见/不可编辑项，优先使用可见真实控件；遇到没有显式提交按钮的表单，会在验证码输入后按 Enter 兜底提交；遇到常见 Cookie/隐私弹窗会自动点击 Accept/Agree/同意/关闭类按钮，避免遮挡表单。注册成功后的网页登录态会保留在该账号的浏览器 profile 目录里，不会因脚本关闭而直接丢失。
12. 浏览器脚本会先寻找 Send code/Get code/验证邮箱等按钮；如果填写账号资料后还需要 Continue/Next 才出现发码按钮，会自动推进一步后再次寻找发码按钮。随后页面保持打开，并等待本机验证码桥接文件。
13. Swift 轮询 MoeMail 当前邮箱邮件，自动提取 4-8 位验证码；轮询采用“前几次 1-2 秒快速检查、后续退避”的 schedule，既更快拿到常见秒到验证码，又保持总窗口覆盖浏览器验证码桥接等待时间，避免验证码邮件稍慢到达时过早写入 `NO_CODE`；支持连续数字、空格分隔或短横线分隔的常见邮件格式。
14. 提取到验证码后复制到剪贴板，同时写入验证码桥接文件；浏览器脚本读取后继续填入并提交。
15. 浏览器提交后会等待 Dashboard/Workspace/成功页或明确错误页出现，兼容“创建工作区中/异步跳转”的延迟状态；成功页文案也支持 `You're all set`、`Account created` 等常见表达，然后写回结果 JSON，工具读取最终 URL 和页面标题。
16. 只有浏览器结果证明注册完成时，才把新账号标记为可用并把当前账号标记为本月用完；如果页面无需验证码或浏览器已进入 Dashboard/Workspace，也以浏览器完成结果为准，不会因为 Swift 端没有提取到验证码而误退回兜底确认。
17. 注册完成后会把 Google Chrome 的 Typeless 网页会话同步到新账号，并打开 Typeless handoff；如果 Chrome 弹出“要打开 Typeless.app 吗？”，工具会先勾选“始终允许 www.typeless.com...”，再点击“打开 Typeless.app”。成功路径不会自动打开账号专属 Playwright/Chromium 额外浏览器；该 profile 只保留用于右侧“打开新账号会话”手动排查。桌面端新手引导会尽量自动完成或跳过；自动化结果会记录被替换的旧账号，旧账号会标记为本月已用完。
18. 如果结果仍停在注册/验证/错误页面，旧账号状态不变，新账号保留为待兜底确认，并在右侧“最近自动换号”里保存账号 ID、状态、验证码、脚本路径、验证码桥接文件、浏览器结果 JSON、浏览器登录态目录和日志；点击“重试最近自动化”可复用同一账号和脚本继续执行。


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

## 运行

```bash
./scripts/run.sh
```

也可以直接运行：

```bash
swift run TypelessSwitchboard
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
/Users/fucaixie/BC/Typeless/TypelessSwitchboard.app
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
