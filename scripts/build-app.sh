#!/usr/bin/env bash
set -euo pipefail

# v2.5.3：构建产物不再落在仓库目录。
#
# 背景（用户报障「我的电脑 app 有 4 个一样的 app」）：
# 旧脚本把 TypelessSwitchboard.app 直接生成在每个 worktree 根目录。
# 虽然 .gitignore 排除了它，git 不会提交，但 **Spotlight 照样会索引**，
# 于是 Launchpad / Spotlight / Finder 搜索里出现好几个一模一样的 app。
#
# 修法：.app 一律先生成到仓库外的缓存目录，只有显式 --install 时才拷进 /Applications。
# 这样任何 worktree 都不会再出现 .app，Spotlight 也只会看到唯一一份。

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

APP="TypelessSwitchboard.app"
# 仓库外的落盘位置，避免污染 worktree 与 Spotlight 索引
STAGE_ROOT="${TYPELESS_SWITCHBOARD_BUILD_ROOT:-$HOME/Library/Caches/TypelessSwitchboard}"
STAGE="$STAGE_ROOT/$APP"

# 版本号从 Core 的单一事实来源解析，避免与代码里的回落值漂移。
# 以前两处各写一份；裸二进制（CLI 导出配置包 / daemon 巡检）读不到 Info.plist，
# 会用到代码里的回落值，一旦忘记同步，导出的配置包就带着假版本号。
APP_VERSION_FILE="Sources/TypelessSwitchboardCore/AppVersion.swift"
VERSION_SHORT="$(sed -n 's/.*static let short = "\(.*\)".*/\1/p' "$APP_VERSION_FILE" | head -1)"
VERSION_BUILD="$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' "$APP_VERSION_FILE" | head -1)"
if [[ -z "$VERSION_SHORT" || -z "$VERSION_BUILD" ]]; then
  echo "ERROR: 无法从 $APP_VERSION_FILE 解析版本号" >&2
  exit 1
fi

