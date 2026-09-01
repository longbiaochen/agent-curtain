# 实测记录

全部数据来自 MacBookPro18,4 / macOS 26.5.2 / 2026-09-01,四显示器
(内置 Liquid Retina XDR + 小米 ×2 + DELL U3219Q)。

## 1. 事件分层:为什么 HID 层阻断不影响 agent

在 `kCGHIDEventTap` 和 `kCGSessionEventTap` 各挂一个 listen-only tap,
分别向两层注入合成事件:

| 注入目标 | HID tap 观察到 | Session tap 观察到 |
|---|---|---|
| `.cgSessionEventTap` | 0 | 1 |
| `.cghidEventTap` | 1 | 1 |

**Session 层注入的事件不经过 HID 层。** agent 用
`CGEvent.post(tap:.cgSessionEventTap)`,因此挂在 HID 层的阻断器看不见它、
也就挡不住它。

阻断状态下的对照(同样两次注入):

| | HID tap | Session tap |
|---|---|---|
| 基线 | 1 | **2** |
| 阻断中 | 1 | **1** |

阻断中 Session tap 只收到 1 个 —— 少的那个正是 HID 层注入的,被吞掉了。

## 2. 远程桌面工具可按 PID 精确放行

远程桌面(实测对象 UURemote)是软件注入且经过 HID 层,事件带发起进程 PID:

```
RESULT total=679
  pid=58218  n=679  /Applications/UURemote.app/Contents/Helpers/UURemoteServer
```

679/679 全部归属明确,故可在回调里读
`CGEventField.eventSourceUnixProcessID` 精确放行。真实硬件事件的 PID 为 0。

白名单生效后的真实使用统计:

```
RELEASED (SIGTERM) blocked=0 allowed=1936
```

## 3. 调光不影响画面捕获;display sleep 会

| 手段 | 物理面板 | `screencapture` 结果 |
|---|---|---|
| 基线(不处理) | 亮 | 241.2 / 255 |
| DDC/BetterDisplay 亮度归零 | 黑 | **222.6 / 255**(真实内容) |
| `pmset displaysleepnow` | 黑 | **0.0 / 255**,部分显示器直接截图失败 |

**`pmset displaysleepnow` 绝不可用于此目的** —— 它让 WindowServer 停止合成,
GUI agent 随之失明。

## 4. 显示器控制:m1ddc 不够,且必须用 displayID 定址

`m1ddc` 对内置屏和 DELL U3219Q 写不进去:

```
display 1: 110 → 写 0 → 110   ✗
display 4: 110 → 写 0 → 110   ✗
```

改用 BetterDisplay 后四块全部成功。但**必须用 `-displayID` 定址**:

| 字段 | 问题 |
|---|---|
| `name` | 两块小米都叫 `Mi Monitor`,一次匹配两块 |
| `originalName` | 内置屏是 `Color LCD`,但 `-namelike="Color LCD"` 返回空 |
| `displayID` | ✅ 唯一且稳定 |

## 5. TCC 归责:哪些启动路径能创建事件 tap

创建事件 tap 需要辅助功能权限,而 TCC 按**责任进程**归责:

| 启动方式 | 责任进程 | `curtain on` |
|---|---|---|
| 已授权的交互式 shell | 该 shell | ✅ |
| SSH | `sshd` | ❌ |
| launchd | `launchd` | ❌ |
| AppleScript applet | applet 自身 | ❌ |

因此 `hid-blocker` 必须持有自己的授权。**授权绑定代码签名哈希,
重新编译后失效**(旧授权行仍留在 TCC.db 里,看起来像已授权,极易误判)。

**但 `curtain off` 不需要任何权限** —— 它只是发 SIGTERM 加恢复亮度,
任何终端、任何会话都能执行。这是"永远不会被锁在外面"的保证。

## 6. 为什么不用真锁屏

- **Codex Locked use** 存在插件冷启动竞态:锁屏后 SecurityAgentHelper 加载
  插件需时间,而 Computer Use 的提交后验证窗口约 2 秒,插件晚约 0.34 秒
  创建完 → 收到 `DENY`;重试又与前一条授权链重叠。
- **Claude Computer Use** 官方明确不支持锁屏
  ("your computer needs to be awake and the Claude Desktop app needs to be open")。

排查过程中另有两个易误判之处记录在此:

- `Library Validation failed ... StagedPlugins/...` 是**回落噪音**,不是故障。
  系统试完暂存路径失败后会从标准路径成功加载,
  `authd: running mechanism CodexComputerUseAuthorizationPlugin:allow` 即证据。
- `sysadminctl -screenLock status` 报 `off` **不代表不会锁屏**。
  `askForPassword=1` 加上启动屏保仍会真正锁上。这两个开关不是同一套机制。

## 7. 拒绝名单:如何在不确定性下做安全设计

「放行一切 `pid != 0`」可免去白名单配置,但存在一个无法远程验证的风险:
键盘增强工具抓取物理键盘后经虚拟 HID 设备重发事件,若带非零 PID 则物理输入
被整体放行。

本项目未去验证「Karabiner 重发事件是否带 PID」,而是用**拒绝名单**让两种
可能都安全:

| 若重发事件 | 拒绝名单的作用 |
|---|---|
| 带非零 PID | 堵住它,物理输入仍被拦 |
| 为 `pid=0` | 无害的空操作,本来就会被拦 |

本机解析结果(Karabiner-Elements 14.x):

```
[3 个进程] Karabiner-Core-Service.app
[2 个进程] Karabiner-VirtualHIDDevice-Daemon.app
[3 个进程] org.pqrs.Karabiner-DriverKit-VirtualHIDDevice
```

注意 dext 位于 `/Library/SystemExtensions/<UUID>/`,UUID 因机器而异,
而 `pgrep -f` 不展开通配符 —— 故按不含路径的进程名匹配。
