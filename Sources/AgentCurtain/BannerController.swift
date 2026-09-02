import AppKit

final class BannerController {
    static let featureColor = NSColor(srgbRed: 0.75, green: 0.10, blue: 0.10, alpha: 1)

    private(set) var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var isVisible = false
    var onScreensChanged: (() -> Void)?

    var displayCount: Int { windows.count }

    func show() {
        precondition(Thread.isMainThread)
        isVisible = true
        rebuild()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.rebuild()
                self?.onScreensChanged?()
            }
        }
    }

    func hide() {
        precondition(Thread.isMainThread)
        isVisible = false
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func rebuild() {
        guard isVisible else { return }
        windows.forEach { $0.close() }
        windows.removeAll()
        NSScreen.screens.forEach { windows.append(makeWindow(on: $0)) }
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow {
        let width = min(CGFloat(620), max(CGFloat(280), screen.frame.width - 40))
        let height: CGFloat = 44
        let rect = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height - 12,
            width: width,
            height: height
        )
        let window = NSWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = Self.featureColor
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: bannerText)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 12, width: width - 24, height: 20)
        window.contentView = label
        window.orderFrontRegardless()
        return window
    }

    private var bannerText: String {
        ProcessInfo.processInfo.environment["CURTAIN_BANNER_TEXT"]
            ?? "CURTAIN IS DRAWN · physical input blocked · Ctrl+Opt+Cmd+Shift+U to release"
    }
}
