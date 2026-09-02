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
install -m 755 "$here/bin/curtain-sentry" ~/.local/libexec/curtain-sentry
install -m 755 "$here/bin/curtain" ~/.local/bin/curtain
sudo install -o "$USER" -g staff -m 755 "$here/bin/curtain" /usr/local/bin/curtain
[[ -f ~/.config/curtain/allowlist ]] || cp "$here/examples/allowlist" ~/.config/curtain/allowlist
[[ -f ~/.config/curtain/denylist ]] || cp "$here/examples/denylist" ~/.config/curtain/denylist

# 安装清单。`curtain doctor` 用它发现「就地 swiftc 编出来的二进制」
# 这类漂移 —— 装好的东西和仓库 build/ 不是一个,查起来很费时间。
: > ~/.local/state/curtain/manifest
for installed in ~/.local/libexec/hid-blocker ~/.local/libexec/curtain-banner \
                 ~/.local/libexec/curtain-watchdog ~/.local/libexec/curtain-sentry \
                 ~/.local/bin/curtain; do
  shasum -a 256 "$installed" >> ~/.local/state/curtain/manifest
done

# 看护:每 5 分钟检查一次「期望拉上却没拉上」。只读,不需要任何授权。
sentry_plist=~/Library/LaunchAgents/me.longbiaochen.curtain-sentry.plist
mkdir -p ~/Library/LaunchAgents
sed "s|__HOME__|$HOME|g" "$here/examples/me.longbiaochen.curtain-sentry.plist" > "$sentry_plist"
launchctl bootout "gui/$(id -u)/me.longbiaochen.curtain-sentry" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$sentry_plist"

cat <<'MSG'

已安装。还需两步:

1. 让 `curtain on` 拿到辅助功能授权。两条路,任选:

   (a) 推荐:从一个**已授权的 Terminal.app** 执行 `curtain on`。
       阻断器是直接 fork 的,TCC 归责到调用方,所以不需要给 hid-blocker
       任何常驻授权。别从 agent 会话(Claude Code / Codex 等)里执行 ——
       它们的责任 app 是随版本变化的 helper bundle,自动升级会让**正在运行**
       的会话整体失去授权。

   (b) 想让 Karabiner 热键 / launchd 也能启用,才需要给二进制本身授权:
       系统设置 → 隐私与安全性 → 辅助功能 → 「+」添加
         ~/.local/libexec/hid-blocker
       **重要:路径型条目钉的是 cdhash** —— 二进制内容一变(改源码重编、
       换签名身份)条目就失配,而且取消勾选再勾上**不会**刷新,
       必须「−」删掉整条再「+」加回。失配时系统设置里看起来仍是勾着的,
       `curtain doctor` 会把新旧 cdhash 一起打出来。
       (源码和签名身份都没变时重跑本脚本不影响 —— cdhash 是可复现的。)

2. (可选)导入热键:Karabiner-Elements → Complex Modifications
   见 examples/karabiner-curtain.json

看护已随安装启用(launchd,每 5 分钟)。人不在本机时本机通知看不到,
把告警接到手机上:
   在 ~/.config/curtain/sentry.conf 里写一行,例如:
     CURTAIN_ALERT_CMD="curl -s -d @- https://ntfy.sh/<你的主题>"

用法: curtain on | off | status | doctor | allow | deny
MSG
