#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="${TMPDIR:-/tmp}/agent-curtain-framebuffer-$(id -u)"
VERIFY_BINARY="$VERIFY_DIR/verify-banner-framebuffer"
mkdir -p "$VERIFY_DIR"
swiftc -O -parse-as-library "$ROOT_DIR/script/verify_banner_framebuffer.swift" \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  -o "$VERIFY_BINARY"
exec "$VERIFY_BINARY"
