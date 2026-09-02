import Foundation

public struct CurtainConfiguration: Equatable, Sendable {
    public static let defaultDeniedRules = [
        "/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app",
        "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app",
        "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice",
    ]

    public let allowedRules: [String]
    public let deniedRules: [String]

    public init(allowedRules: [String], deniedRules: [String]) {
        self.allowedRules = allowedRules
        self.deniedRules = deniedRules
    }

    public static func load(from paths: CurtainPaths) throws -> CurtainConfiguration {
        try paths.prepareDirectories()
        if !FileManager.default.fileExists(atPath: paths.allowlist.path) {
            try writeRules([], to: paths.allowlist)
        }
        if !FileManager.default.fileExists(atPath: paths.denylist.path) {
            try writeRules(defaultDeniedRules, to: paths.denylist)
        }
        return CurtainConfiguration(
            allowedRules: try parseRules(at: paths.allowlist),
            deniedRules: try parseRules(at: paths.denylist)
        )
    }

    public static func parseRules(at url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func writeRules(_ rules: [String], to url: URL) throws {
        let header = "# One executable path or exact process name per line.\n"
        let body = rules.isEmpty ? "" : rules.joined(separator: "\n") + "\n"
        try (header + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
