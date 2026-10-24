#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# `--disable-sandbox`：与 build-app.sh 同一处境 —— SwiftPM 默认用 sandbox-exec
# 编译 Package.swift manifest，本机（及部分受限 shell / Agent 环境）会直接失败：
#   sandbox-exec: sandbox_apply: Operation not permitted
# 不是代码问题，是构建环境不允许再套一层沙箱。
swift run --disable-sandbox OperationalFeatureChecks
