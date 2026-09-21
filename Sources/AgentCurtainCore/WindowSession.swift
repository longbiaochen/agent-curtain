import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public struct WindowSessionRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    public func isNear(_ other: WindowSessionRect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance &&
            abs(y - other.y) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}

public struct WindowDisplayGeometry: Codable, Equatable, Sendable {
    public let uuid: String
    public let bounds: WindowSessionRect
    public let isBuiltin: Bool

    public init(uuid: String, bounds: WindowSessionRect, isBuiltin: Bool) {
        self.uuid = uuid
        self.bounds = bounds
        self.isBuiltin = isBuiltin
    }
}

public struct SavedWindow: Codable, Equatable, Sendable {
    public let ownerPID: Int32
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowID: UInt32?
    public let identifier: String?
    public let title: String?
    public let role: String
    public let subrole: String
    public let ordinal: Int
    public let displayUUID: String
    public let frame: WindowSessionRect
    public let relativeFrame: WindowSessionRect

    public init(
        ownerPID: Int32,
        bundleIdentifier: String?,
        applicationName: String,
        windowID: UInt32?,
        identifier: String?,
        title: String?,
        role: String,
        subrole: String,
        ordinal: Int,
        displayUUID: String,
        frame: WindowSessionRect,
        relativeFrame: WindowSessionRect
    ) {
        self.ownerPID = ownerPID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowID = windowID
        self.identifier = identifier
        self.title = title
        self.role = role
        self.subrole = subrole
        self.ordinal = ordinal
        self.displayUUID = displayUUID
        self.frame = frame
        self.relativeFrame = relativeFrame
    }
}

public struct WindowSessionBackup: Codable, Equatable, Sendable {
    public let version: Int
    public let ownerPID: Int32
    public let createdAt: Date
    public let displays: [WindowDisplayGeometry]
    public let windows: [SavedWindow]

    public init(
        ownerPID: Int32,
        createdAt: Date = Date(),
        displays: [WindowDisplayGeometry],
        windows: [SavedWindow]
    ) {
        version = 1
        self.ownerPID = ownerPID
        let milliseconds = (createdAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        self.createdAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.displays = displays
        self.windows = windows
    }
}

public enum WindowSessionBackupStore {
    public static func write(_ backup: WindowSessionBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) throws -> WindowSessionBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WindowSessionBackup.self, from: Data(contentsOf: url))
    }

    public static func claim(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let claimed = URL(fileURLWithPath: url.path + ".restoring.\(getpid())")
        do {
            try FileManager.default.moveItem(at: url, to: claimed)
            return claimed
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        }
    }

    public static func relinquish(_ claimed: URL, to original: URL) throws {
        guard FileManager.default.fileExists(atPath: claimed.path) else { return }
        try FileManager.default.moveItem(at: claimed, to: original)
    }
}

public struct WindowMatchCandidate: Equatable, Sendable {
    public let windowID: UInt32?
    public let identifier: String?
    public let title: String?
    public let role: String
    public let subrole: String
    public let ordinal: Int

    public init(
        windowID: UInt32?,
        identifier: String?,
        title: String?,
        role: String,
        subrole: String,
        ordinal: Int
    ) {
        self.windowID = windowID
        self.identifier = identifier
        self.title = title
        self.role = role
        self.subrole = subrole
        self.ordinal = ordinal
    }
}

public enum WindowSessionPlanner {
    public static func relativeFrame(_ frame: WindowSessionRect, in display: WindowSessionRect) -> WindowSessionRect {
        guard display.width > 0, display.height > 0 else { return frame }
        return WindowSessionRect(
            x: (frame.x - display.x) / display.width,
            y: (frame.y - display.y) / display.height,
            width: frame.width / display.width,
            height: frame.height / display.height
        )
    }

