#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
mkdir -p "$BUILD_DIR"

# 这是输入阻断工具；构建入口绝不能为了“重启应用”而终止已生效的安全状态。
zsh -n "$ROOT_DIR/bin/curtain" "$ROOT_DIR/bin/curtain-watchdog" "$ROOT_DIR/install.sh"
swiftc -O "$ROOT_DIR/src/hid-blocker.swift" -o "$BUILD_DIR/hid-blocker"
swiftc -O "$ROOT_DIR/src/curtain-banner.swift" -o "$BUILD_DIR/curtain-banner"
install -m 755 "$ROOT_DIR/bin/curtain" "$BUILD_DIR/curtain"
install -m 755 "$ROOT_DIR/bin/curtain-watchdog" "$BUILD_DIR/curtain-watchdog"

case "$MODE" in
  run)
    "$BUILD_DIR/curtain" status
    ;;
  --debug|debug)
    lldb -- /bin/zsh "$BUILD_DIR/curtain" status
    ;;
  --logs|logs)
    tail -n 50 -F "$HOME/.local/state/curtain/blocker.log" "$HOME/.local/state/curtain/watchdog.log"
    ;;
  --telemetry|telemetry)
    /usr/bin/log stream --info --style compact --predicate 'process == "hid-blocker" OR process == "curtain-banner"'
    ;;
  --verify|verify)
    codesign --verify --strict --verbose=2 "$BUILD_DIR/hid-blocker"
    codesign --verify --strict --verbose=2 "$BUILD_DIR/curtain-banner"
    "$BUILD_DIR/curtain" status >/dev/null
    "$ROOT_DIR/tests/watchdog-smoke.zsh"
    echo "verify: shell syntax, Swift builds, code signatures, safe status launch, and watchdog restore passed"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
