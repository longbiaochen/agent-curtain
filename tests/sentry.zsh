#!/bin/zsh
# curtain-sentry 的判据测试。
#
# 看护存在的理由是 2026-09-02 那两次掉线:一次 curtain on 失败后没人再管,
# 一次部署把整套栈拆了没装回去 —— 两次 app 都无法自我报告。所以这里必须
# 覆盖「app 完全不在」这一种,而不只是「app 说它拉开了」。
set -eu

root=${0:a:h:h}
fixture=$(mktemp -d /tmp/curtain-sentry-test.XXXXXX)
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  rm -rf "$fixture"
}
trap cleanup EXIT

state_dir=$fixture/.local/state/curtain
mkdir -p "$state_dir" "$fixture/.config/curtain"
# 告警出口指向文件,这样「有没有真的告警」是可判定的,而不是看日志措辞。
print -r -- 'CURTAIN_ALERT_CMD="cat >> '"$fixture"'/alerts"' > "$fixture/.config/curtain/sentry.conf"

run_sentry() { HOME=$fixture "$root/bin/curtain-sentry" }
alert_count() { [[ -f "$fixture/alerts" ]] && grep -c '^curtain 掉了' "$fixture/alerts" || print 0 }
last_log() { tail -1 "$state_dir/sentry.log" }

start_fake_endpoint() {
  python3 "$root/tests/fixtures/fake-control-socket.py" "$state_dir/control.sock" "$1" 2>/dev/null &
  server_pid=$!
  local waited=0
  while [[ ! -S "$state_dir/control.sock" ]] && (( waited < 50 )); do sleep 0.1; (( waited += 1 )); done
  [[ -S "$state_dir/control.sock" ]]
}
stop_fake_endpoint() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  server_pid=""
  rm -f "$state_dir/control.sock"
}

# 1. 没有声明期望 —— 无论 app 在不在都不该告警
run_sentry
(( $(alert_count) == 0 )) || { print -u2 "sentry: 未声明期望却告警了"; exit 1 }
last_log | grep -q '未声明期望' || { print -u2 "sentry: 日志没记未声明期望"; exit 1 }

# 2. 期望拉上 + app 报告 drawn —— 正常
print -r -- "2026-09-02T06:17:50Z" > "$state_dir/expected"
start_fake_endpoint drawn
run_sentry
(( $(alert_count) == 0 )) || { print -u2 "sentry: 幕帘生效中却告警了"; exit 1 }
last_log | grep -q '幕帘生效中' || { print -u2 "sentry: 日志没记生效中"; exit 1 }
stop_fake_endpoint

# 3. 期望拉上 + app 报告 open —— 必须告警
start_fake_endpoint open
run_sentry
(( $(alert_count) == 1 )) || { print -u2 "sentry: state=open 没有告警"; exit 1 }
grep -q 'state=open' "$fixture/alerts" || { print -u2 "sentry: 告警没说明原因"; exit 1 }
stop_fake_endpoint

# 4. 重复告警要被抑制
rm -f "$state_dir/sentry.last-alert"   # 先清掉,单独验抑制窗口
start_fake_endpoint open
run_sentry
before=$(alert_count)
run_sentry
(( $(alert_count) == before )) || { print -u2 "sentry: 重复告警没有被抑制"; exit 1 }
last_log | grep -q '抑制' || { print -u2 "sentry: 抑制没有记日志"; exit 1 }
stop_fake_endpoint

# 5. 期望拉上 + 控制端点根本不在 —— 这就是 2026-09-02 的真实故障
rm -f "$state_dir/sentry.last-alert"
run_sentry
grep -q '控制端点不可达' "$fixture/alerts" || {
  print -u2 "sentry: app 不在时没有报出不可达"; exit 1
}

# 6. 看护不得有副作用:既不启动 app,也不改状态
[[ ! -S "$state_dir/control.sock" ]] || { print -u2 "sentry: 不该创建/拉起控制端点"; exit 1 }
[[ -f "$state_dir/expected" ]] || { print -u2 "sentry: 不该清除期望标记"; exit 1 }

print "sentry: passed"