    public static func targetFrame(for saved: SavedWindow, on display: WindowDisplayGeometry) -> WindowSessionRect {
        if let original = savedDisplayBounds(for: saved), original.isNear(display.bounds, tolerance: 0.5) {
            return saved.frame
        }
        let relative = saved.relativeFrame
        return WindowSessionRect(
            x: (display.bounds.x + relative.x * display.bounds.width).rounded(),
            y: (display.bounds.y + relative.y * display.bounds.height).rounded(),
            width: max(1, (relative.width * display.bounds.width).rounded()),
            height: max(1, (relative.height * display.bounds.height).rounded())
        )
    }

    public static func matches(
        saved: [SavedWindow],
        candidates: [WindowMatchCandidate],
        trustWindowIDs: Bool = true
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var unused = Set(candidates.indices)

        func assign(where predicate: (SavedWindow, WindowMatchCandidate) -> Bool) {
            for savedIndex in saved.indices where result[savedIndex] == nil {
                let matches = unused.filter { predicate(saved[savedIndex], candidates[$0]) }
                guard matches.count == 1, let candidateIndex = matches.first else { continue }
                result[savedIndex] = candidateIndex
                unused.remove(candidateIndex)
            }
        }

        assign { saved, candidate in
            trustWindowIDs && saved.windowID != nil && saved.windowID == candidate.windowID &&
                compatible(saved, candidate)
        }
        assign { saved, candidate in
            nonempty(saved.identifier) != nil && saved.identifier == candidate.identifier &&
                compatible(saved, candidate)
        }
        assign { saved, candidate in
            nonempty(saved.title) != nil && saved.title == candidate.title && compatible(saved, candidate)
        }

        // AX returns windows in stable application order during a display topology change.
        // Use that order only when no windows appeared or disappeared in this application.
        if saved.count == candidates.count {
            assign { saved, candidate in
                saved.ordinal == candidate.ordinal && compatible(saved, candidate)
            }
        }
        return result
    }

    private static func compatible(_ saved: SavedWindow, _ candidate: WindowMatchCandidate) -> Bool {
        saved.role == candidate.role && saved.subrole == candidate.subrole
    }

    private static func savedDisplayBounds(for saved: SavedWindow) -> WindowSessionRect? {
        let relative = saved.relativeFrame
        guard relative.width != 0, relative.height != 0 else { return nil }
        let width = saved.frame.width / relative.width
        let height = saved.frame.height / relative.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return WindowSessionRect(
            x: saved.frame.x - relative.x * width,
            y: saved.frame.y - relative.y * height,
            width: width,
            height: height
        )
    }
}

public struct WindowRestorationReport: Equatable, Sendable {
    public let saved: Int
    public let restored: Int
    public let disappeared: Int

    public init(saved: Int, restored: Int, disappeared: Int) {
        self.saved = saved
        self.restored = restored
        self.disappeared = disappeared
    }
}

public enum WindowSessionError: Error, LocalizedError {
    case accessibilityPermission
    case noActiveDisplays
    case missingDisplays([String])
    case restoreFailures([String])

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            return "Accessibility permission is required to restore window positions"
        case .noActiveDisplays:
            return "no active displays are available for window capture"
        case .missingDisplays(let uuids):
            return "saved window displays are unavailable: \(uuids.joined(separator: ", "))"
        case .restoreFailures(let failures):
            return "window restore failed: \(failures.joined(separator: "; "))"
        }
    }
}

