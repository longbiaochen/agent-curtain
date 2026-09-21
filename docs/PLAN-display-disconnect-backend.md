# 外接显示器逻辑断开实现计划

状态：已实施；本机显示拓扑验收通过，睡眠唤醒和 iPad 端目视确认仍有外部验收门槛
目标平台：Apple Silicon、macOS 26 及以上
目标行为：启用 AgentCurtain 后，仅保留内屏处于活动显示拓扑，使外屏窗口回到内屏；解除保护、应用异常退出、睡眠唤醒和热插拔后可靠恢复原显示布局。

## 1. 实施前确认的基线

- 当前候选代码已经实现 BetterDisplay Pro 路径：保存 UUID、主屏、位置、分辨率和旋转，断开全部非主屏，随后按 UUID 恢复。
- `DisplaySessionOperations` 在捕获、断开和恢复前都要求 `proAvailable=on`，这是当前功能不能在无 Pro 环境工作的直接原因。
- 现有独立 watchdog 会在主应用异常退出后恢复连接、布局和亮度，但其恢复代码同样写死为 `BetterDisplayClient`。
- 本机 BetterDisplay 二进制导入私有系统符号 `CGSConfigureDisplayEnabled`。当前 macOS 可通过 `dlsym` 解析该符号，Apple 公共 SDK 没有对应公开接口。
- 既往实机证据表明，连续显示拓扑重配置可能中断 UURemote 的 ScreenCaptureKit 流；实现必须合并配置事务并避免全局重复切换。

## 2. 范围与决策

### 2.1 本次范围

新增可选择的显示连接后端：

1. `SystemDisplayConnectionBackend`
   - Apple Silicon 上私有 SPI 可解析时优先使用。
   - 运行时通过 `dlopen`/`dlsym` 加载 `CGSConfigureDisplayEnabled`。
   - 在一次 CoreGraphics 配置事务中启用或停用指定显示器。

2. `BetterDisplayConnectionBackend`
   - 系统 SPI 不可用时，BetterDisplay Pro 作为回退。
   - 继续使用 `disconnectAllButMain` 和 `connectAllDisplays`。

自动选择规则：

```text
运行于 arm64 且 CGSConfigureDisplayEnabled 可解析
  -> system-spi

否则，BetterDisplay Pro 可用
  -> betterdisplay

否则
  -> 在调暗屏幕和拦截输入前失败
```

### 2.2 保留的现有依赖

第一版仍使用 BetterDisplay 免费能力完成：

- 显示器 UUID 和当前 Display ID 枚举；
- 亮度读取、归零和恢复；
- 主屏、位置、分辨率和旋转的保存与恢复。

本次只替换需要 Pro 的连接管理。完全移除 BetterDisplay 依赖属于后续独立任务。

## 3. 代码设计

### 3.1 后端接口

新增 `Sources/AgentCurtainCore/DisplayConnectionBackend.swift`：

```swift
public enum DisplayConnectionBackendKind: String, Codable, Sendable {
    case betterDisplay
    case systemSPI
}

public protocol DisplayConnectionBackend: Sendable {
    var kind: DisplayConnectionBackendKind { get }
    func disconnectExternalDisplays(
        backup: DisplaySessionBackup,
        isCancelled: @Sendable () -> Bool
    ) throws
    func reconnectDisplays(backup: DisplaySessionBackup) throws
}
```

增加后端工厂，负责能力检测和自动选择。后端必须在任何亮度、输入拦截或显示写操作发生前选定。

### 3.2 BetterDisplay 后端

新增 `Sources/AgentCurtainCore/BetterDisplayConnectionBackend.swift`：

- 把现有 `disconnectAllButMain`、`connectAllDisplays` 和连接状态读回迁入该后端。
- 保留 Pro 检查，但不再让 `DisplaySessionOperations.capture` 无条件要求 Pro。
- 恢复仍以 UUID 为准，避免 Display ID 在重新连接后变化。

