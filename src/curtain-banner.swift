import Cocoa
// sg-banner —— screen-guard 生效时的屏幕提示条。
// 物理面板是黑的,但 framebuffer 仍在渲染,所以这个提示条:
//   · 现场闯入者看不到(屏幕全黑)
//   · 你从 UURemote 能看到(远程看的是 framebuffer)
//   · agent 截图会拍到 —— 故意做得小且固定在顶部居中,不遮挡工作区

class Banner: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        for screen in NSScreen.screens { make(on: screen) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                self.windows.forEach { $0.close() }; self.windows.removeAll()
                for s in NSScreen.screens { self.make(on: s) }
            }
    }
    func make(on screen: NSScreen) {
        let w: CGFloat = 560, h: CGFloat = 44
        let f = screen.frame
        let rect = NSRect(x: f.midX - w/2, y: f.maxY - h - 12, width: w, height: h)
        let win = NSWindow(contentRect: rect, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true          // 绝不干扰 agent 点击
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedRed: 0.75, green: 0.10, blue: 0.10, alpha: 0.92).cgColor
        box.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString:
            "🔒 CURTAIN 幕帘已拉上 · 物理键鼠已阻断 · Ctrl+Opt+Cmd+Shift+U 解除")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 12, width: w, height: 20)
        box.addSubview(label)
        win.contentView = box
        win.orderFrontRegardless()
        windows.append(win)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)            // 不进 Dock、不抢焦点
let d = Banner(); app.delegate = d
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }
app.run()
