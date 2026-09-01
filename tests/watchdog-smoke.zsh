#!/bin/zsh
set -eu

root=${0:a:h:h}
fixture=$(mktemp -d /tmp/curtain-watchdog-test.XXXXXX)
trap 'rm -rf "$fixture"' EXIT

sleep 0.2 &
blocker_pid=$!
print -r -- "$blocker_pid" > "$fixture/blocker.pid"
print -r -- "1 0.8" > "$fixture/brightness.bak"
print -r -- "999999" > "$fixture/banner.pid"

CURTAIN_WATCHDOG_NOTIFY=0 "$root/bin/curtain-watchdog" \
  "$blocker_pid" \
  "$fixture/blocker.pid" \
  "$fixture/brightness.bak" \
  "me.longbiaochen.curtain-test-missing-banner" \
  "$fixture/banner.pid" \
  /usr/bin/true > "$fixture/output"

[[ ! -e "$fixture/blocker.pid" ]]
[[ ! -e "$fixture/brightness.bak" ]]
[[ ! -e "$fixture/banner.pid" ]]
grep -q '^RESTORED ' "$fixture/output"
print "watchdog-smoke: passed"
