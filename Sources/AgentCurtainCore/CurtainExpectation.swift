import Foundation

/// 「幕帘现在应该是拉上的」这个意图,落在磁盘上。
///
/// 为什么要单独存一份:app 自己知道 phase,但 app 不在了就没人知道了。
/// 2026-09-02 的两次掉线都不是进程崩溃 —— 一次是启用失败后没人再管,
/// 一次是部署动作把整套栈拆掉没装回去。两种情况下 app 都无法自我报告,
/// 所以判据必须留在 app 之外。
///
/// 只有**主动**拉开(off、热键、到点自动解除)才清除意图;app 崩溃、被卸载、
/// 被替换都不会,于是外部看护能把「你要求拉上、它却不在」认出来。
public struct CurtainExpectation: Sendable {
    private let url: URL

    public init(paths: CurtainPaths) {
        url = paths.expectation
    }

    public init(url: URL) {
        self.url = url
    }

    /// 记录意图。时间戳只用于告警文案,判据是文件在不在。
    public func record(at date: Date = Date()) throws {
        let formatter = ISO8601DateFormatter()
        try formatter.string(from: date).appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: url)
    }

    public var isRecorded: Bool { FileManager.default.fileExists(atPath: url.path) }

    public var recordedAt: Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
