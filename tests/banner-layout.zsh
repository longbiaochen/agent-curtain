#!/bin/zsh
set -eu
root=${0:a:h:h}
probe=$(mktemp -d /tmp/curtain-banner-layout.XXXXXX)
trap 'rm -rf "$probe"' EXIT
swiftc -O -parse-as-library \
  "$root/Sources/AgentCurtain/BannerController.swift" \
  "$root/tests/fixtures/banner-layout.swift" \
  -framework AppKit -o "$probe/probe"
"$probe/probe"
