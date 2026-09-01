import Cocoa

// hid-blocker —— screen-guard 的阻断内核。
//
// 原理(2026-09-01 实测):
//   物理键鼠事件进入 kCGHIDEventTap;agent 用 CGEvent.post(tap:.cgSessionEventTap)
//   注入的合成事件不经过 HID 层,因此天然不受影响。
//   远程桌面类工具(UURemote)则是软件注入且经过 HID 层,事件带自身 PID
//   (实测 pid=58218 UURemoteServer,679/679 全部归属明确),故可按 PID 放行。
//
// 用法: hid-blocker <秒数> [--allow-any-injected] [允许的可执行路径 ...]
//   pid=0 的事件视为真实硬件输入 → 吞掉
//   白名单进程的事件 → 放行
//   --allow-any-injected: 放行一切 pid!=0 的事件(免配置,但见下方警告)
//
// ⚠️ --allow-any-injected 的风险:若某个键盘增强工具(如 Karabiner-Elements)
//    抓取物理键盘后经自身虚拟 HID 设备重发事件,且重发事件带非零 PID,
//    则物理键盘会被整体放行,阻断器失效。
//    DriverKit 设备产生的事件通常仍为 pid=0,但本项目**尚未用真实按键验证**。
//    在验证之前,请使用显式白名单(默认行为)。
//
// 安全:硬性计时器到点必解除;SIGTERM/SIGINT 立即解除;
//      tap 被系统因超时禁用时自动重新启用。

var allowedPaths: [String] = []
var allowedPIDs = Set<Int32>()
var blockedCount = 0
var allowedCount = 0
let lock = NSLock()
var tapRef: CFMachPort?

func refreshPIDs() {
    var found = Set<Int32>()
    for path in allowedPaths {
        let p = Process()
        p.launchPath = "/usr/bin/pgrep"
        p.arguments = ["-f", path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { continue }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { found.insert(pid) }
        }
    }
    lock.lock(); allowedPIDs = found; lock.unlock()
}

func release(_ reason: String) -> Never {
    if let t = tapRef { CGEvent.tapEnable(tap: t, enable: false) }
    lock.lock(); let b = blockedCount, a = allowedCount; lock.unlock()
    print("RELEASED (\(reason)) blocked=\(b) allowed=\(a)")
    fflush(stdout)
    exit(0)
}

// TCC:从桌面 app / launchd / Karabiner 启动时,责任进程不是已授权的 zsh,
// 因此本二进制必须持有自己的辅助功能授权。带 prompt 弹出系统对话框。
// 注意:TCC 授权绑定代码签名哈希 —— 重新编译本文件后需要重新授权。
let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrusted() {
    _ = AXIsProcessTrustedWithOptions(axOpts)
    FileHandle.standardError.write("FAIL: 缺少辅助功能授权 —— 已弹出对话框。请在 系统设置 > 隐私与安全性 > 辅助功能 中勾选 hid-blocker\n".data(using:.utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2, let seconds = Double(args[1]) else {
    FileHandle.standardError.write("usage: hid-blocker <seconds> [allowed-exec-path ...]\n".data(using:.utf8)!)
    exit(2)
}
var allowAnyInjected = false
for a in args.dropFirst(2) {
    if a == "--allow-any-injected" { allowAnyInjected = true } else { allowedPaths.append(a) }
}
refreshPIDs()

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue)          | (1 << CGEventType.keyUp.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue)     | (1 << CGEventType.mouseMoved.rawValue) |
    (1 << CGEventType.leftMouseDown.rawValue)    | (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue)   | (1 << CGEventType.rightMouseUp.rawValue) |
    (1 << CGEventType.otherMouseDown.rawValue)   | (1 << CGEventType.otherMouseUp.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << CGEventType.scrollWheel.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: mask,
    callback: { _, type, ev, _ in
        // 系统因回调超时/用户输入禁用了 tap → 自愈
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tapRef { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        // 解除热键必须在吞掉事件之前检查 —— 否则它自己也会被吞。
        // Ctrl+Opt+Cmd+Shift+U:四个修饰键同按,日常几乎不可能误触。
        if type == .keyDown {
            let code = ev.getIntegerValueField(.keyboardEventKeycode)
            let f = ev.flags
            if code == 32,   // kVK_ANSI_U
               f.contains(.maskControl), f.contains(.maskAlternate),
               f.contains(.maskCommand), f.contains(.maskShift) {
                release("hotkey")
            }
        }
        let pid = Int32(ev.getIntegerValueField(.eventSourceUnixProcessID))
        lock.lock()
        let allowed = pid != 0 && (allowAnyInjected || allowedPIDs.contains(pid))
        if allowed { allowedCount += 1 } else { blockedCount += 1 }
        lock.unlock()
        return allowed ? Unmanaged.passUnretained(ev) : nil
    }, userInfo: nil) else {
    FileHandle.standardError.write("FAIL: cannot create HID tap (need Accessibility permission)\n".data(using:.utf8)!)
    exit(1)
}
tapRef = tap
CFRunLoopAddSource(CFRunLoopGetCurrent(),
    CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

lock.lock(); let n = allowedPIDs.count; lock.unlock()
print("ARMED seconds=\(Int(seconds)) allowlist=\(allowedPaths.count)path/\(n)pid anyInjected=\(allowAnyInjected) hotkey=Ctrl+Opt+Cmd+Shift+U")
fflush(stdout)

// 每 3 秒刷新白名单 PID(进程重启后 PID 会变)
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in refreshPIDs() }
// 硬性自动解除
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { release("timeout") }
signal(SIGTERM) { _ in release("SIGTERM") }
signal(SIGINT)  { _ in release("SIGINT") }
CFRunLoopRun()
