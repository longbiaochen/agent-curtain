import CoreGraphics
import Foundation
import Testing
@testable import AgentCurtainCore

@Suite(.serialized) struct DisplaySessionTests {
    @Test func backupRoundTripsWithSecurePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("display-session.json")
        let backup = DisplaySessionBackup(ownerPID: 42, connectionBackend: .systemSPI, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0")
        ])
        try DisplaySessionBackupStore.write(backup, to: url)
        #expect(try DisplaySessionBackupStore.read(from: url) == backup)
        #expect(backup.version == 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func captureDoesNotRequireBetterDisplayPro() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli")
        try #"""
        #!/bin/sh
        case "$*" in
          'get --identifiers') echo '[{"displayID":1,"UUID":"internal"}]' ;;
          'get -UUID=internal -main') echo true ;;
          'get -UUID=internal -placement') echo 0x0 ;;
          'get -UUID=internal -resolution') echo 1512x982 ;;
          'get -UUID=internal -rotation') echo 0 ;;
          'get -proAvailable') exit 71 ;;
        esac
        """#.write(
            to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let client = try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [1] }, builtinDisplayProvider: { $0 == 1 })
        let backup = try DisplaySessionOperations.capture(
            ownerPID: 1, client: client, connectionBackend: .systemSPI
        )
        #expect(backup.connectionBackend == .systemSPI)
        #expect(backup.displays.map(\.uuid) == ["internal"])
    }

    @Test func disconnectsToBuiltinAndRestoresOriginalMainByUUID() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        let backend = BetterDisplayConnectionBackend(client: client)
        let backup = try DisplaySessionOperations.capture(
            ownerPID: 7, client: client, connectionBackend: .betterDisplay
        )

        #expect(backup.displays.count == 2)
        #expect(backup.builtin?.uuid == "internal")
        #expect(backup.displays.first(where: \.wasMain)?.uuid == "external")

        #expect(try DisplaySessionOperations.disconnectExternalDisplays(
            backup: backup, client: client, backend: backend
        ) == 2)
        #expect(try String(contentsOf: fixture.state, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "internal")

        try DisplaySessionOperations.restore(backup, client: client, backend: backend)
        #expect(try String(contentsOf: fixture.state, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "all")
        #expect(try String(contentsOf: fixture.main, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "external")

        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(log.components(separatedBy: "set -disconnectAllButMain").count - 1 == 1)
        #expect(log.components(separatedBy: "set -connectAllDisplays").count - 1 == 1)
        #expect(log.contains("set -UUID=internal -main=on"))
        #expect(log.contains("set -UUID=external -main=on"))
        #expect(!log.contains("-displayID="))
    }

    @Test func legacyV1BackupDecodesWithoutBackend() throws {
        let data = Data(#"{"createdAt":1772000000000,"displays":[],"ownerPID":42,"version":1}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let backup = try decoder.decode(DisplaySessionBackup.self, from: data)
        #expect(backup.version == 1)
        #expect(backup.connectionBackend == nil)
    }

    @Test func systemSPIUsesOneConfigurationForAllExternalDisplays() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        SystemSPICallRecorder.calls = []
        SystemSPICallRecorder.activeSnapshots = [[1, 22, 23], [1]]
        let backend = SystemDisplayConnectionBackend(
            client: client,
            configureDisplayEnabled: { configuration, displayID, enabled in
                SystemSPICallRecorder.calls.append((configuration, displayID, enabled))
                return .success
            },
            activeDisplayIDs: { SystemSPICallRecorder.nextActiveSnapshot() }
        )
        let backup = DisplaySessionBackup(ownerPID: 7, connectionBackend: .systemSPI, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0"),
            DisplayTopology(uuid: "external-a", displayID: 22, isBuiltin: false, wasMain: false,
                placement: "1512x0", resolution: "2560x1440", rotation: "0"),
            DisplayTopology(uuid: "external-b", displayID: 23, isBuiltin: false, wasMain: false,
                placement: "4072x0", resolution: "1920x1080", rotation: "0")
        ])

        try backend.disconnect(
            displays: backup.displays.filter { !$0.isBuiltin },
            backup: backup,
            isCancelled: { false }
        )

        #expect(SystemSPICallRecorder.calls.map { Int($0.1) } == [22, 23])
        #expect(SystemSPICallRecorder.calls.allSatisfy { !$0.2 })
        #expect(Set(SystemSPICallRecorder.calls.compactMap { $0.0 }).count == 1)
    }

    @Test func systemSPIRestoreSkipsAlreadyActiveDisplays() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        SystemSPICallRecorder.calls = []
        let backend = SystemDisplayConnectionBackend(
            client: try fixture.client(),
            configureDisplayEnabled: { configuration, displayID, enabled in
                SystemSPICallRecorder.calls.append((configuration, displayID, enabled))
                return .success
            },
            activeDisplayIDs: { [1, 22] }
        )
        let backup = try DisplaySessionOperations.capture(
            ownerPID: 7,
            client: fixture.client(),
            connectionBackend: .systemSPI
        )
        try backend.reconnectDisplays(backup: backup)
        #expect(SystemSPICallRecorder.calls.isEmpty)
    }

    @Test func systemSPIRestoreBridgesFromExternalOnlyTopology() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        SystemSPICallRecorder.calls = []
        SystemSPICallRecorder.activeSnapshots = [
            [2], [1, 2, 3], [1, 2, 3], [1, 2, 3, 4]
        ]
        let backend = SystemDisplayConnectionBackend(
            client: try fixture.client(),
            configureDisplayEnabled: { configuration, displayID, enabled in
                SystemSPICallRecorder.calls.append((configuration, displayID, enabled))
                return .success
            },
            activeDisplayIDs: { SystemSPICallRecorder.nextActiveSnapshot() }
        )
        let backup = DisplaySessionBackup(ownerPID: 7, connectionBackend: .systemSPI, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0"),
            DisplayTopology(uuid: "external-a", displayID: 2, isBuiltin: false, wasMain: false,
                placement: "1512x0", resolution: "2560x1440", rotation: "0"),
            DisplayTopology(uuid: "external-b", displayID: 3, isBuiltin: false, wasMain: false,
                placement: "4072x0", resolution: "1920x1080", rotation: "0"),
            DisplayTopology(uuid: "external-c", displayID: 4, isBuiltin: false, wasMain: false,
                placement: "-1920x0", resolution: "1920x1080", rotation: "0")
        ])
        try backend.reconnectDisplays(backup: backup)
        #expect(SystemSPICallRecorder.calls.map { Int($0.1) } == [3, 4])
        #expect(SystemSPICallRecorder.calls.allSatisfy { $0.2 })
    }

    @Test func backendSelectionPrefersSystemSPIWithoutProProbe() throws {
        #expect(SystemDisplayConnectionBackend.isAvailable)
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let backend = try DisplayConnectionBackendFactory.select(client: fixture.client())
        #expect(backend.kind == .systemSPI)
        let log = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
        #expect(!log.contains("get -proAvailable"))
    }

    @Test func reappearingKnownExternalDisplayIsSelectedForLocalDisconnect() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        let backup = try DisplaySessionOperations.capture(
            ownerPID: 7, client: client, connectionBackend: .systemSPI
        )
        try "internal\n".write(to: fixture.state, atomically: true, encoding: .utf8)
        #expect(try DisplaySessionOperations.activeExternalDisplays(in: backup, client: client).isEmpty)
        try "all\n".write(to: fixture.state, atomically: true, encoding: .utf8)
        #expect(try DisplaySessionOperations.activeExternalDisplays(in: backup, client: client).map(\.uuid) == ["external"])
    }

    @Test func knownDisplayUUIDRefreshesChangedDisplayIDBeforeDisconnect() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        let client = try fixture.client()
        let backup = try DisplaySessionOperations.capture(
            ownerPID: 7, client: client, connectionBackend: .systemSPI
        )

        try "remapped\n".write(to: fixture.state, atomically: true, encoding: .utf8)
        let updated = try DisplaySessionOperations.mergeNewActiveDisplays(into: backup, client: client)

        #expect(updated.displays.count == backup.displays.count)
        #expect(updated.displays.first(where: { $0.uuid == "external" })?.displayID == 2)
        #expect(try DisplaySessionOperations.activeExternalDisplays(in: updated, client: client)
            .map(\.displayID) == [2])
    }

    @Test func systemSPIRemapsDisplayIDBeforeFirstRestoreWrite() throws {
        let fixture = try DisplayFixture()
        defer { fixture.remove() }
        try "remapped\n".write(to: fixture.state, atomically: true, encoding: .utf8)
        SystemSPICallRecorder.calls = []
        SystemSPICallRecorder.activeSnapshots = [[1], [1, 2]]
        let backend = SystemDisplayConnectionBackend(
            client: try fixture.client(),
            configureDisplayEnabled: { configuration, displayID, enabled in
                SystemSPICallRecorder.calls.append((configuration, displayID, enabled))
                return .success
            },
            activeDisplayIDs: { SystemSPICallRecorder.nextActiveSnapshot() }
        )
        let stale = DisplaySessionBackup(ownerPID: 7, connectionBackend: .systemSPI, displays: [
            DisplayTopology(uuid: "internal", displayID: 1, isBuiltin: true, wasMain: true,
                placement: "0x0", resolution: "1512x982", rotation: "0"),
            DisplayTopology(uuid: "external", displayID: 22, isBuiltin: false, wasMain: false,
                placement: "1512x0", resolution: "2560x1440", rotation: "0")
        ])

        try backend.reconnectDisplays(backup: stale)

        #expect(SystemSPICallRecorder.calls.map { Int($0.1) } == [2])
        #expect(SystemSPICallRecorder.calls.allSatisfy { $0.2 })
    }
}

private enum SystemSPICallRecorder {
    nonisolated(unsafe) static var calls: [(CGDisplayConfigRef?, CGDirectDisplayID, Bool)] = []
    nonisolated(unsafe) static var activeSnapshots: [[Int]] = []

    static func nextActiveSnapshot() -> [Int] {
        activeSnapshots.count > 1 ? activeSnapshots.removeFirst() : (activeSnapshots.first ?? [])
    }
}

private final class DisplayFixture: @unchecked Sendable {
    let root: URL
    let cli: URL
    let state: URL
    let main: URL
    let log: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cli = root.appendingPathComponent("cli")
        state = root.appendingPathComponent("state")
        main = root.appendingPathComponent("main")
        log = root.appendingPathComponent("log")
        try "all\n".write(to: state, atomically: true, encoding: .utf8)
        try "external\n".write(to: main, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        root=${0%/*}
        printf '%s\n' "$*" >> "$root/log"
        state=$(cat "$root/state")
        main=$(cat "$root/main")
        case "$*" in
          'get --identifiers')
            if [ "$state" = all ]; then
              echo '[{"displayID":1,"UUID":"internal"},{"displayID":22,"UUID":"external"}]'
            else
              echo '[{"displayID":1,"UUID":"internal"},{"displayID":2,"UUID":"external"}]'
            fi ;;
          'get -proAvailable') echo on ;;
          'get -UUID=internal -main') [ "$main" = internal ] && echo true || echo false ;;
          'get -UUID=external -main') [ "$main" = external ] && echo true || echo false ;;
          'get -UUID=internal -placement') echo 0x0 ;;
          'get -UUID=external -placement') echo 1512x0 ;;
          'get -UUID=internal -resolution') echo 1512x982 ;;
          'get -UUID=external -resolution') echo 2560x1440 ;;
          'get -UUID=internal -rotation'|'get -UUID=external -rotation') echo 0 ;;
          'get -UUID=internal -connected') echo on ;;
          'get -UUID=external -connected') [ "$state" = all ] && echo on || echo off ;;
          'set -UUID=internal -main=on') echo internal > "$root/main" ;;
          'set -UUID=external -main=on') echo external > "$root/main" ;;
          'set -disconnectAllButMain') echo internal > "$root/state" ;;
          'set -connectAllDisplays') echo all > "$root/state" ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

    func client() throws -> BetterDisplayClient {
        try BetterDisplayClient(executable: cli, application: nil,
            activeDisplayProvider: { [weak self] in
                guard let self else { return [] }
                let value = try String(contentsOf: self.state, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "all" { return [1, 22] }
                if value == "remapped" { return [1, 2] }
                return [1]
            },
            builtinDisplayProvider: { $0 == 1 })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
