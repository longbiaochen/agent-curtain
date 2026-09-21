import AgentCurtainCore
import Foundation

final class WindowSessionController {
    private let paths: CurtainPaths
    private(set) var lastCapturedCount = 0
    private(set) var lastRestoredCount = 0

    init(paths: CurtainPaths) {
        self.paths = paths
    }

    func capture() throws -> Int {
        try paths.prepareDirectories()
        guard !hasBackup else { throw WindowSessionControllerError.unrestoredBackup }
        let backup = try WindowSessionOperations.capture(
            ownerPID: getpid(),
            excludingBundleIdentifier: Bundle.main.bundleIdentifier
        )
        try WindowSessionBackupStore.write(backup, to: paths.windowSessionBackup)
        lastCapturedCount = backup.windows.count
        lastRestoredCount = 0
        return backup.windows.count
    }

    @discardableResult
    func restoreAllWindows() throws -> WindowRestorationReport? {
        let original = paths.windowSessionBackup
        var candidates: [URL] = []
        if let claimed = try WindowSessionBackupStore.claim(original) { candidates.append(claimed) }
        candidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "window-session.json.restoring."
        ))

        guard !candidates.isEmpty else { return nil }
        var combined: WindowRestorationReport?
        var firstError: Error?
        for claimed in RecoveryClaimFiles.unique(candidates) {
            do {
                let backup = try WindowSessionBackupStore.read(from: claimed)
                let report = try WindowSessionOperations.restore(backup)
                combined = WindowRestorationReport(
                    saved: (combined?.saved ?? 0) + report.saved,
                    restored: (combined?.restored ?? 0) + report.restored,
                    disappeared: (combined?.disappeared ?? 0) + report.disappeared
                )
                try FileManager.default.removeItem(at: claimed)
            } catch {
                firstError = firstError ?? error
                try? WindowSessionBackupStore.relinquish(claimed, to: original)
            }
        }
        if let firstError { throw firstError }
        lastRestoredCount = combined?.restored ?? 0
        return combined
    }

    func recoverStaleBackup() throws {
        guard hasBackup else { return }
        try restoreAllWindows()
    }

    var pendingRestoreCount: Int {
        guard let backup = try? WindowSessionBackupStore.read(from: paths.windowSessionBackup) else { return 0 }
        return backup.windows.count
    }

    private var hasBackup: Bool {
        if FileManager.default.fileExists(atPath: paths.windowSessionBackup.path) { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: paths.stateDirectory.path)) ?? []
        return contents.contains(where: { $0.hasPrefix("window-session.json.restoring.") })
    }
}

enum WindowSessionControllerError: Error, LocalizedError {
    case unrestoredBackup

    var errorDescription: String? {
        "an unrestored window session backup already exists"
    }
}
