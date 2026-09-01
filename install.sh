#!/bin/zsh
# agent-curtain 安装脚本
set -eu
here=${0:a:h}
mkdir -p ~/.local/bin ~/.local/libexec ~/.config/curtain ~/.local/state/curtain

command -v swiftc >/dev/null || { print "需要 swiftc(安装 Xcode Command Line Tools)" >&2; exit 1 }
command -v betterdisplaycli >/dev/null || print "警告:未找到 betterdisplaycli,调光将不可用(brew install --cask betterdisplay)" >&2

swiftc -O "$here/src/hid-blocker.swift"     -o ~/.local/libexec/hid-blocker
swiftc -O "$here/src/curtain-banner.swift"  -o ~/.local/libexec/curtain-banner
install -m 755 "$here/bin/curtain" ~/.local/bin/curtain
sudo install -o "$USER" -g staff -m 755 "$here/bin/curtain" /usr/local/bin/curtain
[[ -f ~/.config/curtain/allowlist ]] || cp "$here/examples/allowlist" ~/.config/curtain/allowlist

cat <<'MSG'

已安装。还需两步:

1. 授予 hid-blocker 辅助功能权限(否则 `curtain on` 无法创建事件 tap):
   系统设置 → 隐私与安全性 → 辅助功能 → 添加
     ~/.local/libexec/hid-blocker
   注意:TCC 授权绑定代码签名哈希,重新编译后需重新授权。

2. (可选)导入热键:Karabiner-Elements → Complex Modifications
   见 examples/karabiner-curtain.json

用法: curtain on | off | status | allow
MSG
