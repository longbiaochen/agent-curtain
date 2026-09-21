import CoreGraphics
import Darwin
import Foundation

public struct SystemDisplayConnectionBackend: DisplayConnectionBackend {
    public typealias ConfigureDisplayEnabled = @convention(c) (
        CGDisplayConfigRef?, CGDirectDisplayID, Bool
    ) -> CGError

    public let kind: DisplayConnectionBackendKind = .systemSPI
    private let client: BetterDisplayClient
    private let configureDisplayEnabled: ConfigureDisplayEnabled
    private let activeDisplayIDs: @Sendable () throws -> [Int]

    private static let resolvedConfigureDisplayEnabled: ConfigureDisplayEnabled? = {
        #if arch(arm64)
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureDisplayEnabled.self)
        #else
        return nil
        #endif
    }()

    public static var isAvailable: Bool {
        #if arch(arm64)
        return resolveConfigureDisplayEnabled() != nil
        #else
        return false
        #endif
    }

    public static var availabilityStatus: String {
        #if arch(arm64)
        return isAvailable ? "available" : "missing"
        #else
        return "unsupported-architecture"
        #endif
    }

    public init(client: BetterDisplayClient) throws {
        guard let function = Self.resolveConfigureDisplayEnabled() else {
            throw DisplayConnectionBackendError.unavailableForRestore(.systemSPI)
        }
        self.client = client
        configureDisplayEnabled = function
        activeDisplayIDs = BetterDisplayClient.defaultActiveDisplayProvider
    }

    init(
        client: BetterDisplayClient,
        configureDisplayEnabled: @escaping ConfigureDisplayEnabled,
        activeDisplayIDs: @escaping @Sendable () throws -> [Int]
    ) {
        self.client = client
        self.configureDisplayEnabled = configureDisplayEnabled
        self.activeDisplayIDs = activeDisplayIDs
    }

    public func disconnect(
        displays: [DisplayTopology],
        backup: DisplaySessionBackup,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let refreshed = DisplaySessionOperations.refreshDisplayIDs(
            in: backup,
            identities: try client.displays()
        )
        let targetUUIDs = Set(displays.filter { !$0.isBuiltin }.map(\.uuid))
        let external = refreshed.displays.filter { targetUUIDs.contains($0.uuid) }
        guard !external.isEmpty else { return }
        if isCancelled() { throw CancellationError() }

        do {
            var active = Set(try activeDisplayIDs())
            var targets = external
            if let builtin = refreshed.builtin, !active.contains(builtin.displayID) {
                try reconnectDisplays(backup: refreshed)
                active = Set(try activeDisplayIDs())
                targets = refreshed.displays.filter { !$0.isBuiltin }
            }
            try configure(targets.filter { active.contains($0.displayID) }.map { ($0, false) })
            if isCancelled() { throw CancellationError() }
            let expected = Set(refreshed.displays.filter(\.isBuiltin).map(\.displayID))
            try waitForActiveDisplayIDs(expected, exact: true)
        } catch {
            try? reconnectDisplays(backup: refreshed)
            throw error
        }
    }

    public func reconnectDisplays(backup: DisplaySessionBackup) throws {
        let backup = DisplaySessionOperations.refreshDisplayIDs(
            in: backup,
            identities: try client.displays()
        )
        do {
            var active = Set(try activeDisplayIDs())
            if let builtin = backup.builtin, !active.contains(builtin.displayID),
               let bridge = backup.displays.first(where: { !$0.isBuiltin && !active.contains($0.displayID) }) {
                try configure([(bridge, true)])
                try waitForActiveDisplayIDs([builtin.displayID], exact: false, timeout: 4)
                active = Set(try activeDisplayIDs())
            }
            let missing = backup.displays.filter { !active.contains($0.displayID) }
            try configure(missing.map { ($0, true) })
            let expected = Set(backup.displays.map(\.displayID))
            do {
                try waitForActiveDisplayIDs(expected, exact: false, timeout: 2)
            } catch {
                do {
                    try retryMissingDisplaysIndividually(backup: backup, expected: expected, timeout: 12)
                } catch {
                    let identities = try client.displays()
                    let currentIDs = Dictionary(uniqueKeysWithValues: identities.compactMap { identity in
                        identity.uuid.map { ($0, identity.displayID) }
                    })
                    let remapped = backup.displays.compactMap { saved -> DisplayTopology? in
                        guard let current = currentIDs[saved.uuid], current != saved.displayID else { return nil }
                        return DisplayTopology(
                            uuid: saved.uuid,
                            displayID: current,
                            isBuiltin: saved.isBuiltin,
                            wasMain: saved.wasMain,
                            placement: saved.placement,
                            resolution: saved.resolution,
                            rotation: saved.rotation
                        )
                    }
                    let nowActive = Set(try activeDisplayIDs())
                    let stillMissing = remapped.filter { !nowActive.contains($0.displayID) }
                    for display in stillMissing {
                        try configure([(display, true)])
                        usleep(250_000)
                    }
                    _ = try client.waitForActiveDisplays(
                        uuids: Set(backup.displays.map(\.uuid)), exact: false
                    )
                }
            }
        } catch {
            if (try? client.proAvailable()) == true {
                try client.connectAllDisplays()
                let expected = Dictionary(uniqueKeysWithValues: backup.displays.map { ($0.uuid, true) })
                try client.waitForConnectionStates(expected)
                return
            }
            throw error
        }
    }

    private func configure(_ changes: [(DisplayTopology, Bool)]) throws {
        guard !changes.isEmpty else { return }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            throw DisplayConnectionBackendError.configuration("begin returned \(begin.rawValue)")
        }
        var completed = false
        defer {
            if !completed { CGCancelDisplayConfiguration(configuration) }
        }
        for (display, enabled) in changes {
            let result = configureDisplayEnabled(configuration, CGDirectDisplayID(display.displayID), enabled)
            guard result == .success else {
                throw DisplayConnectionBackendError.configuration(
                    "CGSConfigureDisplayEnabled(displayID=\(display.displayID), enabled=\(enabled)) returned \(result.rawValue)"
                )
            }
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard complete == .success else {
            throw DisplayConnectionBackendError.configuration("complete returned \(complete.rawValue)")
        }
        completed = true
    }

    private func retryMissingDisplaysIndividually(
        backup: DisplaySessionBackup,
        expected: Set<Int>,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var actual: Set<Int> = []
        repeat {
            actual = Set(try activeDisplayIDs())
            if expected.isSubset(of: actual) { return }
            for display in backup.displays where !actual.contains(display.displayID) {
                try configure([(display, true)])
                usleep(250_000)
                actual = Set(try activeDisplayIDs())
                if expected.isSubset(of: actual) { return }
            }
        } while Date() < deadline
        throw DisplayConnectionBackendError.verification(
            expected: expected.sorted(), actual: actual.sorted()
        )
    }

    private func waitForActiveDisplayIDs(
        _ expected: Set<Int>,
        exact: Bool,
        timeout: TimeInterval = 15
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var actual: Set<Int> = []
        repeat {
            actual = Set(try activeDisplayIDs())
            if exact ? actual == expected : expected.isSubset(of: actual) { return }
            usleep(250_000)
        } while Date() < deadline
        throw DisplayConnectionBackendError.verification(
            expected: expected.sorted(), actual: actual.sorted()
        )
    }

    private static func resolveConfigureDisplayEnabled() -> ConfigureDisplayEnabled? {
        resolvedConfigureDisplayEnabled
    }
}
