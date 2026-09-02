#!/bin/zsh
set -eu

root=${0:a:h:h}
fixture=$(mktemp -d /tmp/agent-curtain-watchdog-test.XXXXXX)
owner_pid=''
watchdog_pid=''
cleanup() {
  [[ -z "$owner_pid" ]] || kill -KILL "$owner_pid" 2>/dev/null || true
  [[ -z "$watchdog_pid" ]] || kill -KILL "$watchdog_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT

swift build --package-path "$root" >/dev/null
bin_dir=$(swift build --package-path "$root" --show-bin-path)
fake_cli="$root/tests/fixtures/fake-betterdisplaycli"
chmod +x "$fake_cli"
log="$fixture/betterdisplay.log"
backup="$fixture/brightness.json"

sleep 30 &
owner_pid=$!
python3 -c 'import json,sys
json.dump({"ownerPID":int(sys.argv[2]),"createdAt":0,"displays":[{"displayID":7,"brightness":0.75}]},open(sys.argv[1],"w"))' "$backup" "$owner_pid"
chmod 600 "$backup"

CURTAIN_FAKE_BETTERDISPLAY_LOG="$log" \
  "$bin_dir/AgentCurtainRestoreWatchdog" "$owner_pid" "$backup" "$fake_cli" &
watchdog_pid=$!
sleep 0.3
kill -KILL "$owner_pid"
wait "$watchdog_pid"
watchdog_pid=''
owner_pid=''

[[ ! -e "$backup" ]]
grep -Fxq 'set -displayID=7 -brightness=0.75' "$log"
print 'watchdog-integration: kill -9 owner restored the recorded display brightness'
