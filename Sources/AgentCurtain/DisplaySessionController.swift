import AgentCurtainCore
import Darwin
import Foundation

final class DisplaySessionController {
    private let paths: CurtainPaths
    private(set) var lastBackendKind: DisplayConnectionBackendKind?
    private(set) var betterDisplayProStatus = "unknown"

    init(paths: CurtainPaths) {
        self.paths = paths
    }

    func capture() throws -> Int {
        try paths.prepareDirectories()
        guard !hasBackup else { throw DisplaySessionControllerError.unrestoredBackup }
        let client = try BetterDisplayClient()
        let backend = try DisplayConnectionBackendFactory.select(client: client)
        let backup = try DisplaySessionOperations.capture(
            ownerPID: getpid(),
            client: client,
            connectionBackend: backend.kind
        )
        try DisplaySessionBackupStore.write(backup, to: paths.displaySessionBackup)
        lastBackendKind = backend.kind
        return backup.displays.count
    }

    func disconnectExternalDisplays(isCancelled: @Sendable () -> Bool = { false }) throws -> Int {
        let client = try BetterDisplayClient()
        let saved = try DisplaySessionBackupStore.read(from: paths.displaySessionBackup)
        let backup = DisplaySessionOperations.refreshDisplayIDs(
            in: saved,
            identities: try client.displays()
        )
        if backup != saved {
            try DisplaySessionBackupStore.write(backup, to: paths.displaySessionBackup)
        }
        let backend = try DisplayConnectionBackendFactory.restoreBackend(for: backup, client: client)
        lastBackendKind = backup.connectionBackend ?? backend.kind
        return try DisplaySessionOperations.disconnectExternalDisplays(
            backup: backup,
            client: client,
            backend: backend,
            isCancelled: isCancelled
        )
    }

    func reconcileNewDisplays() throws -> Int {
        guard FileManager.default.fileExists(atPath: paths.displaySessionBackup.path) else {
            throw DisplaySessionControllerError.unrestoredBackup
        }
        let client = try BetterDisplayClient()
        let existing = try DisplaySessionBackupStore.read(from: paths.displaySessionBackup)
        let updated = try DisplaySessionOperations.mergeNewActiveDisplays(into: existing, client: client)
        if updated != existing {
            try DisplaySessionBackupStore.write(updated, to: paths.displaySessionBackup)
        }
        let activeExternal = try DisplaySessionOperations.activeExternalDisplays(
            in: updated,
            client: client
        )
        guard !activeExternal.isEmpty else { return updated.displays.count }
        let backend = try DisplayConnectionBackendFactory.restoreBackend(for: updated, client: client)
        lastBackendKind = updated.connectionBackend ?? backend.kind
        try DisplaySessionOperations.disconnectDisplays(
            activeExternal,
            backup: updated,
            client: client,
            backend: backend
        )
        return updated.displays.count
    }

    func restoreAllDisplays() throws {
        let original = paths.displaySessionBackup
        var candidates: [URL] = []
        if let claimed = try DisplaySessionBackupStore.claim(original) { candidates.append(claimed) }
        candidates.append(contentsOf: RecoveryClaimFiles.recoverable(
            in: paths.stateDirectory,
            prefix: "display-session.json.restoring."
        ))

        guard !candidates.isEmpty else { return }
        var firstError: Error?
        for claimed in RecoveryClaimFiles.unique(candidates) {
            do {
                let client = try BetterDisplayClient()
                let saved = try DisplaySessionBackupStore.read(from: claimed)
                let backup = DisplaySessionOperations.refreshDisplayIDs(
                    in: saved,
                    identities: try client.displays()
                )
                if backup != saved {
                    try DisplaySessionBackupStore.write(backup, to: claimed)
                }
                let backend = try DisplayConnectionBackendFactory.restoreBackend(for: backup, client: client)
                lastBackendKind = backup.connectionBackend ?? backend.kind
                try DisplaySessionOperations.restore(backup, client: client, backend: backend)
                try FileManager.default.removeItem(at: claimed)
            } catch {
                firstError = firstError ?? error
                try? DisplaySessionBackupStore.relinquish(claimed, to: original)
            }
        }
        if let firstError { throw firstError }
    }

    func recoverStaleBackup() throws {
        guard hasBackup else { return }
        try restoreAllDisplays()
    }

    func currentActiveDisplayCount() throws -> Int {
        try BetterDisplayClient().activeDisplays().count
    }

    func refreshBackendDiagnostics() {
        guard let client = try? BetterDisplayClient() else {
            betterDisplayProStatus = "unknown"
            return
        }
        do {
            betterDisplayProStatus = try client.proAvailable() ? "on" : "off"
        } catch {
            betterDisplayProStatus = "unknown"
        }
    }

    var pendingRestoreCount: Int {
        guard let backup = try? DisplaySessionBackupStore.read(from: paths.displaySessionBackup) else { return 0 }
        return backup.displays.filter { !$0.isBuiltin }.count
    }

    var privateDisplaySPIStatus: String {
        SystemDisplayConnectionBackend.availabilityStatus
    }

    var displayBackendStatus: String? {
        if let lastBackendKind { return lastBackendKind.rawValue }
        if let saved = try? DisplaySessionBackupStore.read(from: paths.displaySessionBackup) {
            return saved.connectionBackend?.rawValue ?? DisplayConnectionBackendKind.betterDisplay.rawValue
        }
        return DisplayConnectionBackendFactory.preferredKindWithoutProbingBetterDisplay?.rawValue
    }

    private var hasBackup: Bool {
        if FileManager.default.fileExists(atPath: paths.displaySessionBackup.path) { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: paths.stateDirectory.path)) ?? []
        return contents.contains(where: { $0.hasPrefix("display-session.json.restoring.") })
    }
}

enum DisplaySessionControllerError: Error, LocalizedError {
    case unrestoredBackup

    var errorDescription: String? {
        switch self {
        case .unrestoredBackup: return "an unrestored display session backup already exists"
        }
    }
}
