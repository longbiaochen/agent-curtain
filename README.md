# agent-curtain

**拉上幕帘,后台照常演出。**

macOS 上的「假锁屏」:熄灭全部显示器、阻断物理键鼠,但**保持会话解锁**,
让 GUI agent 继续工作,同时按 PID 精确放行远程桌面工具。

```
curtain on      # 四块屏全黑,物理键鼠失效,agent 照常
curtain off     # 拉开
curtain status
```

## 解决什么问题

一台常驻办公室、跑着无人值守 agent 的 Mac。会有人进来,但真锁屏会让
GUI agent 全部停摆:

- **Codex Locked use** 有插件冷启动竞态,不可靠
- **Claude Computer Use** 官方不支持锁屏

于是只剩两个坏选项:锁屏但 agent 停工,或不锁屏但桌面裸奔。

`agent-curtain` 提供第三条:**屏幕全黑 + 物理输入失效 + agent 照常 + 远程运维照常**。

## 原理

macOS 事件分层:物理键鼠进入 `kCGHIDEventTap`;agent 用
`CGEvent.post(tap:.cgSessionEventTap)` 注入的合成事件**不经过该层**。

所以阻断器挂在 HID 层时,只吞物理输入,对 agent 完全透明。
远程桌面工具经 HID 层但事件带自身 PID,可按 PID 精确放行。

完整实测数据见 [docs/FINDINGS.md](docs/FINDINGS.md)。

## ⚠️ 安全边界

**本工具的安全强度低于真锁屏。** 会话是解锁的,能绕过输入阻断的人
——插一个新键盘、直接重启、把硬盘拆走——即可进入桌面。

它挡的是**机会型闯入**(同事路过、访客进门),不是有准备的攻击者。
人不在且没有 GUI agent 任务时,真锁屏仍是更稳妥的选择。

配合 FileVault 使用;不要用它保护高价值数据。

## 安装

```bash
git clone https://github.com/<you>/agent-curtain.git
cd agent-curtain && ./install.sh
```

依赖:
- macOS(在 26.5.2 / Apple Silicon 上开发验证)
- Xcode Command Line Tools(`swiftc`)
- [BetterDisplay](https://betterdisplay.pro/) —— 调光后端,`brew install --cask betterdisplay`
- (可选)Karabiner-Elements —— 热键宿主

安装后**必须**给 `~/.local/libexec/hid-blocker` 授予辅助功能权限:
系统设置 → 隐私与安全性 → 辅助功能 → 添加该二进制。

> TCC 授权绑定代码签名哈希,**重新编译后需要重新授权**。
> 旧授权行仍会留在 TCC.db 里,看起来像已授权 —— 这是个很容易误判的坑。

## 白名单

`~/.config/curtain/allowlist`,每行一个可执行文件路径。按路径匹配、
每 3 秒刷新 PID,因此进程重启换了 PID 依然有效。

```
/Applications/UURemote.app/Contents/Helpers/UURemoteServer
```

agent 的合成事件走 session 层、不经过 HID 层,**无需**列在这里。

### 免配置模式(有风险)

物理输入的 `pid` 恒为 0,软件注入的事件带发起进程 PID。所以理论上
「放行一切 `pid != 0`」就能免去白名单:

```
curtain on --allow-any-injected
```

这个模式的风险由**拒绝名单**兜住。

### 拒绝名单

`~/.config/curtain/denylist`,优先级**高于**白名单和 `--allow-any-injected`。

存在的理由:键盘增强工具(如 Karabiner-Elements)抓取物理键盘后,经自身虚拟
HID 设备重发事件。若重发事件带非零 PID,「放行一切 `pid != 0`」会把物理键盘
整体放行,阻断器失效。

默认拒绝名单包含 Karabiner 的三个组件。这个设计的好处是**不依赖对未知行为的
判断**:若重发事件带 PID,拒绝名单堵住它;若它们其实是 `pid=0`(DriverKit
设备的常见行为),拒绝名单是无害的空操作。**两种情况下都安全。**

```bash
curtain deny     # 编辑拒绝名单
curtain status   # 查看解析到的进程数
```

## 拉开方式

| 方式 | 需要辅助功能权限 |
|---|---|
| 远程桌面 → 终端 → `curtain off` | 否 |
| `ssh <host> curtain off` | 否 |
| 热键 `Ctrl+Opt+Cmd+Shift+U` | 否(Karabiner 宿主) |
| `curtain on 3600` 显式超时 | — |

**`curtain off` 不需要任何权限** —— 它只是发 SIGTERM 加恢复亮度。
只有 `on` 需要辅助功能权限。这是"永远不会被锁在外面"的保证。

默认**无自动解除**:幕帘只应由人主动拉开。需要超时就显式传秒数。

## 设计细节

- **看门狗**:阻断器以任何方式退出(超时/热键/SIGTERM/崩溃)都恢复亮度
- **tap 自愈**:捕获 `tapDisabledByTimeout` / `ByUserInput` 后自动重新启用
- **提示条**:顶部居中横幅。物理屏是黑的所以现场看不到,但远程桌面看的是
  framebuffer 所以能看到。`ignoresMouseEvents`,不干扰 agent 点击
- **多屏**:插拔显示器自动重建横幅

## 已知限制

- **「物理输入被阻断」这一核心行为尚未用真实按键验证过。** 开发期间所有测试
  均为程序化注入,`blocked` 计数从未由真人按键产生。逻辑与分层证据充分
  (见 FINDINGS.md),拒绝名单也覆盖了已知的绕过路径,但请在你自己的机器上
  实测后再依赖它。
- `hid-blocker` 内置的解除热键同样未经真实按键验证 —— 程序化模拟的键盘事件
  到不了 HID 层,无法自动化测试。Karabiner 那条是主路径。
- 仅在 Apple Silicon / macOS 26.5.2 上验证过。
- BetterDisplay 首次运行需要授权。

## License

MIT