### 3.3 系统 SPI 后端

新增 `Sources/AgentCurtainCore/SystemDisplayConnectionBackend.swift`：

- 只在 arm64 构建中报告可用。
- 动态加载 CoreGraphics，不在链接阶段引用私有符号。
- 将 `CGSConfigureDisplayEnabled` 转换为带明确 C 调用约定的函数指针。
- 使用 `CGBeginDisplayConfiguration`、`CGSConfigureDisplayEnabled`、`CGCompleteDisplayConfiguration` 组成事务。
- 一个事务中断开所有外屏；一个事务中恢复所有保存的外屏。
- 任一调用或提交失败时取消事务并返回结构化错误。

首版使用 `kCGConfigureForSession`，与现有 watchdog 恢复契约保持一致。`kCGConfigureForAppOnly` 仅作为实机实验项；只有证明主应用退出时能够稳定自动恢复，才考虑替换。

### 3.4 安全断开顺序

1. 捕获当前显示拓扑并写入 0600 备份。
2. 选定连接后端，将后端类型写入备份。
3. 启动独立 watchdog。
4. 调暗显示器并读回亮度。
5. 确认恰好存在一个内建显示器。
6. 如果外屏是主屏，先把主屏切换到内屏并等待读回稳定。
7. 一次事务中断开所有外屏。
8. 用 `CGGetActiveDisplayList` 和 UUID 验证仅内屏处于活动状态。
9. 验证失败时立即通过同一后端重新启用外屏，再恢复布局和亮度。
10. 验证成功后才进入 `drawn/internal-only` 状态。

### 3.5 备份格式

将 `DisplaySessionBackup` 升级为 v2，并保持 v1 可解码：

```text
version
ownerPID
createdAt
connectionBackend
displays[]
  uuid
  displayID
  isBuiltin
  wasMain
  placement
  resolution
  rotation
```

规则：

- v2 恢复必须使用备份记录的后端。
- v1 备份继续走 BetterDisplay 恢复路径。
- 只有连接、主屏、分辨率、旋转、位置和亮度全部读回成功后才删除备份。
- 失败时把 `.restoring.<pid>` 归还原路径，允许菜单或下次启动重试。

### 3.6 系统 SPI 恢复顺序

1. 使用保存的 Display ID 执行 `enabled=true`。
2. 等待显示配置通知和活动列表稳定。
3. 通过 BetterDisplay 标识列表按 UUID 重新取得当前 Display ID。
4. 对仍未在线的 UUID 使用新 ID 重试。
5. 如果 BetterDisplay Pro 此时可用，允许调用 `connectAllDisplays` 作为最后的软件兜底。
6. 所有目标 UUID 在线后，恢复模式、旋转、主屏和位置。
7. 仍有显示器缺失时保留备份并报告 `restore-pending`，不得宣称恢复成功。

## 4. 应用与 watchdog 改造

### 4.1 DisplaySession

修改：

- `Sources/AgentCurtainCore/DisplaySession.swift`
- `Sources/AgentCurtain/DisplaySessionController.swift`

工作项：

- 将连接操作从 `BetterDisplayClient` 中抽出。
- 捕获阶段选择后端并写入备份。
- 断开、恢复和热插拔都通过后端接口执行。
- 移除捕获阶段无条件 Pro 检查。

### 4.2 watchdog

修改：

- `Sources/AgentCurtainRestoreWatchdog/main.swift`
- `Sources/AgentCurtain/BrightnessController.swift`

工作项：

- watchdog 从备份读取后端类型并创建对应恢复后端。
- 系统 SPI 恢复不要求 Pro。
- BetterDisplay CLI 路径继续传入，用于亮度、UUID 重映射和布局恢复。
- 保持先恢复显示连接、后恢复亮度的顺序。

### 4.3 热插拔

修改 `CurtainCoordinator.screensChanged()` 的下游行为：

