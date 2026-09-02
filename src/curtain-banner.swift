import Cocoa
// sg-banner —— screen-guard 生效时的屏幕提示条。
// 物理面板是黑的,但 framebuffer 仍在渲染,所以这个提示条:
//   · 现场闯入者看不到(屏幕全黑)
//   · 你从 UURemote 能看到(远程看的是 framebuffer)
//   · agent 截图会拍到 —— 故意做得小且固定在顶部居中,不遮挡工作区

class Banner: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        selfTestIfRequested()
    }

    // 屏幕数没变时只挪位置,不销毁窗口。
    // 销毁路径才是 2026-09-02 那次崩溃的现场(AppKit 在 CA 事务里
    // 释放窗口的过渡动画),而分辨率变化、显示器睡醒这类最常见的
    // 屏幕参数变化根本不需要重建窗口。
    func rebuild() {
        let screens = NSScreen.screens
        while windows.count > screens.count {
            let extra = windows.removeLast()
            extra.orderOut(nil)
            extra.close()
        }
        for (index, screen) in screens.enumerated() {
            if index < windows.count {
                windows[index].setFrame(frame(on: screen), display: true)
            } else {
                windows.append(make(on: screen))
            }
        }
    }

    func frame(on screen: NSScreen) -> NSRect {
        let w: CGFloat = 560, h: CGFloat = 44
        let f = screen.frame
        return NSRect(x: f.midX - w/2, y: f.maxY - h - 12, width: w, height: h)
    }

    @discardableResult
    func make(on screen: NSScreen) -> NSWindow {
        let w: CGFloat = 560, h: CGFloat = 44
        let rect = frame(on: screen)
        let win = NSWindow(contentRect: rect, styleMask: .borderless,
                           backing: .buffered, defer: false)
        // 关键:NSWindow 默认 isReleasedWhenClosed = true。close() 会自己
        // 释放窗口一次,而 windows 数组里的强引用被 ARC 释放时又是一次 ——
        // 双重释放,崩在后面某次 autorelease pool pop 里(2026-09-02 11:18:50,
        // EXC_BAD_ACCESS @ -[_NSWindowTransformAnimation dealloc])。
        win.isReleasedWhenClosed = false
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

        // 文案可通过 CURTAIN_BANNER_TEXT 覆盖,便于本地化。
        let text = ProcessInfo.processInfo.environment["CURTAIN_BANNER_TEXT"]
            ?? "🔒 CURTAIN IS DRAWN · physical input blocked · Ctrl+Opt+Cmd+Shift+U to release"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 12, width: w, height: 20)
        box.addSubview(label)
        win.contentView = box
        win.orderFrontRegardless()
        return win
    }

    // 重建路径的冒烟钩子:
    //   CURTAIN_BANNER_SELFTEST=<次数> curtain-banner
    // 把 didChangeScreenParameters 发 <次数> 遍,每遍转一次 runloop 让 CA 事务
    // 提交完,验证窗口数始终等于屏幕数且不崩。
    // 注意:合成的通知**不会**复现 2026-09-02 那次崩溃 —— 那需要真实的显示器
    // 重配置才会让 AppKit 建出 _NSWindowTransformAnimation。双重释放本身由
    // tests/banner-lifetime.zsh 用 weak 引用确定性地证明。
    func selfTestIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["CURTAIN_BANNER_SELFTEST"],
              let rounds = Int(raw), rounds > 0 else { return }
        DispatchQueue.main.async {
            for round in 1...rounds {
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                FileHandle.standardError.write("selftest round \(round)/\(rounds) ok windows=\(self.windows.count)\n".data(using: .utf8)!)
            }
            FileHandle.standardError.write("SELFTEST PASS\n".data(using: .utf8)!)
            exit(0)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)            // 不进 Dock、不抢焦点
let d = Banner(); app.delegate = d
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }
app.run()
