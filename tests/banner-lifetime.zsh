#!/bin/zsh
# 回归测试:提示条窗口的生命周期。
#
# 2026-09-02 11:18:50 curtain-banner 崩在
#   EXC_BAD_ACCESS @ -[_NSWindowTransformAnimation dealloc]
# 起因是 NSWindow 默认 isReleasedWhenClosed = true:close() 释放一次,
# windows 数组里的强引用被 ARC 释放时又一次 —— 双重释放。
#
# 本测试用 weak 引用做判据:数组仍持有窗口,weak 却被清零,就说明提前释放了。
# 旧行为必崩(SIGSEGV),修复后必须干净退出。
set -eu

root=${0:a:h:h}
probe=$(mktemp -d /tmp/curtain-banner-test.XXXXXX)
trap 'rm -rf "$probe"' EXIT

swiftc -O "$root/tests/fixtures/banner-window-lifetime.swift" -o "$probe/probe" 2>/dev/null

# 1. 旧行为:必须复现出提前释放并崩溃
set +e
old_out=$("$probe/probe" --released-when-closed 2>&1)
old_code=$?
set -e
if (( old_code == 0 )); then
  print -u2 "banner-lifetime: 预期 isReleasedWhenClosed=true 会崩溃，但它干净退出了"
  print -u2 "$old_out"
  exit 1
fi
print -r -- "$old_out" | grep -q '已被清零' || {
  print -u2 "banner-lifetime: 旧行为没有表现出提前释放"; print -u2 "$old_out"; exit 1
}

# 2. 修复后:窗口必须在 close() 后仍然存活，且干净退出
new_out=$("$probe/probe" 2>&1)
print -r -- "$new_out" | grep -q '仍存活' || {
  print -u2 "banner-lifetime: isReleasedWhenClosed=false 时窗口仍被提前释放"
  print -u2 "$new_out"; exit 1
}

# 3. 正式 app 的提示条实现必须真的设了这一项
grep -q 'isReleasedWhenClosed = false' "$root/Sources/AgentCurtain/BannerController.swift" || {
  print -u2 "banner-lifetime: BannerController 没有设置 isReleasedWhenClosed = false"
  exit 1
}

print "banner-lifetime: passed"