- 只捕获和断开新出现的外屏。
- 不重新执行全局 `disconnectAllButMain`。
- 合并短时间内连续到达的显示配置通知。
- 每次配置完成后读取实际活动 UUID，再决定是否需要下一次动作。

## 5. 状态与诊断

扩展 `curtain status` 和 `curtain doctor`：

```text
displayBackend=betterdisplay|system-spi
betterDisplayPro=on|off|unknown
privateDisplaySPI=available|missing|unsupported-architecture
displayMode=internal-only|all-displays|restore-pending
restorePending=<count>
```

README 调整：

- BetterDisplay app 仍是第一版的亮度和布局依赖。
- Pro 从必需改为可选。
- Apple Silicon 优先使用系统 SPI，BetterDisplay Pro 仅作回退。
- 私有 SPI 可能随 macOS 更新变化，升级系统后必须重新验收。

## 6. 测试计划

### 6.1 单元测试

- SPI 可用时选择系统 SPI 后端，不探测 Pro 即可完成选择。
- SPI 不可用且 Pro 可用时选择 BetterDisplay 后端。
- SPI 缺失或架构不支持时，在任何显示写操作前失败。
- 主屏切换完成后才允许断开外屏。
- 多外屏在一个事务中处理。
- 部分调用失败时取消事务并恢复已改变的状态。
- 离线显示器不在活动列表时，仍使用保存 ID 恢复。
- Display ID 变化后按 UUID 重映射。
- v1 备份兼容恢复。
- 未完成恢复时保留备份。
- 新外屏只触发局部断开。

系统 SPI 测试通过注入函数指针和配置事务适配器完成，不对真实显示器写入。

### 6.2 集成测试

- coordinator 成功、取消和失败回滚状态转换。
- `kill -9` owner 后 watchdog 同时恢复显示拓扑与亮度。
- BetterDisplay 和系统 SPI 两种备份均能被 watchdog 识别。
- `curtain status` 准确报告所选后端和待恢复数量。
- 完整 Swift 测试、shell 集成测试和候选构建通过。

### 6.3 签名验证

- 在临时目录构建候选，避免 Documents 元数据污染签名。
- 使用项目既有 Developer ID 和 Hardened Runtime。
- 验证主程序、内嵌 watchdog 和外层 app：
  - `codesign --verify --deep --strict`
  - `codesign -dv --verbose=4`
  - `spctl -a -vv`

## 7. 实机验收

物理显示器写操作只在代码、自动化测试、候选签名和软件回滚路径全部完成后进行。该步骤需要用户对物理设备操作的一次明确授权。

验收前提：

- 本机控制台可用；
- UURemote 已连接并能持续刷新；
- 原布局、主屏、显示模式、旋转和亮度均已记录；
- watchdog 正在运行且备份可读；
- 不使用 `pmset displaysleepnow`。

验收场景：

1. 正常启用：外屏退出活动拓扑，窗口回到内屏，UU 只显示一个屏幕。
2. 正常解除：所有外屏、窗口布局、主屏、分辨率、旋转和亮度恢复。
3. 主应用 `kill -9`：watchdog 自动恢复，无残留 `restore-pending`。
4. 启用期间接入新外屏：只处理新屏，不扰动已稳定的 UU 流。
5. 睡眠唤醒：期望状态与实际拓扑一致，必要时只执行一次修复事务。
6. UURemote：日志无持续 `streamOutput NOT found` 或 `stream stopped in dealloc`，画面持续刷新。

每个场景先恢复到完整可用状态再进入下一个场景，避免连续拓扑切换造成误判。

## 8. 发布和回滚

发布顺序：

1. 生成签名候选，不覆盖正式安装。
2. 完成只读检查和自动化测试。
3. 获得实机写操作授权后完成硬件验收。
4. 安装到 `/Applications/AgentCurtain.app`。
5. 验证正式安装路径、控制 socket、登录项、watchdog 和 `curtain doctor`。
6. 留下 `state=open`、全部外屏已恢复、UU 可连接的最终场景。

