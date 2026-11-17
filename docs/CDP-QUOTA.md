# 额度直读（CDP）设计说明

> 适用版本：Typeless 2.12.0 / Electron 43.8.4 / Chrome 150（2026-11-17 本机实测）
> 对应 App 版本：v2.8.0

## 1. 为什么要换链路

Typeless 的周额度只有服务端知道，接口是：

```http
POST https://api.typeless.com/user/usage_stats
Content-Type: application/json

{"params": {}}
```

2026-10 起，这个接口对「非官方客户端」加了两道门：

| 门 | 表现 | 谁能过 |
| --- | --- | --- |
| **客户端签名** | `403` / `code 20006` / `This client is not supported. Please use the official Typeless app.` | App 自己的 API 客户端 |
| **JA3/TLS 指纹白名单** | `418` / `code 101010100` / `ja3_tls_code` | Electron/Chromium 的握手；Node/OpenSSL 不行 |

实测（`node extract-active-session.js`）：

```json
{"errorCode":"API_HTTP_ERROR",
 "error":"API 额度拉取失败 (HTTP 418): Request failed due to a client-side error (code: 101010100)…"}
```

也就是说：**签名算对了也没用** —— TLS 握手阶段就被拒了。
v2.7.5 的「读屏 OCR」是当时的唯一出路，但它依赖屏幕录制权限 + 窗口可见，
解析还得跟界面文案赛跑。

## 2. 直读做了什么

```text
┌────────────────┐   CDP (ws://127.0.0.1:9333)   ┌──────────────────────────┐
│ TypelessSwitch │ ────────────────────────────▶ │ Typeless 渲染进程         │
│ board (Swift)  │   Runtime.evaluate(JS)        │  floating-bar.html / hub  │
└────────────────┘ ◀──────────────────────────── │   ↓ import() App 的客户端 │
                                                │   ↓ post('/user/usage_stats')│
                                                └───────────┬──────────────┘
                                                            │ 官方签名 + Chromium TLS
                                                            ▼
                                                   api.typeless.com
```

关键点：

1. **Typeless 带 `--remote-debugging-port=9333` 启动**（Electron 原生支持）。
2. 连上 `/json/list` 里最合适的页面：`floating-bar`（常驻、不遮挡、不打断听写）
   → `hub` → 任意 Typeless 页面。
3. 用 `Runtime.evaluate` 跑一段受控 JS：
   - 从 `link[rel=modulepreload]` 拿到页面已预载的 chunk URL；
   - 逐个 `import()`，找**形状**为「导出对象带 `post` 与 `buildUrl`」的模块 ——
     那就是 App 自己的 API 客户端（2.12.0 里是 `fw3XiDt9.js` 的 `y`，
     但导出名和文件名都会随版本变，所以不硬编码）；
   - `await client.post('/user/usage_stats', { params: {} })`；
   - 顺带 `ipcRenderer.invoke('auth:get-current')` 取 `email` / `user_id`
     （**只取这两个字段，令牌不出渲染进程**）。
4. 解析 `data.data.voice_transcription`：

```json
{"total_words":179,"avg_wpm":222.82,"mins_saved":5.52,
 "week_word_usage_limit":23333,"week_word_usage_value":179}
```

`remaining = week_word_usage_limit - week_word_usage_value`。

## 3. 为什么不是「读 App 的缓存」

翻过这些地方，**都没有**周额度字段（v2.7.5 已经查过一轮，v2.8.0 复核）：

- `~/Library/Application Support/Typeless/*.json`（`app-settings` / `app-storage` / `app-onboarding`）
- `typeless.db`（SQLite，只有听写历史）
- `Local Storage` / `IndexedDB`（只有 onboarding 与提示类标记）

额度只在内存里，每次打开界面现拉。所以「直读」是唯一不依赖 UI 的实时来源。

## 4. 失败模式与对应处置

| `--probe-quota` 输出 | 含义 | 处置 |
| --- | --- | --- |
| `端口 9333 没有进程监听` | Typeless 没带调试端口启动，或没运行 | 点「带端口重启 Typeless」；或 `node scripts/probe-quota-cdp.js --launch` |
| `端口上不是 Typeless（UA 不匹配）` | 端口被别的 Electron 应用/DevTools 占用 | 换端口（设置里改，或 `--port`） |
| `没有可用的渲染页面` | App 刚启动、渲染进程还没建好 | 等 2–5 秒重试 |
| `拿不到额度：{"ok":false,"error":"no-client"…}` | 页面里没有可识别的客户端模块 | 版本升级导致结构变化 → 看下一节 |
| `拿不到额度：{"ok":false,"error":"no-quota"}` | 客户端找到了，但响应里没有 `voice_transcription` | 可能未登录 / 会话过期 → 看 App 界面 |

调用方（`SwitchboardStore.syncActiveAppSessionAndQuota`）的顺序是：

```
CDP 直读 → 官方接口（历史路径，基本已死）→ 读屏 OCR → 本地缓存估算
```

直读失败**不会**改变原有行为，只是少一条更快更准的路径。

## 5. 版本升级后的排障顺序

Typeless 每次大版本都可能改渲染层结构。按这个顺序查，通常 10 分钟内能定位：

1. `node scripts/probe-quota-cdp.js` —— 看 `clientChunk` 还是不是老名字；
2. 若报 `no-client`：在渲染进程里手动找客户端。先 `curl http://127.0.0.1:9333/json/list`
   拿到目标页的 `webSocketDebuggerUrl`，用任一 CDP 客户端（或 Chrome 的
   `devtools://devtools/bundled/inspector.html?ws=…`）连上去，在 Console 里跑：
   ```js
   const urls = [...document.querySelectorAll('link[rel=modulepreload]')].map(l => l.href);
   for (const u of urls) { const m = await import(u); for (const k of Object.keys(m)) {
     const c = m[k]; if (c && typeof c.post === 'function' && typeof c.buildUrl === 'function') console.log(u, k);
   }}
   ```
3. 若连 `modulepreload` 都没有：探针会自动退回 `Debugger.enable` +
   `Debugger.scriptParsed` 列脚本（v2.8.0 已实现，不需要改代码）；
4. 若客户端不再带 `post` / `buildUrl`（比如改成裸 `fetch`）：那就需要重新找
   「带签名的请求函数」，形状判据要跟着改 —— 这是唯一需要改代码的情形。

## 6. 安全边界

- DevTools 端口只监听 `127.0.0.1`，但**同机任意进程都能连上** —— 这是 CDP 的固有属性，
  和「打开开发者工具」等价。不需要直读时可在设置里关掉（关掉后不再带端口启动）。
- 直读过程中拿到的 `auth:get-current` 含 access/refresh token。实现里**只取
  `email` / `user_id`**，令牌不出渲染进程；任何进入日志的原始报文都要先过
  `TypelessQuotaBridge.redactSecrets`（JWT 与 40–64 位十六进制密钥 → `<redacted>`）。
- 直读不修改任何 App 状态：只发一次 `usage_stats`（只读接口），不写会话、不点按钮、
  不切账号。

## 7. 为什么不再用「时间盲轮换」兜底

v2.7.1 的降级模式是「额度读不到 → 每 90 分钟强制换一个号」。它保证「不卡在死号上」，
但代价很实在：每次切换都要轮换设备身份 + 重写桌面会话 + 等 Electron 读盘
（热启动 5–10 秒，冷启动实测到过 120 秒），期间用户正在听写。

直读把这件事变回它本来的样子：**只有真的快用完才切**。降级模式仍然保留，
但应该只在「端口被关掉 + 没授屏幕录制」这种极端组合下才会被触发。
