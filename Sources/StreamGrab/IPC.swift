import Darwin
import Foundation

/// Paths and constants shared by the app and the native-messaging host.
enum Paths {
    static let hostName = "com.streamgrab.host"
    static let extensionID = "ljopggppagmplkghfflbeopnlacihime"

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamGrab", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var work: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamGrab", isDirectory: true)
    }

    static var socket: String { support.appendingPathComponent("ipc.sock").path }
    static var installedExtension: URL { support.appendingPathComponent("Chrome Extension", isDirectory: true) }

    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// One JSON line in, one JSON line out, over a Unix socket that only this user can open.
enum IPC {
    typealias Handler = @Sendable ([String: Any]) -> [String: Any]

    static func serve(_ handler: @escaping Handler) {
        let path = Paths.socket
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, bind(fd, path) == 0, listen(fd, 16) == 0 else {
            NSLog("StreamGrab: can't listen on \(path): \(String(cString: strerror(errno)))")
            return
        }
        chmod(path, 0o600)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global().async {
                    defer { close(client) }
                    guard let line = readLine(client),
                          let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    writeLine(client, handler(obj))
                }
            }
        }
    }

    /// Sends a request to the running app. Returns nil when nothing is listening.
    static func send(_ message: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, Paths.socket) == 0 else { return nil }
        writeLine(fd, message)
        guard let line = readLine(fd) else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func bind(_ fd: Int32, _ path: String) -> Int32 { withAddress(path) { Darwin.bind(fd, $0, $1) } }
    private static func connect(_ fd: Int32, _ path: String) -> Int32 { withAddress(path) { Darwin.connect(fd, $0, $1) } }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            if let nl = buf[0 ..< n].firstIndex(of: 10) {
                data.append(contentsOf: buf[0 ..< nl])
                return data
            }
            data.append(contentsOf: buf[0 ..< n])
        }
    }

    private static func writeLine(_ fd: Int32, _ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(10)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}
