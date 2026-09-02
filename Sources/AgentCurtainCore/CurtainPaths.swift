import Foundation

public struct CurtainPaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var configDirectory: URL { home.appendingPathComponent(".config/curtain", isDirectory: true) }
    public var stateDirectory: URL { home.appendingPathComponent(".local/state/curtain", isDirectory: true) }
    public var allowlist: URL { configDirectory.appendingPathComponent("allowlist") }
    public var denylist: URL { configDirectory.appendingPathComponent("denylist") }
    public var controlSocket: URL { stateDirectory.appendingPathComponent("control.sock") }
    public var brightnessBackup: URL { stateDirectory.appendingPathComponent("brightness.json") }

    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }
}
