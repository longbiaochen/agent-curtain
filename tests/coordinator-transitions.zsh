#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
probe=$(mktemp -d /tmp/curtain-transition-test.XXXXXX)
trap 'rm -rf "$probe"' EXIT
compile_target="$(uname -m)-apple-macosx26.0"
cp "$root/Sources/AgentCurtain/CurtainCoordinator.swift" "$probe/CurtainCoordinator.swift"
cp "$root/tests/fixtures/coordinator-transitions.swift" "$probe/main.swift"
swiftc -swift-version 5 -target "$compile_target" -emit-library -emit-module \
  -module-name AgentCurtainCore -emit-module-path "$probe/AgentCurtainCore.swiftmodule" \
  -o "$probe/libAgentCurtainCore.dylib" "$root"/Sources/AgentCurtainCore/*.swift
swiftc -swift-version 5 -target "$compile_target" -I "$probe" -L "$probe" \
  -lAgentCurtainCore -Xlinker -rpath -Xlinker "$probe" \
  "$probe/CurtainCoordinator.swift" "$probe/main.swift" -o "$probe/test"
"$probe/test"
