# AgentCurtain

**拉上幕帘，后台照常演出。**

AgentCurtain 是面向 macOS 26+ 无人值守 GUI agent 会话的菜单栏应用。它把每块
物理显示器调暗，在 HID 事件层阻断物理键鼠，同时让未锁定的 WindowServer 会话
继续合成画面。白名单内的远程桌面进程和 session 层的 agent 注入仍可正常工作。

[English](README.md) · [实测记录](docs/FINDINGS.md) ·
[实现 PRD](docs/PRD-menubar-app.md)

> AgentCurtain 弱于真锁屏。它防的是路过同事、进屋访客等机会型接触，防不住
> 有准备的攻击者、重启、插入新输入设备或物理拆机。UI 只会说“幕帘已拉上”，
> 不会把它表述成“已锁定”或“安全”。

## 交付形态

`/Applications/AgentCurtain.app` 是唯一安装的运行主体，也是唯一需要辅助功能
授权的对象。app 内含：

- 显示拉开/拉上状态及实时计数的 `NSStatusItem` 菜单；
- 拒绝优先判定、可自愈的 `kCGHIDEventTap` 阻断器；
- 每块显示器一个、可在 framebuffer 中扫描到的提示条；
- 只按 `displayID` 定址的 BetterDisplay 亮度控制；
- `~/.local/state/curtain/control.sock` 上权限为 0600 的 Unix socket；
- app 被强杀时独立恢复亮度的包内看门狗。

`curtain` 是不持有权限的瘦 socket 客户端。它不会创建事件 tap，因此不需要任何
TCC 授权。

## 安装

依赖：

- Apple Silicon、macOS 26 或以上；
- Xcode Command Line Tools；
- 已安装带 `betterdisplaycli` 的 BetterDisplay；
- 从源码构建时，钥匙串内有 PRD 指定的 Developer ID 身份。

```bash
./install.sh
```

主程序、包内恢复看门狗、外层 app 都使用以下身份签名：

```text
Developer ID Application: LONGBIAO CHEN (HJG65XBC25)
```

构建强制启用 Hardened Runtime 和安全时间戳；找不到身份时直接失败，不回退到
ad-hoc 签名。安装后还会对 `/Applications` 中的 app 再做一次严格验证。

第一次启用前，到“系统设置 → 隐私与安全性 → 辅助功能”勾选 **AgentCurtain**。
它的 designated requirement 基于 bundle identifier、Apple anchor 和 Team ID，
不含 `cdhash`，因此后续用同一身份重编译、升级不需要重新授权。

## 使用

可以用菜单栏图标、全局快捷键或兼容 CLI：

```bash
curtain on
curtain status
curtain off
curtain allow
curtain deny
curtain doctor
```

旧有的定时形式继续支持：

```bash
curtain on 3600
curtain on --allow-any-injected
```

拒绝名单为空时，`--allow-any-injected` 会被拒绝。全局快捷键：

- `Ctrl+Opt+Cmd+Shift+L`：拉上幕帘；
- `Ctrl+Opt+Cmd+Shift+U`：拉开幕帘。

解除热键在 HID 回调吞掉按键前检查。`curtain off` 只与 app 的 socket 通信，
包括从 SSH 执行时也不需要辅助功能权限。

## 配置

- `~/.config/curtain/allowlist`：允许的可执行文件路径，一行一个；
- `~/.config/curtain/denylist`：永远拦截，优先级最高。

空行和以 `#` 开头的行会忽略。`.app` 规则解析到精确的 bundle executable；
非路径规则只匹配完整进程名。PID 解析使用 `proc_listallpids` + `proc_pidpath`，
绝不使用 `pgrep -f` 子串匹配，并且每 3 秒刷新一次。

默认拒绝名单包含 PRD 要求的三个 Karabiner 组件。

## 运行安全

拉上幕帘的顺序可回滚：

1. 先确认 AgentCurtain 自己已有辅助功能授权；
2. 按 `displayID` 读取所有活动显示器原亮度；
3. 原子写入权限 0600 的恢复记录；
4. 启动包内独立恢复看门狗；
5. 把每块屏调到 0 并逐块读回；
6. 挂上 HID event tap，并为每块屏创建提示条。

任何一步失败都会回滚亮度。正常 `off`、从菜单退出、`SIGTERM`、定时解除和解除
热键都会恢复亮度。`kill -9` 无法执行 app 清理，因此独立看门狗会观察主进程退出，
使用同一恢复文件复原；下次启动还会重试孤立的恢复记录。

显示器变化通知会重建提示条，并把新插入的 `displayID` 及其原亮度追加到恢复记录，
随后再调暗新屏。

AgentCurtain 绝不调用 `pmset displaysleepnow`，因为 display sleep 会停止
framebuffer 合成，让 GUI agent 失明。

## 开发与验证

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --install
```

Codex 的 Run 按钮也指向同一脚本。`--verify` 会运行 Swift 测试、严格验证签名、
启动已签名 bundle、检查 socket 权限为 0600，并验证 JSON `status` 响应。

硬件验收必须单独进行。尤其是“物理键鼠确实无效”只能由真人按键/移动鼠标验证：
应看到 `blocked` 上升且界面无响应。程序化注入到不了同一 HID 路径，不能替代这项
证据。完整逐项清单见
[docs/PRD-menubar-app.md](docs/PRD-menubar-app.md#9-验收标准)。