回滚策略：

- 保留 BetterDisplay Pro 官方后端作为系统 SPI 不可用时的自动回退。
- 系统 SPI 不可用或验收失败时，`auto` 回退 BetterDisplay Pro；无 Pro 时在写操作前明确失败。
- 卸载或替换候选前先执行恢复，确认不存在显示与亮度备份。
- 不修改、重签或替换 BetterDisplay.app。

## 9. 完成标准

以下条件全部满足才能宣布交付完成：

- 无 Pro 时能够选中系统 SPI 后端并把活动拓扑收敛到内屏。
- 外屏窗口实际回到内屏，UURemote 实际只显示一个持续更新的屏幕。
- 正常解除和 `kill -9` 都能恢复全部外屏及原布局。
- 热插拔与睡眠唤醒不留下失联显示器或待恢复备份。
- 自动化测试、候选签名、正式安装和实机验收都有对应证据。
- 工作树中的无关改动未被覆盖或暂存。

## 10. 2026-09-20 验收记录

已验证：

- 本机 BetterDisplay Pro 为 `off`，正式安装版本选择 `system-spi`。
- 四屏正常启用后 CoreGraphics 活动列表只剩内屏；正常解除后四屏、主屏、位置、分辨率和亮度恢复。
- 主应用 `kill -9` 后，包内 watchdog 恢复四屏且删除恢复记录。
- 用 SPI 模拟外屏重新活动后，应用完成桥接恢复并再次收敛到仅内屏；解除后无延迟协调错误。
- 26 个 Swift 测试、5 个 coordinator 场景、watchdog 集成、banner 测试和签名候选验证通过。
- UURemote 服务保持已建立连接，45 分钟日志中两类已知流错误均为 0。
- 正式安装状态为 `open`、`activeDisplays=4`、`restorePending=0`。

剩余门槛：

- 当前系统拒绝 `pmset sleepnow`，返回 IOKit `0xe00002e2`；当前会话中未取得一次真实睡眠唤醒证据。
- 当前工具不能读取 iPad 上的实际画面；iPad 端“单屏且持续刷新”仍需一次目视确认。
- Developer ID 严格验签通过；未做 Apple 公证，因此 `spctl` 报 `Unnotarized Developer ID`。

## 11. 2026-09-21 窗口恢复验收记录

已完成：

- 启用保护前按显示 UUID 保存外屏可见窗口的原 frame，并在显示拓扑恢复稳定后执行
  `size → position → size` 写入和 2 pt 容差读回。
- 正常解除保护时，ChatGPT、Claude、SmartShadow 共 3 个外屏窗口全部回到原显示器和原位置。
- watchdog 不再直接执行 AX 窗口写入。它恢复显示拓扑和亮度后释放 `recovery.lock`，再通过
  LaunchServices 重启正式 AgentCurtain，由持有辅助功能权限的主程序回放非空窗口备份。
- 正式安装版 `kill -9` 验收中，主进程 PID 从 `83501` 切换为 `83940`；四屏和 3 个窗口全部恢复，
  最终 `state=open`、`activeDisplays=4`、`restorePending=0`、`windowRestorePending=0`。
- watchdog 集成测试验证了锁在主程序启动前已经释放；主程序启动失败时窗口备份保持原路径，
  允许下次启动继续恢复。
- 所有 SPI 写入前都会按 UUID 刷新并持久化当前 Display ID；同 UUID 外屏以原 ID 或新 ID
  重新出现时都会重新调暗并断开。
- 启动恢复会聚合显示器、亮度和窗口阶段错误；显示器失败仍继续恢复亮度，亮度失败不会跳过窗口。
- 10 个窗口 XCTest、29 个 Swift Testing 测试、7 个 coordinator 场景、完整 `--verify`、
  Developer ID 严格验签和正式安装均通过。
