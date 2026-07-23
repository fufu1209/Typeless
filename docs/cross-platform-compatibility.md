# Typeless Switchboard 跨平台兼容策略

目标：**本机 macOS 已验证链路保持稳定**，同时把 `typeless-toolkit` 的 Windows/macOS 平台差异收敛为可测试矩阵，后续在另一台 Mac 或 Windows 上只需要填配置并通过预检，就能接入同一套一键换号核心流程。

## 当前支持级别

| 平台 | 状态 | 说明 |
|---|---|---|
| macOS（本机） | 本机已验证 | SwiftUI App 已真实跑通过：MoeMail 生成邮箱、Typeless 注册/验证码、Chrome 会话同步、桌面端 handoff、新手引导跳过、设备身份重置。 |
| macOS（其他电脑） | 兼容 | 路径/权限/API Key/Typeless 安装位置可能不同；先跑一键自检或 `scripts/typeless-portable-preflight.js`。 |
| Windows | toolkit 兼容矩阵已纳入 | 路径、进程名、Credential Manager 目标、device.cache 位置按 `typeless-toolkit` 的 `lib/platform.js` 固化；Windows 原生壳层/GUI 需要后续按此矩阵接 UI。 |
| Linux | 计划适配 | 源项目标注 Linux 未适配；必须显式填写可执行文件、数据目录、设备缓存目录和凭据删除策略后才能升级。 |

## 已纳入的 typeless-toolkit 关键点

### Windows

- 进程名：`Typeless.exe`
- 可执行文件默认：`%LOCALAPPDATA%\Programs\Typeless\Typeless.exe`
- 登录态目录：`%APPDATA%\Typeless.exe`
- 设备缓存：`%APPDATA%\Typeless\Cache\device.cache`
- 设备凭据：`Typeless.deviceIdentifier`
- 凭据删除：`cmdkey /delete:Typeless.deviceIdentifier`

### macOS

- 进程名：`Typeless`
- 可执行文件默认：`/Applications/Typeless.app/Contents/MacOS/Typeless` 或 `~/Applications/Typeless.app/Contents/MacOS/Typeless`
- 登录态目录候选：`~/Library/Application Support/Typeless.exe`、`~/Library/Application Support/Typeless`
- 设备缓存候选：
  - `~/Library/Application Support/now.typeless.desktop/device.cache`
  - `~/Library/Application Support/Typeless/Cache/device.cache`
  - `~/Library/Application Support/Typeless.exe/Cache/device.cache`
- 设备凭据：
  - `service=now.typeless.desktop.deviceIdentifier, account=now.typeless.desktop.security.auth_key`
  - 兼容旧目标：`Typeless.deviceIdentifier`
- 凭据删除：Security.framework `SecItemDelete` + `security delete-generic-password` 兜底。

## resetDevice 标准步骤

1. 退出 Typeless 桌面进程。
2. 删除平台设备凭据：Windows Credential Manager / macOS Keychain。
3. 删除 `device.cache`。
4. 删除 `user-data.json`。
5. 清理 `app-storage.json` 中的 `userData`、`quotaUsage`、`session`、`currentRoute`。
6. 清理 Electron 残留目录：`Local Storage`、`Network`、`Cookies`、`Session Storage`。
7. 重新启动 Typeless，等待新设备身份生成。
8. 完成网页注册后同步 Chrome 会话并执行桌面端 handoff。
9. 写入/延迟重写新手引导完成状态。

## 静默换号与设备用户数上限

Typeless 服务端会对**同一 deviceId 上登录过的用户数**设限。历史实现里：

- 全自动一键换号会 `resetDevice`
- 无感/智能静默换号只注入 `user-data.json`，**不换设备身份**

这会在长期无感轮切后触发：

`The number of users logged into this device has exceeded the limit.`

当前 macOS 主流程已补齐：

1. **静默换号前也执行设备身份重置**（Keychain + `device.cache` + 登录残留），再写入目标会话。
2. **同步官方额度时识别设备用户数超限**（`DEVICE_USER_LIMIT` / 英文与中文文案）。
3. **命中超限时跳过静默池切换**，直接降级为全自动 `resetDevice` + 注册/handoff。
4. 静默切换成功与否以**目标邮箱校验通过**为准；未验证成功不标记旧号用完。

## 保护当前稳定状态的护栏

- macOS 主程序仍是当前 SwiftUI/AppKit/Security/Apple Events 路线，不被 Windows 逻辑覆盖。
- 平台兼容信息放在 `Sources/TypelessSwitchboardCore/PlatformCompatibility.swift`，由测试固定。
- `scripts/typeless-portable-preflight.js` 是只读预检，不删除凭据、不删文件、不启动 Typeless。
- `Tests/OperationalFeatureChecks` 会检查：
  - macOS 本机 profile 仍是 `productionVerified`。
  - Windows profile 与 `typeless-toolkit` 默认路径/凭据一致。
  - Linux 显式为 `planned`，避免误报已支持。
  - 便携预检脚本通过 `node --check` 且在本机只读运行。

## 其他电脑使用顺序

### 另一台 Mac

1. 安装 Typeless、Google Chrome、Node.js。
2. 填 MoeMail 地址/API Key/域名。
3. 运行：

```bash
node scripts/typeless-portable-preflight.js
```

4. 打开 App 里的一键自检，处理辅助功能/自动化/Chrome 外部协议/Typeless 麦克风输入监听屏幕录制权限。
5. 点“全自动一键换新账号”。

### Windows

当前仓库已经具备 Windows 兼容矩阵和只读预检脚本；要达到和 macOS App 同等的一键体验，需要补一个 Windows 壳层，复用这些模块：

- MoeMail API 生成邮箱。
- Playwright 注册/验证码桥接脚本。
- Windows Credential Manager resetDevice。
- Windows Chrome/Typeless 协议 handoff。
- Windows 本地安全存储（Credential Manager 或 DPAPI）保存 API Key/密码。

预检命令：

```powershell
node scripts/typeless-portable-preflight.js --config config.local.json
```

`config.local.json` 可填：

```json
{
  "typeless_exe": "C:\\Users\\你\\AppData\\Local\\Programs\\Typeless\\Typeless.exe",
  "userdata_dir": "C:\\Users\\你\\AppData\\Roaming\\Typeless.exe",
  "device_cache_dir": "C:\\Users\\你\\AppData\\Roaming\\Typeless\\Cache",
  "credential_target": "Typeless.deviceIdentifier"
}
```

## 当前结论

- **本台 Mac：已完成并保持优先级最高。**
- **另一台 Mac：配置和权限补齐后可按同一套逻辑跑。**
- **Windows：底层平台矩阵已纳入并有只读预检；完整 GUI/一键壳层需下一步按这个矩阵封装，不能直接把 macOS App 原样拿去 Windows。**
- **Linux：不宣称已完成，保持 planned，避免误导。**
