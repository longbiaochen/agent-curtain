import Foundation

public enum DisplayConnectionBackendKind: String, Codable, Sendable {
    case systemSPI = "system-spi"
    case betterDisplay = "betterdisplay"
}

public protocol DisplayConnectionBackend: Sendable {
    var kind: DisplayConnectionBackendKind { get }

    func disconnect(
        displays: [DisplayTopology],
        backup: DisplaySessionBackup,
        isCancelled: @Sendable () -> Bool
    ) throws

    func reconnectDisplays(backup: DisplaySessionBackup) throws
}

public enum DisplayConnectionBackendError: Error, LocalizedError {
    case unavailable
    case unavailableForRestore(DisplayConnectionBackendKind)
    case configuration(String)
    case verification(expected: [Int], actual: [Int])

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "no display connection backend is available (private display SPI missing and BetterDisplay Pro unavailable)"
        case .unavailableForRestore(let kind):
            return "saved display connection backend is unavailable: \(kind.rawValue)"
        case .configuration(let message):
            return "display configuration failed: \(message)"
        case .verification(let expected, let actual):
            return "display topology did not settle; expected display IDs \(expected), active display IDs \(actual)"
        }
    }
}

public enum DisplayConnectionBackendFactory {
    /// Selection order is intentional: use the local system transaction first and
    /// consult BetterDisplay Pro only if that SPI cannot be loaded.
    public static func select(client: BetterDisplayClient) throws -> any DisplayConnectionBackend {
        if SystemDisplayConnectionBackend.isAvailable {
            return try SystemDisplayConnectionBackend(client: client)
        }
        if try client.proAvailable() {
            return BetterDisplayConnectionBackend(client: client)
        }
        throw DisplayConnectionBackendError.unavailable
    }

    public static func restoreBackend(
        for backup: DisplaySessionBackup,
        client: BetterDisplayClient
    ) throws -> any DisplayConnectionBackend {
        switch backup.connectionBackend ?? .betterDisplay {
        case .systemSPI:
            if SystemDisplayConnectionBackend.isAvailable {
                return try SystemDisplayConnectionBackend(client: client)
            }
            // A Pro connection operation is a recovery-only escape hatch if an OS
            // update removes the SPI after a system-SPI session was recorded.
            if try client.proAvailable() {
                return BetterDisplayConnectionBackend(client: client)
            }
            throw DisplayConnectionBackendError.unavailableForRestore(.systemSPI)
        case .betterDisplay:
            guard try client.proAvailable() else {
                throw DisplayConnectionBackendError.unavailableForRestore(.betterDisplay)
            }
            return BetterDisplayConnectionBackend(client: client)
        }
    }

    public static var preferredKindWithoutProbingBetterDisplay: DisplayConnectionBackendKind? {
        SystemDisplayConnectionBackend.isAvailable ? .systemSPI : nil
    }
}
