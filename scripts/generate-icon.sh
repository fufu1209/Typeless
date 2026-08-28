#!/usr/bin/env bash
#
# generate-icon.sh — 从 templates/AppIcon.svg 渲染出 macOS 用的 Resources/AppIcon.icns
#
# 依赖：macOS 自带的 qlmanage / sips / iconutil。零第三方依赖。
# 用法：./scripts/generate-icon.sh
#
set -eo pipefail

cd "$(dirname "$0")/.."

SVG="templates/AppIcon.svg"
ICONSET_DIR="/tmp/TypelessSwitchboard.iconset"
OUT_ICNS="Resources/AppIcon.icns"

if [[ ! -f "$SVG" ]]; then
    echo "ERROR: $SVG not found" >&2
    exit 1
fi

# macOS 上 qlmanage 通过 QuickLook 渲染 SVG（无需第三方 SVG 库）。
TMP_PNG="/tmp/AppIcon.master.png"
mkdir -p "$(dirname "$TMP_PNG")"
rm -rf "$TMP_PNG"

# qlmanage 输出的临时目录
QL_OUT="$(mktemp -d)"
qlmanage -t -s 1024 -o "$QL_OUT" "$SVG" >/dev/null
cp "$QL_OUT/AppIcon.svg.png" "$TMP_PNG"
rm -rf "$QL_OUT"

mkdir -p Resources

echo "→ 生成 7 档 PNG（16/32/64/128/256/512/1024）"
mkdir -p "$ICONSET_DIR" && rm -f "$ICONSET_DIR"/*.png
# @2x 文件的实际像素 = 基础尺寸的 2 倍（Apple iconset 约定）。
sips -s format png -s formatOptions default "$TMP_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$TMP_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$TMP_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$TMP_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$TMP_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$TMP_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$TMP_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$TMP_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$TMP_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$TMP_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

echo "→ iconutil 打包成 icns"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

# 自检：解回 iconset 验证 icns 合法
VERIFY_DIR="$(mktemp -d)"
iconutil -c iconset -o "$VERIFY_DIR/AppIcon.iconset" "$OUT_ICNS" >/dev/null
ROUND_TRIP_COUNT=$(ls "$VERIFY_DIR/AppIcon.iconset" | wc -l | tr -d ' ')
rm -rf "$VERIFY_DIR"
if [[ "$ROUND_TRIP_COUNT" -lt 7 ]]; then
    echo "ERROR: icns 验证失败，仅解出 $ROUND_TRIP_COUNT 张图" >&2
    exit 1
fi

rm -rf "$ICONSET_DIR"
echo "OK: $OUT_ICNS ($(wc -c < "$OUT_ICNS" | tr -d ' ') bytes, $ROUND_TRIP_COUNT sizes)"
