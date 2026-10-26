import Foundation

/// URLSession wrapper that replays the browser's request headers (Referer, Cookie, User-Agent…)
/// and downloads pieces straight to disk while counting bytes for the speed display.
final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let headers: [String: String]
    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    private var received: Int64 = 0

    /// Called as a download proceeds with (bytes written so far, bytes expected or -1).
    typealias Progress = @Sendable (Int64, Int64) -> Void

    private final class Waiter {
        let destination: URL
        let expectsRange: Bool
        let continuation: CheckedContinuation<Int64, Error>
        let progress: Progress?
        var result: Result<Int64, Error>?
        init(_ destination: URL, _ expectsRange: Bool, _ continuation: CheckedContinuation<Int64, Error>, _ progress: Progress?) {
            self.destination = destination; self.expectsRange = expectsRange; self.continuation = continuation
            self.progress = progress
        }
    }

    /// Headers that must not be replayed: URLSession manages them, or they'd break ranged requests.
    private static let skipped: Set<String> = [
        "range", "host", "content-length", "accept-encoding", "connection", "if-range",
        "if-none-match", "if-modified-since", "upgrade-insecure-requests", "priority",
    ]

    init(headers: [String: String], connections: Int = Engine.maxConnections) {
        self.headers = headers.filter { k, _ in
            let k = k.lowercased()
            return !Self.skipped.contains(k) && !k.hasPrefix("sec-") && !k.hasPrefix(":")
        }
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false // the Cookie header comes from the browser
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpMaximumConnectionsPerHost = max(connections, 2)
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    func invalidate() { session.invalidateAndCancel() }

    /// Bytes received since the last call (for speed measurement).
    func takeReceivedBytes() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let n = received
        received = 0
        return n
    }

    func request(_ url: URL, range: ClosedRange<Int64>? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let r = range { req.setValue("bytes=\(r.lowerBound)-\(r.upperBound)", forHTTPHeaderField: "Range") }
        return req
    }

    /// Small resources: playlists and keys.
    func data(_ url: URL, range: ClosedRange<Int64>? = nil) async throws -> Data {
        if url.scheme == "data" { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(for: request(url, range: range))
        try Self.check(response, url: url)
        return data
    }

    func text(_ url: URL) async throws -> (String, URL) {
        let (data, response) = try await session.data(for: request(url))
        try Self.check(response, url: url)
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw GrabError("Playlist isn't text.")
        }
        // Use the final URL after redirects to resolve relative segment paths.
        return (s, response.url ?? url)
    }

    /// Reads only the response headers of a GET.
    func head(_ url: URL, range: ClosedRange<Int64>? = nil) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request(url, range: range))
        bytes.task.cancel()
        try Self.check(response, url: url)
        guard let http = response as? HTTPURLResponse else { throw GrabError("Not an HTTP response.") }
        return http
    }

    /// Downloads to `destination`, replacing it. Returns the number of bytes written.
    @discardableResult
    func download(_ url: URL, range: ClosedRange<Int64>? = nil, to destination: URL, progress: Progress? = nil) async throws -> Int64 {
        let task = session.downloadTask(with: request(url, range: range))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                waiters[task.taskIdentifier] = Waiter(destination, range != nil, cont, progress)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func check(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) else { return }
        throw HTTPStatusError(status: http.statusCode,
                              retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(HTTPStatusError.parseRetryAfter),
                              name: url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        received += bytesWritten
        let progress = waiters[downloadTask.taskIdentifier]?.progress
        lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let w = waiters[downloadTask.taskIdentifier]; lock.unlock()
        guard let w else { return }
        do {
            if let r = downloadTask.response { try Self.check(r, url: downloadTask.originalRequest?.url ?? location) }
            if w.expectsRange, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 {
                throw GrabError("The server ignored a byte-range request.")
            }
            let fm = FileManager.default
            try? fm.removeItem(at: w.destination)
            try fm.moveItem(at: location, to: w.destination)
            let size = (try? fm.attributesOfItem(atPath: w.destination.path))?[.size] as? NSNumber
            w.result = .success(size?.int64Value ?? 0)
        } catch {
            w.result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let w = waiters.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let w else { return }
        if let error { w.continuation.resume(throwing: error) }
        else { w.continuation.resume(with: w.result ?? .failure(GrabError("Download finished without data."))) }
    }
}

struct HTTPStatusError: LocalizedError {
    let status: Int
    /// From the Retry-After header: how long the server wants us to wait.
    let retryAfter: TimeInterval?
    let name: String

    var errorDescription: String? {
        status == 429 ? "The server kept refusing with “Too many requests” (HTTP 429) for \(name), even over one connection."
            : "Server answered HTTP \(status) for \(name)."
    }

    /// Retry-After is either a number of seconds or an HTTP date.
    static func parseRetryAfter(_ value: String) -> TimeInterval? {
        if let s = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
