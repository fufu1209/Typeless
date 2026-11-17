#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib-sdk-fallback.sh"
swift run --disable-sandbox TypelessSwitchboard
