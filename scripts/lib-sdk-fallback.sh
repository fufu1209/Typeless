#!/usr/bin/env bash
# 共用片段：没有完整 Xcode 时，把 SDKROOT 回落到仍能编译的 26.x SDK。
#
# 背景（v2.6.0 起）：macOS 27 SDK 把 SwiftUI 的 @State / @Observable 改成宏实现，
# 宏插件（libSwiftUIMacros.dylib）只随**完整 Xcode** 分发。本机只有 Command Line
# Tools 时，用 27 SDK 编译必然报：
#   error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
# 这不是代码问题，是工具链缺件。
#
# 用法（在脚本里 source 本文件即可，必须在 cd 到仓库根之后）：
#   source "$(dirname "$0")/lib-sdk-fallback.sh"
#
# v2.8.0：原来只有 build-app.sh 里有这段逻辑，`swift run` 的两个测试脚本没有，
# 于是「没有 Xcode 的机器上测试全挂、构建却正常」——同一个工具的两种命运，
# 排查时非常容易误判。现在统一从这里取。

if [[ -z "${SDKROOT:-}" && ! -d "/Applications/Xcode.app" ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk; do
    if [[ -d "$candidate" ]]; then
      export SDKROOT="$candidate"
      echo "NOTE: 未检测到 Xcode，使用 SDK $(basename "$SDKROOT") 构建"
      break
    fi
  done
fi
