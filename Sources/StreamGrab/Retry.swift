import Foundation
import Network

/// When and how often a failed download is tried again on its own.
enum RetryPolicy {
    static let maxAttempts = 8
    /// Wait before automatic retry number 1, 2, 3…; the last value repeats.
    private static let delays: [TimeInterval] = [5, 15, 30, 60, 120, 300, 600]

    /// Problems that can go away by themselves: network trouble, timeouts, an overloaded server.
    /// Everything else (404, DRM, a live stream, a broken playlist, a full disk) fails for good.
    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? HTTPStatusError { return [408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524].contains(e.status) }
        if let e = error as? GrabError { return e.transient }
        if let e = error as? URLError {
            let transient: Set<URLError.Code> = [
                .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .badServerResponse,
                .cannotLoadFromNetwork, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
                .secureConnectionFailed, .zeroByteResource,
            ]
            return transient.contains(e.code)
        }
        return false
    }

    /// The wait before automatic retry number `attempt` (1-based), with ±20% jitter so
    /// several failed downloads don't all hit the server again at the same moment.
    static func delay(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let base = delays[min(max(attempt, 1), delays.count) - 1]
        let jittered = base * Double.random(in: 0.8 ... 1.2)
        return max(jittered, min(retryAfter ?? 0, 3600))
    }

    static func retryAfter(_ error: Error) -> TimeInterval? { (error as? HTTPStatusError)?.retryAfter }
}

/// Tells the download manager when the Mac gets back online, so waiting retries can go right away.
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasOnline = true

    init(onReconnect: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            if online && !self.wasOnline { onReconnect() }
            self.wasOnline = online
        }
        monitor.start(queue: DispatchQueue(label: "StreamGrab.network"))
    }
}
