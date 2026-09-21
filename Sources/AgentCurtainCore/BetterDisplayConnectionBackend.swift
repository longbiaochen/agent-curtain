import Foundation

public struct BetterDisplayConnectionBackend: DisplayConnectionBackend {
    public let kind: DisplayConnectionBackendKind = .betterDisplay
    private let client: BetterDisplayClient

    public init(client: BetterDisplayClient) {
        self.client = client
    }

    public func disconnect(
        displays: [DisplayTopology],
        backup: DisplaySessionBackup,
        isCancelled: @Sendable () -> Bool
    ) throws {
        guard try client.proAvailable() else { throw BetterDisplayError.proRequired }
        let external = displays.filter { !$0.isBuiltin }
        guard !external.isEmpty else { return }
        if isCancelled() { throw CancellationError() }

        do {
            let allExternal = Set(backup.displays.filter { !$0.isBuiltin }.map(\.uuid))
            if Set(external.map(\.uuid)) == allExternal {
                try client.disconnectAllButMain()
            } else {
                for display in external {
                    if isCancelled() { throw CancellationError() }
                    try client.setFeature("connected", value: "off", uuid: display.uuid)
                }
            }
            if isCancelled() { throw CancellationError() }

            let expected = Dictionary(uniqueKeysWithValues: external.map { ($0.uuid, false) })
            try client.waitForConnectionStates(expected)
        } catch {
            try? reconnectDisplays(backup: backup)
            throw error
        }
    }

    public func reconnectDisplays(backup: DisplaySessionBackup) throws {
        guard try client.proAvailable() else { throw BetterDisplayError.proRequired }
        try client.connectAllDisplays()
        let expected = Dictionary(uniqueKeysWithValues: backup.displays.map { ($0.uuid, true) })
        try client.waitForConnectionStates(expected)
    }
}