# v2.6.0：macOS 27 SDK 起，SwiftUI 的 @State / @Observable 等改成了宏实现，
# 而宏插件（libSwiftUIMacros.dylib）只随**完整 Xcode** 分发。本机只有 Command Line
# Tools 时，用 27 SDK 编译必然报：
#   error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
# 这不是代码问题，是工具链缺件。所以没有 Xcode 时回退到仍能编译的 26.x SDK。
# 装了 Xcode 的话什么都不用做，走系统默认。
if [[ -z "${SDKROOT:-}" && ! -d "/Applications/Xcode.app" ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk; do
    if [[ -d "$candidate" ]]; then
      export SDKROOT="$candidate"
      echo "NOTE: 未检测到 Xcode，使用 SDK $(basename "$SDKROOT") 构建"
      break
    fi
  done
fi

swift build -c release

rm -rf "$STAGE"
mkdir -p "$STAGE_ROOT"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp ".build/release/TypelessSwitchboard" "$STAGE/Contents/MacOS/TypelessSwitchboard"

# v2.6.0：会话/额度脚本以 SwiftPM 资源包形式随包分发（唯一来源），
# 漏拷这个 bundle 会让 App 找不到脚本、额度同步整条失效。
for bundle in .build/release/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$STAGE/Contents/Resources/"
  echo "Bundled resources: $(basename "$bundle")"
done

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TypelessSwitchboard</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.typeless.switchboard</string>
  <key>CFBundleName</key>
  <string>Typeless Switchboard</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION_SHORT}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# v2.3.0：复制 AppIcon.icns 到 .app（若 icns 不存在则现场生成）。
ICON_SRC="Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$STAGE/Contents/Resources/AppIcon.icns"
else
    echo "WARN: $ICON_SRC not found, generating via scripts/generate-icon.sh"
    ./scripts/generate-icon.sh
    cp "$ICON_SRC" "$STAGE/Contents/Resources/AppIcon.icns"
fi

if command -v codesign >/dev/null 2>&1; then
  # 优先用**稳定的自签名身份**签名。
  #
  # 为什么重要：钥匙串条目的授权记录的是「创建它的那个 app 的签名指纹」。
  # ad-hoc 签名（`--sign -`）的指纹每次构建都变 ⇒ 每次重装 app 都会弹
  # 「想要使用你储存在钥匙串中的机密信息」并要登录密码，而 GUI 与守护会双双
  # 卡死在那一句 SecItemCopyMatching 上：窗口不出、日志不写（2026-09-30 实测）。
  # 换成固定证书后，指定要求变成「bundle id + 证书」，跨构建稳定，不再重复授权。
  # 一次性创建：./scripts/create-signing-identity.sh
  SIGN_IDENTITY="${TYPELESS_SIGN_IDENTITY:-TypelessSwitchboard Local}"
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGE" >/dev/null
    echo "已用稳定身份签名：$SIGN_IDENTITY（钥匙串不会重复要授权）"
  else
    codesign --force --deep --sign - "$STAGE" >/dev/null
    echo "WARN: 未找到代码签名身份，已退回 ad-hoc 签名 —— 每次重装 app 都会要求钥匙串授权。" >&2
    echo "      一次性根治：./scripts/create-signing-identity.sh" >&2
  fi
fi

echo "Built $STAGE (v${VERSION_SHORT})"

# 清理历史遗留：本仓库目录里若还残留旧 .app，直接删掉（构建产物，可随时重建）。
# 只在明确属于本仓库且未被 git 跟踪时删除，避免误伤。
if [[ -d "$REPO_ROOT/$APP" ]]; then
    if git ls-files --error-unmatch "$APP" >/dev/null 2>&1; then
        echo "WARN: $REPO_ROOT/$APP 已被 git 跟踪，保留不动"
    else
        echo "Removing stale build artifact: $REPO_ROOT/$APP"
        rm -rf "$REPO_ROOT/$APP"
    fi
fi

# 用法：
#   ./scripts/build-app.sh                  # 构建到缓存目录（默认）
#   ./scripts/build-app.sh --install        # 安装到 /Applications
#   ./scripts/build-app.sh --install --launch
#   ./scripts/build-app.sh --out /path      # 拷到指定目录
DO_INSTALL=0
DO_LAUNCH=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1; shift ;;
    --launch)  DO_LAUNCH=1; shift ;;
    --out)     OUT_DIR="${2:-}"; shift 2 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$DO_INSTALL" -eq 1 ]]; then
  DEST="/Applications/$APP"
  GUARD_LABEL="local.typeless.switchboard.quota-guard"
  GUARD_PLIST="$HOME/Library/LaunchAgents/$GUARD_LABEL.plist"

  # ① 安装前先停掉守护。
  #
  # 为什么必须停：下面是 `rm -rf` + `cp -R`，拷贝整个 .app 有几秒窗口期。
  # 而守护是 launchd 定时任务（StartInterval 见 plist，默认按用户配置的分钟数），随时可能被拉起 ——
  # 只要它在这个窗口期内启动，就会从「正在被写入的 bundle」加载，
  # 代码签名校验失败，被内核直接 SIGKILL。实测崩溃报告：
  #   EXC_CRASH (SIGKILL (Code Signature Invalid))
  #   Termination Reason: Namespace CODESIGNING, Code 4, Launch Constraint Violation
  # 这不是软件缺陷，是安装流程自己的竞态；但用户会看到一份吓人的崩溃报告，
  # 所以在这里堵掉。
  GUARD_WAS_LOADED=0
  if launchctl list 2>/dev/null | grep -q "$GUARD_LABEL"; then
    GUARD_WAS_LOADED=1
    launchctl bootout "gui/$(id -u)/$GUARD_LABEL" 2>/dev/null \
      || launchctl unload "$GUARD_PLIST" 2>/dev/null || true
    echo "已暂停额度守护（安装期间，避免签名校验竞态）"
  fi

  # ② 正在运行的 GUI 也要先退出：它持有旧 bundle，直接 rm 掉会留下坏状态。
  if pgrep -f "TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard" >/dev/null 2>&1; then
    osascript -e 'tell application "TypelessSwitchboard" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6; do
      pgrep -f "TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard" >/dev/null 2>&1 || break
      sleep 0.5
    done
    echo "已退出运行中的 GUI"
  fi

  echo "Installing to $DEST"
  rm -rf "$DEST"
  cp -R "$STAGE" "$DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  echo "Installed $DEST"

  # ③ 恢复守护（装完再拉起来，此时 bundle 已经是完整的新版本）。
  #
  # 判据用「plist 还在」而不是「装之前是否加载」：plist 在就说明用户装过这个守护，
  # 而它完全可能正因为历史缺陷（守护自噬 → bootout 后 bootstrap 失败）处于
  # 「已安装但没加载」的状态 —— 这里顺带治好，并且**校验**，不再静默失败。
  if [[ -f "$GUARD_PLIST" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$GUARD_PLIST" 2>/dev/null \
      || launchctl load "$GUARD_PLIST" 2>/dev/null || true
    if launchctl print "gui/$(id -u)/$GUARD_LABEL" >/dev/null 2>&1; then
      echo "已恢复额度守护（launchd 校验通过）"
    else
      echo "⚠️ 额度守护未能加载：请打开 App 的「额度守护」页点「安装/更新开机插件」" >&2
    fi
  fi

  if [[ "$DO_LAUNCH" -eq 1 ]]; then
    # ④ 不要用裸 `open` —— 它在受限 shell 里会静默失效（不报错也不启动）。
    #    走 Finder 的 Apple Event 才可靠。
    osascript -e "tell application \"Finder\" to open POSIX file \"$DEST\"" >/dev/null 2>&1 \
      || open "$DEST" 2>/dev/null || true
    echo "Launched $DEST"
  fi
fi

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  cp -R "$STAGE" "$OUT_DIR/$APP"
  echo "Copied to $OUT_DIR/$APP"
fi
