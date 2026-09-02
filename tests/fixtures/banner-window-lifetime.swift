import Cocoa

// 直接验「close() 是否在数组还持有窗口时就把它释放掉」。
// weak 引用会在 dealloc 时被清零 —— 数组还持有却变 nil,就是提前释放。
func log(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

let releasedWhenClosed = CommandLine.arguments.contains("--released-when-closed")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
log("isReleasedWhenClosed=\(releasedWhenClosed)")

var strongRefs: [NSWindow] = []
weak var weakRef: NSWindow?
autoreleasepool {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 44),
                       styleMask: .borderless, backing: .buffered, defer: false)
    win.isReleasedWhenClosed = releasedWhenClosed
    win.level = .screenSaver
    win.orderFrontRegardless()
    strongRefs.append(win)
    weakRef = win
    log("  已 orderFront 并存入数组")
    win.close()
    log("  close() 返回")
}
log("  autoreleasepool 排空后: weak 引用 \(weakRef != nil ? "仍存活" : "已被清零 —— 数组里是悬垂引用")")
strongRefs.removeAll()
log("  数组释放完成")