public enum WindowSessionOperations {
    public static func capture(ownerPID: Int32, excludingBundleIdentifier: String? = nil) throws -> WindowSessionBackup {
        guard AXIsProcessTrusted() else { throw WindowSessionError.accessibilityPermission }
        let displays = activeDisplayGeometries()
        guard !displays.isEmpty else { throw WindowSessionError.noActiveDisplays }
        let external = displays.filter { !$0.isBuiltin }
        let cgWindows = cgWindowSnapshots()
        var saved: [SavedWindow] = []

        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid > 0,
                  application.bundleIdentifier != excludingBundleIdentifier,
                  application.activationPolicy != .prohibited else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            let windows = axWindows(in: appElement)
            for (ordinal, window) in windows.enumerated() {
                guard isRestorableWindow(window),
                      axBool(window, kAXMinimizedAttribute as CFString) != true,
                      axBool(window, "AXFullScreen" as CFString) != true,
                      let frame = axWindowFrame(window),
                      let display = external.first(where: { contains($0.bounds, frame.center) }) else { continue }
                let metadata = matchCGWindow(
                    pid: pid,
                    frame: frame,
                    title: axString(window, kAXTitleAttribute as CFString),
                    snapshots: cgWindows
                )
                // A definite offscreen CG window belongs to another Space. Missing CG metadata
                // is not enough reason to discard an otherwise movable AX window.
                guard metadata?.isOnscreen != false else { continue }
                saved.append(SavedWindow(
                    ownerPID: pid,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.localizedName ?? application.bundleIdentifier ?? "pid \(pid)",
                    windowID: metadata?.windowID,
                    identifier: axString(window, kAXIdentifierAttribute as CFString),
                    title: axString(window, kAXTitleAttribute as CFString),
                    role: axString(window, kAXRoleAttribute as CFString) ?? "",
                    subrole: axString(window, kAXSubroleAttribute as CFString) ?? "",
                    ordinal: ordinal,
                    displayUUID: display.uuid,
                    frame: frame,
                    relativeFrame: WindowSessionPlanner.relativeFrame(frame, in: display.bounds)
                ))
            }
        }
        return WindowSessionBackup(ownerPID: ownerPID, displays: displays, windows: saved)
    }

    public static func restore(_ backup: WindowSessionBackup) throws -> WindowRestorationReport {
        guard backup.windows.isEmpty || AXIsProcessTrusted() else {
            throw WindowSessionError.accessibilityPermission
        }
        let neededUUIDs = Set(backup.windows.map(\.displayUUID))
        let displays = waitForDisplays(neededUUIDs: neededUUIDs)
        let missing = neededUUIDs.subtracting(displays.keys).sorted()
        guard missing.isEmpty else { throw WindowSessionError.missingDisplays(missing) }
        if backup.windows.isEmpty {
            return WindowRestorationReport(saved: 0, restored: 0, disappeared: 0)
        }

        // WindowServer reports geometry before every application has handled its screen-change
        // notification. Let that first wave settle, then verify all windows together below.
        Thread.sleep(forTimeInterval: 0.5)
        let grouped = Dictionary(grouping: backup.windows, by: ApplicationIdentity.init)
        var disappeared = 0
        var tasks: [WindowRestoreTask] = []
        var unresolved: [String] = []

        for (identity, savedWindows) in grouped {
            guard let resolvedApplication = runningApplication(for: identity) else {
                disappeared += savedWindows.count
                continue
            }
            let application = resolvedApplication.application
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let elements = axWindows(in: appElement).filter(isRestorableWindow)
            let snapshots = cgWindowSnapshots().filter { $0.pid == application.processIdentifier }
            let live = elements.enumerated().map { ordinal, element in
                let frame = axWindowFrame(element)
                let metadata = frame.flatMap {
                    matchCGWindow(pid: application.processIdentifier, frame: $0,
                        title: axString(element, kAXTitleAttribute as CFString), snapshots: snapshots)
                }
                return LiveWindow(
                    element: element,
                    match: WindowMatchCandidate(
                        windowID: metadata?.windowID,
                        identifier: axString(element, kAXIdentifierAttribute as CFString),
                        title: axString(element, kAXTitleAttribute as CFString),
                        role: axString(element, kAXRoleAttribute as CFString) ?? "",
                        subrole: axString(element, kAXSubroleAttribute as CFString) ?? "",
                        ordinal: ordinal
                    )
                )
            }
            let matches = WindowSessionPlanner.matches(
                saved: savedWindows,
                candidates: live.map(\.match),
                trustWindowIDs: resolvedApplication.sameProcess
            )
            let currentWindowIDs = Set(snapshots.map(\.windowID))
            for savedIndex in savedWindows.indices {
                guard let liveIndex = matches[savedIndex] else {
                    let saved = savedWindows[savedIndex]
                    if resolvedApplication.sameProcess,
                       let windowID = saved.windowID,
                       !currentWindowIDs.contains(windowID) {
                        disappeared += 1
                    } else {
                        unresolved.append("\(saved.applicationName) window \(saved.windowID.map(String.init) ?? String(saved.ordinal))")
                    }
                    continue
                }
                let saved = savedWindows[savedIndex]
                guard let display = displays[saved.displayUUID] else { continue }
                let target = WindowSessionPlanner.targetFrame(for: saved, on: display)
                tasks.append(WindowRestoreTask(saved: saved, element: live[liveIndex].element, target: target))
            }
        }

        let deadline = Date().addingTimeInterval(3)
        var pending = tasks
        var stablePasses = 0
        repeat {
            for task in pending where axWindowFrame(task.element)?.isNear(task.target, tolerance: 2) != true {
                _ = applyWindowFramePrecisely(task.element, frame: task.target)
            }
            Thread.sleep(forTimeInterval: 0.15)
            pending = tasks.filter { axWindowFrame($0.element)?.isNear($0.target, tolerance: 2) != true }
            if pending.isEmpty {
                stablePasses += 1
                if stablePasses >= 2 { break }
            } else {
                stablePasses = 0
            }
        } while Date() < deadline

        let failed = unresolved + pending.map {
                "\($0.saved.applicationName) window \($0.saved.windowID.map(String.init) ?? String($0.saved.ordinal))"
            }
        guard failed.isEmpty else {
            throw WindowSessionError.restoreFailures(failed)
        }
        return WindowRestorationReport(saved: backup.windows.count, restored: tasks.count, disappeared: disappeared)
    }
}

