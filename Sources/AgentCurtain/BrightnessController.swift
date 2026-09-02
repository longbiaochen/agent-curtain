import AgentCurtainCore
import Darwin
import Foundation

final class BrightnessController {
    private let paths: CurtainPaths
    private var watchdog: Process?

    init(paths: CurtainPaths) {
        self.paths = paths
    }

    func dimAllDisplays() throws -> Int {
        try paths.prepareDirectories()
        guard !FileManager.default.fileExists(atPath: paths.brightnessBackup.path) else {
            throw BrightnessControllerError.unrestoredBackup
        }

        let client = try BetterDisplayClient()
        let ids = try client.displayIDs()
        let displays = try ids.map { id in
            DisplayBrightness(displayID: id, brightness: try client.brightness(displayID: id))
        }
        let backup = BrightnessBackup(ownerPID: getpid(), displays: displays)
        try BrightnessBackupStore.write(backup, to: paths.brightnessBackup)

        do {
            try startWatchdog(betterDisplay: client.executable)
            for display in displays {
                try client.setBrightness(displayID: display.displayID, value: 0)
                let readback = try client.brightness(displayID: display.displayID)
                guard readback <= 0.01 else {
                    throw BrightnessControllerError.dimReadback(display.displayID, readback)
                }
            }
            return displays.count
        } catch {
            try? restoreAllDisplays()
            throw error
        }
    }

    func restoreAllDisplays() throws {
        let client = try BetterDisplayClient()
        let original = paths.brightnessBackup
        var candidates: [URL] = []
        if let claimed = try BrightnessBackupStore.claim(original) {
            candidates.append(claimed)
        }
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: paths.stateDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        candidates.append(contentsOf: existing.filter { $0.lastPathComponent.hasPrefix("brightness.json.restoring.") })

        var firstError: Error?
        for claimed in Array(Set(candidates)) {
            do {
                let backup = try BrightnessBackupStore.read(from: claimed)
                for display in backup.displays {
                    try client.setBrightness(displayID: display.displayID, value: display.brightness)
                }
                try FileManager.default.removeItem(at: claimed)
            } catch {
                firstError = firstError ?? error
                try? BrightnessBackupStore.relinquish(claimed, to: original)
            }
        }
        if let firstError { throw firstError }
        watchdog?.terminate()
        watchdog = nil
    }

    func dimNewDisplays() throws -> Int {
        let original = paths.brightnessBackup
        guard FileManager.default.fileExists(atPath: original.path) else {
            throw BrightnessControllerError.unrestoredBackup
        }
        let client = try BetterDisplayClient()
        let existing = try BrightnessBackupStore.read(from: original)
        let knownIDs = Set(existing.displays.map(\.displayID))
        let activeIDs = try client.displayIDs()
        let newDisplays = try activeIDs.filter { !knownIDs.contains($0) }.map { id in
            DisplayBrightness(displayID: id, brightness: try client.brightness(displayID: id))
        }
        guard !newDisplays.isEmpty else { return activeIDs.count }

        let updated = BrightnessBackup(
            ownerPID: existing.ownerPID,
            createdAt: existing.createdAt,
            displays: existing.displays + newDisplays
        )
        try BrightnessBackupStore.write(updated, to: original)
        do {
            for display in newDisplays {
                try client.setBrightness(displayID: display.displayID, value: 0)
                let readback = try client.brightness(displayID: display.displayID)
                guard readback <= 0.01 else {
                    throw BrightnessControllerError.dimReadback(display.displayID, readback)
                }
            }
            return activeIDs.count
        } catch {
            for display in newDisplays {
                try? client.setBrightness(displayID: display.displayID, value: display.brightness)
            }
            try? BrightnessBackupStore.write(existing, to: original)
            throw error
        }
    }

    func recoverStaleBackup() throws {
        guard FileManager.default.fileExists(atPath: paths.brightnessBackup.path) || hasOrphanedClaim else { return }
        try restoreAllDisplays()
    }

    private var hasOrphanedClaim: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: paths.stateDirectory.path)) ?? []
        return contents.contains(where: { $0.hasPrefix("brightness.json.restoring.") })
    }

    private func startWatchdog(betterDisplay: URL) throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AgentCurtainRestoreWatchdog")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BrightnessControllerError.watchdogMissing
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(getpid()), paths.brightnessBackup.path, betterDisplay.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        usleep(150_000)
        guard process.isRunning else { throw BrightnessControllerError.watchdogFailed }
        watchdog = process
    }
}

enum BrightnessControllerError: Error, LocalizedError {
    case unrestoredBackup
    case dimReadback(Int, Double)
    case watchdogMissing
    case watchdogFailed

    var errorDescription: String? {
        switch self {
        case .unrestoredBackup: return "an unrestored brightness backup already exists"
        case .dimReadback(let id, let value): return "displayID=\(id) remained at brightness \(value)"
        case .watchdogMissing: return "the embedded brightness recovery watchdog is missing"
        case .watchdogFailed: return "the brightness recovery watchdog failed to start"
        }
    }
}
