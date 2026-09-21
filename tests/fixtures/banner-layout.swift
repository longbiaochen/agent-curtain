import AppKit

@main
struct BannerLayoutTest {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let controller = BannerController()
        NSApp.hide(nil)
        controller.show(.enabling)
        defer { controller.hide() }

        let screens = NSScreen.screens
        precondition(!screens.isEmpty && controller.windows.count == screens.count)
        for (screen, window) in zip(screens, controller.windows) {
            precondition(screen.frame.contains(window.frame), "banner outside \(screen.localizedName)")
            precondition(abs(window.frame.maxY - screen.frame.maxY) < 1, "banner not at screen top")
            precondition(abs(window.frame.midX - screen.frame.midX) < 1, "banner not centered")
            precondition(window.frame.height <= max(33, screen.safeAreaInsets.top + 1), "banner too tall")
            if screen.safeAreaInsets.top > 0,
               let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let segments = window.contentView!.subviews
                precondition(segments.count == 2, "expected symmetric wings")
                precondition(segments[0].frame.width == segments[1].frame.width, "unequal wings")
                precondition(window.frame.minX + segments[0].frame.maxX <= left.maxX, "left wing overlaps notch")
                precondition(window.frame.minX + segments[1].frame.minX >= right.minX, "right wing overlaps notch")
                precondition(segments.allSatisfy { $0.frame.width <= 140 }, "wings too wide")
            } else {
                precondition(window.frame.width <= 240, "banner too wide")
            }
            precondition(window.ignoresMouseEvents, "banner intercepts clicks")
            precondition(window.isVisible && !window.canHide, "banner can disappear with the app")
            print("\(screen.localizedName): \(window.frame) PASS")
        }

        let numbers = controller.windows.map(\.windowNumber)
        for state in BannerController.Presentation.allCases {
            controller.show(state)
            precondition(controller.windows.map(\.windowNumber) == numbers, "state change rebuilt windows")
            for window in controller.windows {
                precondition(window.title.contains(state.status), "state label is stale")
                for segment in window.contentView!.subviews {
                    let label = segment.subviews.compactMap { $0 as? NSTextField }.first!
                    precondition(label.intrinsicContentSize.width <= label.frame.width, "status text is clipped: \(label.stringValue)")
                }
            }
        }
        // A delayed release must never hide a new enable operation.
        controller.finishRelease()
        controller.show(.enabling)
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        precondition(controller.displayCount == screens.count && controller.presentation == .enabling)
        controller.finishRelease()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        precondition(controller.windows.isEmpty, "release did not dismiss the banner")
        print("banner-layout: geometry, complete labels, in-place transitions and dismissal passed")
    }
}
