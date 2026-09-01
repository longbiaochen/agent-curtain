#!/bin/zsh
# agent-curtain 安装脚本
set -eu
here=${0:a:h}
build_dir=$(mktemp -d /tmp/agent-curtain-install.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
mkdir -p ~/.local/bin ~/.local/libexec ~/.config/curtain ~/.local/state/curtain

command -v swiftc >/dev/null || { print "需要 swiftc(安装 Xcode Command Line Tools)" >&2; exit 1 }
command -v betterdisplaycli >/dev/null || { print "需要 betterdisplaycli(brew install --cask betterdisplay)" >&2; exit 1; }

swiftc -O "$here/src/hid-blocker.swift"     -o "$build_dir/hid-blocker"
swiftc -O "$here/src/curtain-banner.swift"  -o "$build_dir/curtain-banner"

signing_identity=${CURTAIN_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -n "$signing_identity" ]]; then
  for binary in "$build_dir/hid-blocker" "$build_dir/curtain-banner"; do
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$binary"
    codesign --verify --strict --verbose=2 "$binary"
  done
  print "使用稳定签名: $signing_identity"
else
  print "警告:未找到 Developer ID Application，将使用 linker ad-hoc 签名；重新编译后需重新授权辅助功能。" >&2
fi

install -m 755 "$build_dir/hid-blocker" ~/.local/libexec/hid-blocker
install -m 755 "$build_dir/curtain-banner" ~/.local/libexec/curtain-banner
install -m 755 "$here/bin/curtain-watchdog" ~/.local/libexec/curtain-watchdog
install -m 755 "$here/bin/curtain" ~/.local/bin/curtain
sudo install -o "$USER" -g staff -m 755 "$here/bin/curtain" /usr/local/bin/curtain
[[ -f ~/.config/curtain/allowlist ]] || cp "$here/examples/allowlist" ~/.config/curtain/allowlist
[[ -f ~/.config/curtain/denylist ]] || cp "$here/examples/denylist" ~/.config/curtain/denylist

cat <<'MSG'

已安装。还需两步:

1. 授予 hid-blocker 辅助功能权限(否则 `curtain on` 无法创建事件 tap):
   系统设置 → 隐私与安全性 → 辅助功能 → 添加
     ~/.local/libexec/hid-blocker
   使用 Developer ID 签名时，首次安装授权一次即可；ad-hoc 签名重新编译后需重授。

2. (可选)导入热键:Karabiner-Elements → Complex Modifications
   见 examples/karabiner-curtain.json

用法: curtain on | off | status | doctor | allow | deny
MSG
