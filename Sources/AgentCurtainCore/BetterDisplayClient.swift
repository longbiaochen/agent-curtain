import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum CommandRunner {
    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 15) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw BetterDisplayError.commandTimedOut
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, stdout: output, stderr: error)
    }
}

public enum BetterDisplayError: Error, LocalizedError {
    case executableNotFound
    case commandFailed(String)
    case commandTimedOut
    case invalidDisplayList
    case invalidBrightness(Int)
    case appNotRunning(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "betterdisplaycli was not found"
        case .commandFailed(let message): return "betterdisplaycli failed: \(message)"
        case .commandTimedOut: return "betterdisplaycli timed out"
        case .invalidDisplayList: return "betterdisplaycli returned no display IDs"
        case .invalidBrightness(let id): return "invalid brightness for displayID=\(id)"
        case .appNotRunning(let app):
            return "BetterDisplay.app is not running (\(app)); betterdisplaycli answers nothing without it"
        }
    }
}

public struct BetterDisplayClient: Sendable {
    public let executable: URL
    /// betterdisplaycli 只是个前端,BetterDisplay.app 不在时它什么都不回、
    /// 退出码还是 0。2026-09-06 早上机器重启后 app 没跟着起来,`curtain on`
    /// 就一直死在「没有显示器」上。所以拿不到显示器列表时,先把 app 拉起来再试。
    public let application: URL?
    /// 拉起 app 后最多等这么久让 CLI 通起来。
    public let launchWait: TimeInterval
    /// 真正把 app 拉起来的动作。默认 `open -gj`;测试里换成空操作,免得真去开东西。
    public let launcher: @Sendable (URL) -> Void

    public static let defaultLauncher: @Sendable (URL) -> Void = { application in
        _ = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-gj", application.path], timeout: 10)
    }

    public init(executable: URL? = nil, application: URL? = URL(fileURLWithPath: "/Applications/BetterDisplay.app"),
                launchWait: TimeInterval = 10, launcher: @escaping @Sendable (URL) -> Void = BetterDisplayClient.defaultLauncher) throws {
        self.application = application
        self.launchWait = launchWait
        self.launcher = launcher
        if let executable {
            self.executable = executable
            return
        }
        let candidates = [
            "/opt/homebrew/bin/betterdisplaycli",
            "/usr/local/bin/betterdisplaycli",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BetterDisplayError.executableNotFound
        }
        self.executable = URL(fileURLWithPath: path)
    }

    public func displayIDs() throws -> [Int] {
        var result = try checked(["get", "--identifiers"])
        if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = try displayIDsAfterLaunchingApp()
        }
        let data = Data(result.stdout.utf8)
        let object: Any
        if let direct = try? JSONSerialization.jsonObject(with: data) {
            object = direct
        } else {
            let wrapped = Data(("[" + result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + "]").utf8)
            guard let parsed = try? JSONSerialization.jsonObject(with: wrapped) else {
                throw BetterDisplayError.invalidDisplayList
            }
            object = parsed
        }

        let dictionaries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let dictionary = object as? [String: Any] {
            dictionaries = [dictionary]
        } else {
            throw BetterDisplayError.invalidDisplayList
        }
        let ids = dictionaries.compactMap { item -> Int? in
            if let number = item["displayID"] as? NSNumber { return number.intValue }
            if let string = item["displayID"] as? String { return Int(string) }
            return nil
        }
        guard !ids.isEmpty else { throw BetterDisplayError.invalidDisplayList }
        return Array(Set(ids)).sorted()
    }

    public func brightness(displayID: Int) throws -> Double {
        let result = try checked(["get", "-displayID=\(displayID)", "-brightness"])
        guard let value = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw BetterDisplayError.invalidBrightness(displayID)
        }
        return value
    }

    public func setBrightness(displayID: Int, value: Double) throws {
        _ = try checked(["set", "-displayID=\(displayID)", "-brightness=\(value)"])
    }

    /// CLI 空回答 = app 不在。装了就 `open -gj` 拉起来,轮询到它开口为止。
    private func displayIDsAfterLaunchingApp() throws -> CommandResult {
        guard let application, FileManager.default.fileExists(atPath: application.path) else {
            throw BetterDisplayError.appNotRunning(application?.path ?? "not installed")
        }
        launcher(application)
        let deadline = Date().addingTimeInterval(launchWait)
        while Date() < deadline {
            usleep(500_000)
            let retry = try checked(["get", "--identifiers"])
            if !retry.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return retry }
        }
        throw BetterDisplayError.appNotRunning(application.path)
    }

    private func checked(_ arguments: [String]) throws -> CommandResult {
        let result = try CommandRunner.run(executable, arguments: arguments)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BetterDisplayError.commandFailed(message.isEmpty ? "exit \(result.status)" : message)
        }
        return result
    }
}
