import Foundation
import Testing
@testable import AgentCurtainCore

@Test func controlProtocolParsesCompatibleCommands() throws {
    #expect(try ControlCommand.parse("on") == .draw(duration: nil, allowAnyInjected: false))
    #expect(try ControlCommand.parse("on 60 --allow-any-injected") == .draw(duration: 60, allowAnyInjected: true))
    #expect(try ControlCommand.parse("off") == .open)
    #expect(try ControlCommand.parse("status") == .status)
    #expect(try ControlCommand.parse("quit") == .quit)
    #expect(throws: ControlProtocolError.self) { try ControlCommand.parse("on -1") }
    #expect(throws: ControlProtocolError.self) { try ControlCommand.parse("off now") }
}

@Test func denyAlwaysWinsAndPhysicalInputIsAlwaysBlocked() {
    let allowed: Set<Int32> = [42, 43]
    let denied: Set<Int32> = [43, 44]
    #expect(!InputDecision.shouldAllow(pid: 0, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: true))
    #expect(InputDecision.shouldAllow(pid: 42, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: false))
    #expect(!InputDecision.shouldAllow(pid: 43, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: true))
    #expect(InputDecision.shouldAllow(pid: 45, allowedPIDs: allowed, deniedPIDs: denied, allowAnyInjected: true))
}

@Test func processNamesMatchExactlyRatherThanBySubstring() {
    let rule = ProcessRule("UURemoteServer")
    #expect(rule.matches(path: "/Applications/UURemote.app/Contents/Helpers/UURemoteServer"))
    #expect(!rule.matches(path: "/tmp/UURemoteServer-helper"))
}

@Test func configurationCreatesSecureDefaultDenylist() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = CurtainPaths(home: root)
    let config = try CurtainConfiguration.load(from: paths)
    #expect(config.deniedRules == CurtainConfiguration.defaultDeniedRules)
    let attrs = try FileManager.default.attributesOfItem(atPath: paths.denylist.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func brightnessBackupRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("brightness.json")
    let backup = BrightnessBackup(ownerPID: 123, displays: [DisplayBrightness(displayID: 7, brightness: 0.75)])
    try BrightnessBackupStore.write(backup, to: url)
    #expect(try BrightnessBackupStore.read(from: url) == backup)
    let claimedURL = try BrightnessBackupStore.claim(url)
    let claimed = try #require(claimedURL)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try BrightnessBackupStore.relinquish(claimed, to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}
