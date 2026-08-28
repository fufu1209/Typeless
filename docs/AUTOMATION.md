# 全自动一键换号流程

> 从 README 拆出来的细节文档。只想用起来的话看 README 的「快速开始」就够了，
> 这份是给「想知道每一步到底做了什么 / 注册卡住了要排查」的人看的。


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
16. 只有浏览器结果证明注册完成时，才把新账号标记为可用并把当前账号标记为本周用完；如果页面无需验证码或浏览器已进入 Dashboard/Workspace，也以浏览器完成结果为准，不会因为 Swift 端没有提取到验证码而误退回兜底确认。
17. 注册完成后会把 Google Chrome 的 Typeless 网页会话同步到新账号，并打开 Typeless handoff；如果 Chrome 弹出“要打开 Typeless.app 吗？”，工具会先勾选“始终允许 www.typeless.com...”，再点击“打开 Typeless.app”。成功路径不会自动打开账号专属 Playwright/Chromium 额外浏览器；该 profile 只保留用于右侧“打开新账号会话”手动排查。桌面端新手引导会尽量自动完成或跳过；自动化结果会记录被替换的旧账号，旧账号会标记为本周已用完。
18. 如果结果仍停在注册/验证/错误页面，旧账号状态不变，新账号保留为待兜底确认，并在右侧“最近自动换号”里保存账号 ID、状态、验证码、脚本路径、验证码桥接文件、浏览器结果 JSON、浏览器登录态目录和日志；点击“重试最近自动化”可复用同一账号和脚本继续执行。
