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

VERSION_SHORT="2.5.3"
VERSION_BUILD="4"

swift build -c release

rm -rf "$STAGE"
mkdir -p "$STAGE_ROOT"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp ".build/release/TypelessSwitchboard" "$STAGE/Contents/MacOS/TypelessSwitchboard"

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
  codesign --force --deep --sign - "$STAGE" >/dev/null
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
  echo "Installing to $DEST"
  rm -rf "$DEST"
  cp -R "$STAGE" "$DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  echo "Installed $DEST"
  if [[ "$DO_LAUNCH" -eq 1 ]]; then
    open "$DEST"
    echo "Launched $DEST"
  fi
fi

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  cp -R "$STAGE" "$OUT_DIR/$APP"
  echo "Copied to $OUT_DIR/$APP"
fi
