import Darwin
import Foundation

/// 从一个已接受的连接里读出第一行命令。
///
/// 为什么单独抽出来:2026-09-06 `curtain status` 时好时坏,坏时回
/// `command is not UTF-8`。真正的原因是监听 fd 设了 O_NONBLOCK,而 macOS 上
/// `accept()` 出来的 fd **继承**这个标志;客户端的字节还没到,`recv` 就返回
/// EAGAIN,原来的循环把它当成 EOF,于是拿着一个空串去报「不是 UTF-8」。
/// 机器负载一高(当天 load 294),这个竞态几乎必输。
///
/// 这里把连接改回阻塞、加上接收超时,并把「空命令」和「不是 UTF-8」分开报。
public enum ControlLineReader {
    public enum Failure: Error, Equatable, LocalizedError {
        case empty
        case notUTF8
        case timedOut
        case tooLong

        public var errorDescription: String? {
            switch self {
            case .empty: return "empty command"
            case .notUTF8: return "command is not UTF-8"
            case .timedOut: return "timed out waiting for a command"
            case .tooLong: return "command is too long"
            }
        }
    }

    public static let maximumLength = 4096

    /// 读到第一个换行为止;`timeout` 是等待**每一段**数据的上限。
    public static func readLine(from fd: Int32, timeout: TimeInterval = 5) -> Result<String, Failure> {
        // 不管调用方给的 fd 是什么状态,这里一律按阻塞 + 超时来读。
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        var interval = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < maximumLength {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(buffer, count: count)
                if data.contains(0x0A) { break }
                continue
            }
            if count == 0 { break }                       // 对端关闭
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {  // 超时
                return data.isEmpty ? .failure(.timedOut) : .failure(.empty)
            }
            break                                         // 其它错误:按已读到的处理
        }
        if data.count >= maximumLength, !data.contains(0x0A) { return .failure(.tooLong) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        guard let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.empty)
        }
        return .success(String(line))
    }
}
