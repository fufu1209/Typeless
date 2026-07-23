#!/usr/bin/env bash
# 安装 / 更新 / 卸载「开机轻量额度守护」LaunchAgent。
# 不常驻 GUI：定时执行 TypelessSwitchboard --daemon-check，额度低才换号。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_BIN="$ROOT/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard"
LABEL="local.typeless.switchboard.quota-guard"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Application Support/TypelessSwitchboard/Logs"
INTERVAL_MINUTES="${INTERVAL_MINUTES:-1}"

usage() {
  cat <<'EOF'
用法:
  ./scripts/install-quota-guard.sh          # 打包(如需)并安装/更新开机插件
  ./scripts/install-quota-guard.sh --run-once
  ./scripts/install-quota-guard.sh --status
  ./scripts/install-quota-guard.sh --uninstall

环境变量:
  INTERVAL_MINUTES=1   # 巡检间隔（分钟，1–120）
EOF
}

ensure_app() {
  if [[ ! -x "$APP_BIN" ]]; then
    echo "未找到 $APP_BIN，正在打包…"
    ./scripts/build-app.sh
  fi
  if [[ ! -x "$APP_BIN" ]]; then
    echo "错误：打包后仍找不到可执行文件" >&2
    exit 1
  fi
}

cmd="${1:-install}"

case "$cmd" in
  -h|--help)
    usage
    exit 0
    ;;
  --status)
    if [[ -f "$PLIST" ]]; then
      echo "已安装: $PLIST"
      /bin/launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | head -40 || true
    else
      echo "未安装开机轻量插件"
    fi
    if [[ -f "$LOG_DIR/quota-guard-daemon.log" ]]; then
      echo "--- 最近 daemon 日志 ---"
      tail -n 8 "$LOG_DIR/quota-guard-daemon.log" || true
    fi
    exit 0
    ;;
  --uninstall)
    /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    /bin/launchctl unload -w "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已卸载 $LABEL"
    exit 0
    ;;
  --run-once)
    ensure_app
    echo "执行单次额度巡检…"
    "$APP_BIN" --daemon-check
    exit 0
    ;;
  install|--install|"")
    ensure_app
    mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
    # 钳制间隔
    if [[ "$INTERVAL_MINUTES" -lt 1 ]]; then INTERVAL_MINUTES=1; fi
    if [[ "$INTERVAL_MINUTES" -gt 120 ]]; then INTERVAL_MINUTES=120; fi
    INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_BIN}</string>
    <string>--daemon-check</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${INTERVAL_SECONDS}</integer>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/quota-guard-launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/quota-guard-launchd.err.log</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>Nice</key>
  <integer>10</integer>
</dict>
</plist>
PLIST
    /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    if ! /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
      /bin/launchctl load -w "$PLIST"
    fi
    /bin/launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
    echo "已安装开机轻量额度守护"
    echo "  plist: $PLIST"
    echo "  binary: $APP_BIN"
    echo "  interval: ${INTERVAL_MINUTES} 分钟"
    echo "  登录后自动跑；额度充足只检查，低于阈值才换号。可关掉 GUI。"
    echo "  日志: $LOG_DIR/"
    ;;
  *)
    usage
    exit 1
    ;;
esac
