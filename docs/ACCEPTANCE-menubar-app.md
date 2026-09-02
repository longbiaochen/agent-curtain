# AgentCurtain 菜单栏应用验收矩阵

本文件把“实现存在”“自动测试通过”“安装运行通过”和“真实硬件行为通过”分开。
截至 2026-09-02，当前权威安装物是 `/Applications/AgentCurtain.app`。

## 实现与安装

| 要求 | 当前证据 | 结论 |
|---|---|---|
| 单个 `AgentCurtain.app` | `/Applications/AgentCurtain.app` strict codesign 通过；旧 `~/.local/libexec/{hid-blocker,curtain-banner,curtain-watchdog,curtain-sentry}` 已移除 | 通过 |
| Developer ID + Hardened Runtime + timestamp | `Authority=Developer ID Application: LONGBIAO CHEN (HJG65XBC25)`；flags 含 `runtime`；有安全时间戳 | 通过 |
| requirement 不含 `cdhash` | `codesign -d -r-` 为 identifier + Apple anchor + Team ID，未出现 `cdhash` | 通过 |
| accessory 菜单栏 app | 安装物 `LSUIElement=true`，运行时 `NSApp.setActivationPolicy(.accessory)` | 实现与安装通过；图标可见性尚缺可用 GUI 读取面 |
| 0600 Unix socket | `stat ~/.local/state/curtain/control.sock` 为 `srw------- 600`；`status` 返回合法 JSON | 通过 |
| 瘦 CLI 无 TCC | 未授权的当前 shell 执行 `curtain off` 返回 `{"ok":true,"state":"open"}` | 通过 |
| 旧命令兼容 | `on [秒] [--allow-any-injected]`、`off/status/allow/deny/doctor` 协议解析测试通过 | 通过 |

## PRD §5 实现核对

| 要求 | 覆盖点 | 结论 |
|---|---|---|
| HID 层 `.defaultTap` | `InputBlocker` 使用 `.cghidEventTap`、`.headInsertEventTap`、`.defaultTap` | 通过 |
| 完整事件掩码 | key、flags、三类鼠键、左右拖动、滚轮、移动均进入 mask | 通过 |
| 拒绝优先 | 纯函数单测覆盖 deny 同时命中 allow/allow-any 时仍拒绝 | 自动测试通过；真实事件尚待授权 |
| tap 自愈 | 两种 disabled event 均立即 `CGEvent.tapEnable` | 实现通过；真实触发尚未制造 |
| 精确 PID 解析 | `proc_listallpids` + `proc_pidpath`；无运行时 `pgrep -f` | 通过 |
| 每 3 秒刷新 PID | `InputBlocker` 3 秒 timer | 通过 |
| 每屏提示条 | `.screenSaver`、忽略鼠标、all spaces、stationary、屏幕变化重建 | 生命周期回归通过；framebuffer 正例待授权 |
| 提示条 framebuffer 验证 | `script/verify_banner_framebuffer.sh` 使用 ScreenCaptureKit 逐 `displayID` 扫描 `#BF1A1A`；幕帘打开基线四屏均为 0 像素并正确失败 | 负例通过；正例待授权 |
| 亮度只按 displayID | BetterDisplay 所有 get/set 均使用 `-displayID=`；运行时无 `pmset displaysleepnow` | 通过 |
| 原亮度恢复 | 0600 JSON 备份、正常恢复、孤立记录重试、包内 watchdog | 单测与 kill -9 夹具通过；真实屏强杀待授权 |
| 显示器插拔 | 提示条重建；新 displayID 追加原亮度后调暗 | 实现通过；真实插拔待执行 |
| 默认 denylist | 三个 Karabiner 规则创建测试通过 | 通过 |
| 安全措辞 | 菜单显示“幕帘”且说明弱于真锁屏；中英文 README 明示威胁边界 | 通过 |
| 全局快捷键 | L 由全局 monitor 触发；U 在 HID 回调吞键前处理 | 实现通过；真人按键待执行 |

## PRD §9 十一项验收

| # | 项目 | 当前结论 | 尚需的权威证据 |
|---:|---|---|---|
| 1 | 授权一次后重编译仍有效 | **阻塞** | 当前系统设置中 `AgentCurtain.app` 开关为 off；授权后拉上、重编译重签安装、再次拉上 |
| 2 | requirement 不含 cdhash | **通过** | 已有安装物 `codesign -d -r-` 读回 |
| 3 | 四块屏全部熄灭 | **阻塞** | 授权后逐 `displayID` 读回 brightness=0 |
| 4 | 截图仍拿到真实内容 | **阻塞** | 拉上前后 ScreenCaptureKit 图像平均亮度对照，拉上后不得接近 0 |
| 5 | 提示条真的画出来 | **待正例** | 拉上时运行 framebuffer 验收器，四屏均 PASS |
| 6 | 物理键鼠确实无效 | **必须真人** | 真人按键/移动鼠标，`blocked` 上升且桌面无响应 |
| 7 | 白名单放行远程桌面 | **阻塞** | UURemote 操作正常且 `allowed` 上升 |
| 8 | 拒绝名单优先 | **自动测试通过，实机待验** | 同一真实注入进程同时 allow+deny 后事件被拦 |
| 9 | 解除不需要权限 | **通过** | 当前未授权 shell 的 `curtain off` 已成功 |
| 10 | 崩溃后亮度恢复 | **夹具通过，实屏待验** | watchdog 已通过 kill -9 owner 夹具；仍需拉上后 kill -9 app 并逐屏读回原值 |
| 11 | 显示器插拔 | **实现通过，实机待验** | 拉上时拔插一屏，提示条特征色与 brightness=0 均重新建立 |

## 当前唯一前置阻塞

系统设置 → 隐私与安全性 → 辅助功能 中，`AgentCurtain.app` 已存在但开关为 off。
应用在任何调暗前检查该授权；当前执行 `curtain on 3` 返回授权错误，四屏亮度保持
`displayID 1=0.979, 2=0.8, 3=0.8, 4=1.0`，证明失败路径没有先黑屏。

切换此安全设置后，按本表 #1、#3–#8、#10–#11 继续实机验收。