private struct ApplicationIdentity: Hashable {
    let ownerPID: Int32
    let bundleIdentifier: String?
    let applicationName: String

    init(_ window: SavedWindow) {
        ownerPID = window.ownerPID
        bundleIdentifier = window.bundleIdentifier
        applicationName = window.applicationName
    }
}

private struct LiveWindow {
    let element: AXUIElement
    let match: WindowMatchCandidate
}

private struct WindowRestoreTask {
    let saved: SavedWindow
    let element: AXUIElement
    let target: WindowSessionRect
}

private struct CGWindowSnapshot {
    let pid: Int32
    let windowID: UInt32
    let title: String?
    let frame: WindowSessionRect
    let isOnscreen: Bool
}

private func activeDisplayGeometries() -> [WindowDisplayGeometry] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).compactMap { id in
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return WindowDisplayGeometry(
            uuid: string,
            bounds: WindowSessionRect(CGDisplayBounds(id)),
            isBuiltin: CGDisplayIsBuiltin(id) != 0
        )
    }
}

private func waitForDisplays(neededUUIDs: Set<String>, timeout: TimeInterval = 4) -> [String: WindowDisplayGeometry] {
    guard !neededUUIDs.isEmpty else { return [:] }
    let deadline = Date().addingTimeInterval(timeout)
    var previous: [String: WindowDisplayGeometry] = [:]
    var stableSamples = 0
    repeat {
        let current = Dictionary(uniqueKeysWithValues: activeDisplayGeometries().map { ($0.uuid, $0) })
        if neededUUIDs.isSubset(of: Set(current.keys)) {
            if current == previous {
                stableSamples += 1
                if stableSamples >= 2 { return current }
            } else {
                stableSamples = 0
            }
        }
        previous = current
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return previous
}

private func runningApplication(for identity: ApplicationIdentity) -> (application: NSRunningApplication, sameProcess: Bool)? {
    if let existing = NSRunningApplication(processIdentifier: identity.ownerPID),
       identity.bundleIdentifier == nil || existing.bundleIdentifier == identity.bundleIdentifier {
        return (existing, true)
    }
    if let bundleIdentifier = identity.bundleIdentifier {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if matches.count == 1 { return (matches[0], false) }
    }
    let matches = NSWorkspace.shared.runningApplications.filter {
        $0.localizedName == identity.applicationName && $0.activationPolicy != .prohibited
    }
    return matches.count == 1 ? (matches[0], false) : nil
}

private func axWindows(in application: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows
}

private func isRestorableWindow(_ window: AXUIElement) -> Bool {
    guard let frame = axWindowFrame(window), frame.width > 0, frame.height > 0 else { return false }
    let subrole = axString(window, kAXSubroleAttribute as CFString) ?? ""
    guard subrole.isEmpty || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else {
        return false
    }
    var positionSettable = DarwinBoolean(false)
    var sizeSettable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success &&
        positionSettable.boolValue &&
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success &&
        sizeSettable.boolValue
}

private func axWindowFrame(_ window: AXUIElement) -> WindowSessionRect? {
    guard let point = axPoint(window, kAXPositionAttribute as CFString),
          let size = axSize(window, kAXSizeAttribute as CFString),
          size.width > 0, size.height > 0 else { return nil }
    return WindowSessionRect(x: point.x, y: point.y, width: size.width, height: size.height)
}

private func cgWindowSnapshots() -> [CGWindowSnapshot] {
    guard let raw = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return raw.compactMap { info in
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return CGWindowSnapshot(
            pid: pid,
            windowID: windowID,
            title: info[kCGWindowName as String] as? String,
            frame: WindowSessionRect(frame),
            isOnscreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
        )
    }
}

private func matchCGWindow(
    pid: Int32,
    frame: WindowSessionRect,
    title: String?,
    snapshots: [CGWindowSnapshot]
) -> CGWindowSnapshot? {
    let near = snapshots.filter { $0.pid == pid && $0.frame.isNear(frame, tolerance: 2) }
    if let title, !title.isEmpty {
        let titled = near.filter { $0.title == title }
        if titled.count == 1 { return titled[0] }
    }
    return near.count == 1 ? near[0] : nil
}

private func applyWindowFramePrecisely(_ window: AXUIElement, frame: WindowSessionRect) -> Bool {
    var point = CGPoint(x: frame.x, y: frame.y)
    var size = CGSize(width: frame.width, height: frame.height)
    guard let pointValue = AXValueCreate(.cgPoint, &point),
          let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

    let application = applicationElement(for: window)
    var restoreEnhancedUI = false
    if let application,
       axBool(application, "AXEnhancedUserInterface" as CFString) == true,
       setAXBool(application, attribute: "AXEnhancedUserInterface" as CFString, value: false) {
        restoreEnhancedUI = true
    }
    defer {
        if restoreEnhancedUI, let application {
            _ = setAXBool(application, attribute: "AXEnhancedUserInterface" as CFString, value: true)
        }
    }

    for _ in 0..<2 {
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        Thread.sleep(forTimeInterval: 0.012)
        if axWindowFrame(window)?.isNear(frame, tolerance: 2) == true { return true }
    }
    return false
}

private func applicationElement(for window: AXUIElement) -> AXUIElement? {
    var pid = pid_t()
    guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return nil }
    return AXUIElementCreateApplication(pid)
}

private func setAXBool(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success, settable.boolValue else {
        return false
    }
    return AXUIElementSetAttributeValue(element, attribute, value as CFBoolean) == .success
}

private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? Bool
}

private func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

private func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

private func contains(_ bounds: WindowSessionRect, _ point: CGPoint) -> Bool {
    point.x >= bounds.x && point.x < bounds.x + bounds.width &&
        point.y >= bounds.y && point.y < bounds.y + bounds.height
}

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
