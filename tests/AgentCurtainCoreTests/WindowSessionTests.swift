import XCTest
@testable import AgentCurtainCore

final class WindowSessionTests: XCTestCase {
    func testBackupStoreRoundTripsAtomicallyWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("window-session.json")
        let backup = WindowSessionBackup(
            ownerPID: 42,
            createdAt: Date(timeIntervalSince1970: 123.456),
            displays: [display(uuid: "external", x: -2560, y: -400, width: 2560, height: 1440)],
            windows: [window(windowID: 91, title: "Document", ordinal: 0)]
        )

        try WindowSessionBackupStore.write(backup, to: url)

        XCTAssertEqual(try WindowSessionBackupStore.read(from: url), backup)
        let mode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(mode & 0o777, 0o600)
        let claimed = try XCTUnwrap(WindowSessionBackupStore.claim(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try WindowSessionBackupStore.relinquish(claimed, to: url)
        XCTAssertEqual(try WindowSessionBackupStore.read(from: url), backup)
    }

    func testRelinquishNeverOverwritesANewerOriginalBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-session-relinquish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("window-session.json")
        let claimed = directory.appendingPathComponent("window-session.json.restoring.999999")
        let older = WindowSessionBackup(ownerPID: 1, displays: [], windows: [])
        let newer = WindowSessionBackup(ownerPID: 2, displays: [], windows: [])
        try WindowSessionBackupStore.write(older, to: claimed)
        try WindowSessionBackupStore.write(newer, to: original)

        XCTAssertThrowsError(try WindowSessionBackupStore.relinquish(claimed, to: original))
        XCTAssertEqual(try WindowSessionBackupStore.read(from: original).ownerPID, 2)
        XCTAssertEqual(try WindowSessionBackupStore.read(from: claimed).ownerPID, 1)
    }

    func testRecoverableClaimsExcludeLiveForeignRestorers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-session-claims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("window-session.json.restoring.\(getpid())")
        let dead = directory.appendingPathComponent("window-session.json.restoring.999999")
        let live = directory.appendingPathComponent("window-session.json.restoring.1")
        for file in [current, dead, live] { _ = FileManager.default.createFile(atPath: file.path, contents: Data()) }

        let names = Set(RecoveryClaimFiles.recoverable(
            in: directory,
            prefix: "window-session.json.restoring."
        ).map(\.lastPathComponent))

        XCTAssertTrue(names.contains(current.lastPathComponent))
        XCTAssertTrue(names.contains(dead.lastPathComponent))
        XCTAssertFalse(names.contains(live.lastPathComponent))
    }

    func testTargetFramePreservesExactNegativeCoordinatesWhenDisplayIsUnchanged() {
        let saved = window(
            frame: WindowSessionRect(x: -2390, y: -120, width: 1200, height: 900),
            display: WindowSessionRect(x: -2560, y: -400, width: 2560, height: 1440)
        )
        let target = display(uuid: "external", x: -2560, y: -400, width: 2560, height: 1440)

        XCTAssertEqual(WindowSessionPlanner.targetFrame(for: saved, on: target), saved.frame)
    }

    func testTargetFrameScalesRelativePlacementWhenDisplayResolutionChanges() {
        let saved = window(
            frame: WindowSessionRect(x: -1920, y: 100, width: 960, height: 540),
            display: WindowSessionRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        let target = display(uuid: "external", x: 1512, y: -200, width: 2560, height: 1440)

        XCTAssertEqual(
            WindowSessionPlanner.targetFrame(for: saved, on: target),
            WindowSessionRect(x: 1512, y: -67, width: 1280, height: 720)
        )
    }

    func testWindowIDWinsWhenTitlesAndOrderChange() {
        let saved = [
            window(windowID: 10, title: "old A", ordinal: 0),
            window(windowID: 20, title: "old B", ordinal: 1),
        ]
        let candidates = [
            WindowMatchCandidate(windowID: 20, identifier: nil, title: "new B", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0),
            WindowMatchCandidate(windowID: 10, identifier: nil, title: "new A", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertEqual(WindowSessionPlanner.matches(saved: saved, candidates: candidates), [0: 1, 1: 0])
    }

    func testIdentifierAndTitleMatchMultipleWindowsWithoutDependingOnApplicationNameAlone() {
        let saved = [
            window(windowID: nil, identifier: "editor-1", title: "same", ordinal: 0),
            window(windowID: nil, identifier: "editor-2", title: "same", ordinal: 1),
        ]
        let candidates = [
            WindowMatchCandidate(windowID: nil, identifier: "editor-2", title: "same", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0),
            WindowMatchCandidate(windowID: nil, identifier: "editor-1", title: "same", role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertEqual(WindowSessionPlanner.matches(saved: saved, candidates: candidates), [0: 1, 1: 0])
    }

    func testOrdinalFallbackRequiresSameWindowCount() {
        let saved = [window(windowID: nil, title: nil, ordinal: 0)]
        let sameCount = [
            WindowMatchCandidate(windowID: nil, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow", ordinal: 0),
        ]
        let extraWindow = sameCount + [
            WindowMatchCandidate(windowID: nil, identifier: nil, title: nil, role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertEqual(WindowSessionPlanner.matches(saved: saved, candidates: sameCount), [0: 0])
        XCTAssertTrue(WindowSessionPlanner.matches(saved: saved, candidates: extraWindow).isEmpty)
    }

    func testWindowIDIsIgnoredAfterApplicationProcessChanges() {
        let saved = [window(windowID: 10, title: "old title", ordinal: 0)]
        let reused = [
            WindowMatchCandidate(windowID: 10, identifier: nil, title: "different title",
                role: "AXWindow", subrole: "AXStandardWindow", ordinal: 1),
        ]

        XCTAssertTrue(WindowSessionPlanner.matches(
            saved: saved,
            candidates: reused,
            trustWindowIDs: false
        ).isEmpty)
    }

    func testWindowIDDoesNotOverrideIncompatibleWindowRole() {
        let saved = [window(windowID: 10, title: "Document", ordinal: 0)]
        let candidate = [
            WindowMatchCandidate(windowID: 10, identifier: nil, title: "Document",
                role: "AXSheet", subrole: "AXUnknown", ordinal: 0),
        ]

        XCTAssertTrue(WindowSessionPlanner.matches(saved: saved, candidates: candidate).isEmpty)
    }

    private func display(uuid: String, x: Double, y: Double, width: Double, height: Double) -> WindowDisplayGeometry {
        WindowDisplayGeometry(
            uuid: uuid,
            bounds: WindowSessionRect(x: x, y: y, width: width, height: height),
            isBuiltin: false
        )
    }

    private func window(
        windowID: UInt32? = 1,
        identifier: String? = nil,
        title: String? = "Document",
        ordinal: Int = 0,
        frame: WindowSessionRect = WindowSessionRect(x: -2400, y: -300, width: 1000, height: 700),
        display: WindowSessionRect = WindowSessionRect(x: -2560, y: -400, width: 2560, height: 1440)
    ) -> SavedWindow {
        SavedWindow(
            ownerPID: 100,
            bundleIdentifier: "example.app",
            applicationName: "Example",
            windowID: windowID,
            identifier: identifier,
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            ordinal: ordinal,
            displayUUID: "external",
            frame: frame,
            relativeFrame: WindowSessionPlanner.relativeFrame(frame, in: display)
        )
    }
}
