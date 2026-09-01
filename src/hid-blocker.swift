import Cocoa
import Darwin

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
//   --allow-any-injected: 放行一切 pid!=0 的事件(免配置)
//   --deny <path>:        无论何种模式都拒绝该进程的事件,优先级最高
//
// 拒绝名单解决了 --allow-any-injected 的核心风险:键盘增强工具
// (Karabiner-Elements)抓取物理键盘后经自身虚拟 HID 设备重发事件。
// 若重发事件带非零 PID,放行规则会把物理键盘整体放行 —— 显式拒绝可堵住。
// 而若那些事件其实是 pid=0(DriverKit 设备的常见行为),拒绝名单是无害的
// 空操作。**两种情况下都安全**,因此无需先验证究竟是哪一种。
//
// 安全:硬性计时器到点必解除;SIGTERM/SIGINT 立即解除;
//      tap 被系统因超时禁用时自动重新启用。

var allowedPaths: [String] = []
var deniedPaths: [String] = []
var allowedPIDs = Set<Int32>()
var deniedPIDs = Set<Int32>()
var blockedCount = 0
var allowedCount = 0
let lock = NSLock()
var tapRef: CFMachPort?
var signalSources: [DispatchSourceSignal] = []

func processSnapshot() -> [(pid: Int32, path: String)] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
    let actual = pids.withUnsafeMutableBytes { raw in
        proc_listallpids(raw.baseAddress, bytes)
    }
    guard actual > 0 else { return [] }

    var result: [(Int32, String)] = []
    for pid in pids.prefix(Int(actual)) where pid > 0 {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
        result.append((pid, URL(fileURLWithPath: String(cString: buffer))
            .standardizedFileURL.resolvingSymlinksInPath().path))
    }
    return result
}

func resolvedRule(_ raw: String) -> (path: String?, name: String?) {
    guard raw.hasPrefix("/") else { return (nil, raw) }
    let standardized = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
    if standardized.pathExtension == "app",
       let executable = Bundle(url: standardized)?.executableURL {
        return (executable.standardizedFileURL.resolvingSymlinksInPath().path, nil)
    }
    return (standardized.path, nil)
}

func pidsFor(_ rules: [String], in processes: [(pid: Int32, path: String)]) -> Set<Int32> {
    let resolved = rules.map(resolvedRule)
    var found = Set<Int32>()
    for process in processes {
        let executableName = URL(fileURLWithPath: process.path).lastPathComponent
        if resolved.contains(where: { rule in
            if let path = rule.path { return process.path == path }
            if let name = rule.name { return executableName == name }
            return false
        }) {
            found.insert(process.pid)
        }
    }
    return found
}
func refreshPIDs() {
    let processes = processSnapshot()
    let a = pidsFor(allowedPaths, in: processes), d = pidsFor(deniedPaths, in: processes)
    lock.lock(); allowedPIDs = a; deniedPIDs = d; lock.unlock()
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
var expectDeny = false
for a in args.dropFirst(2) {
    if expectDeny { deniedPaths.append(a); expectDeny = false }
    else if a == "--allow-any-injected" { allowAnyInjected = true }
    else if a == "--deny" { expectDeny = true }
    else { allowedPaths.append(a) }
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
        // 拒绝名单优先级最高,压过 --allow-any-injected 与白名单
        let denied = pid != 0 && deniedPIDs.contains(pid)
        let allowed = !denied && pid != 0 && (allowAnyInjected || allowedPIDs.contains(pid))
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
print("ARMED seconds=\(Int(seconds)) allowlist=\(allowedPaths.count)path/\(n)pid anyInjected=\(allowAnyInjected) deny=\(deniedPaths.count)path hotkey=Ctrl+Opt+Cmd+Shift+U")
fflush(stdout)

// 每 3 秒刷新白名单 PID(进程重启后 PID 会变)
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in refreshPIDs() }
// 硬性自动解除
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { release("timeout") }
for (number, reason) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { release(reason) }
    source.resume()
    signalSources.append(source)
}
CFRunLoopRun()
