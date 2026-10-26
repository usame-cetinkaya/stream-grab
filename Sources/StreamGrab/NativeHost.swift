import Foundation

/// When Chrome starts us as a native-messaging host (argv[1] = "chrome-extension://…/"),
/// we answer the extension over stdin/stdout without showing any UI:
///  - "ping":     is the app running? is ffmpeg available? (never launches the app)
///  - "probe":    fetch an HLS playlist or DASH manifest with the page's headers and list its qualities
///  - "download": hand a job to the app (launching it if needed)
enum NativeHost {
    static func isHostLaunch(_ args: [String]) -> Bool {
        args.dropFirst().contains { $0.hasPrefix("chrome-extension://") }
    }

    static func run() -> Never {
        let input = FileHandle.standardInput
        while let lenData = try? input.read(upToCount: 4), lenData.count == 4 {
            let len = lenData.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            guard len > 0, len < 64 << 20, let body = try? input.read(upToCount: len), body.count == len,
                  let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { break }
            reply(handleSync(msg))
        }
        exit(0)
    }

    private static func reply(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var len = UInt32(data.count)
        let out = FileHandle.standardOutput
        out.write(Data(bytes: &len, count: 4))
        out.write(data)
    }

    private static func handleSync(_ msg: [String: Any]) -> [String: Any] {
        let sema = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            box.value = await handle(msg)
            sema.signal()
        }
        sema.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable { var value: [String: Any] = [:] }

    private static func handle(_ msg: [String: Any]) async -> [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        switch msg["type"] as? String {
        case "ping":
            return ["ok": true, "version": version, "ffmpeg": Paths.ffmpeg != nil,
                    "appRunning": IPC.send(["type": "ping"]) != nil]
        case "probe":
            guard let s = msg["url"] as? String, let url = URL(string: s) else { return ["ok": false, "error": "Bad URL"] }
            do {
                return try await probe(url, headers: msg["headers"] as? [String: String] ?? [:])
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        case "download", "show":
            return forwardToApp(msg)
        default:
            return ["ok": false, "error": "Unknown request"]
        }
    }

    private static func probe(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        let fetcher = Fetcher(headers: headers)
        defer { fetcher.invalidate() }
        let (text, base) = try await fetcher.text(url)
        if DASH.isManifest(text) { return try probeDASH(text, base: base, url: url) }
        guard text.hasPrefix("#EXTM3U") || text.contains("#EXTINF") || text.contains("#EXT-X-STREAM-INF") else {
            throw GrabError("Not an HLS playlist or DASH manifest")
        }
        if HLS.isMaster(text) {
            let variants = HLS.parseMaster(text, base: base)
            var prefixes = Set(variants.flatMap { [$0.url] + ($0.audioURL.map { [$0] } ?? []) }.map(directory))
            var result: [String: Any] = [
                "ok": true, "kind": "master",
                "variants": variants.map { v -> [String: Any] in
                    var d: [String: Any] = ["url": v.url, "bandwidth": v.bandwidth]
                    if let h = v.height { d["height"] = h }
                    if let w = v.width { d["width"] = w }
                    if let f = v.frameRate { d["frameRate"] = f }
                    if let a = v.audioURL { d["audioUrl"] = a }
                    return d
                },
            ]
            // Duration (for size estimates), live and DRM status come from one media playlist.
            if let first = variants.last.flatMap({ URL(string: $0.url) }),
               let (t, b) = try? await fetcher.text(first) {
                let media = HLS.parseMedia(t, base: b)
                result["duration"] = media.duration
                result["live"] = media.isLive
                result["drm"] = media.drm || text.contains("SESSION-KEY") && text.contains("KEYFORMAT=\"com.")
                prefixes.formUnion(media.segments.prefix(1).map { directory($0.url.absoluteString) })
            }
            result["prefixes"] = Array(prefixes)
            return result
        }
        let media = HLS.parseMedia(text, base: base)
        return ["ok": true, "kind": "media", "duration": media.duration, "live": media.isLive, "drm": media.drm,
                "prefixes": Array(Set(([url.absoluteString] + media.segments.prefix(1).map { $0.url.absoluteString }).map(directory)))]
    }

    private static func probeDASH(_ text: String, base: URL, url: URL) throws -> [String: Any] {
        let mpd = try DASH.parse(text, base: base)
        let qualities = mpd.videoQualities
        guard !qualities.isEmpty else { throw GrabError("No video in the manifest") }
        return [
            "ok": true, "kind": "dash", "duration": mpd.duration, "live": mpd.isLive, "drm": mpd.drm,
            "prefixes": Array(Set(mpd.tracks.flatMap(\.prefixes))),
            "variants": qualities.map { v -> [String: Any] in
                let audio = mpd.audio(for: v)
                var d: [String: Any] = ["url": url.absoluteString, "bandwidth": v.bandwidth + (audio?.bandwidth ?? 0), "videoId": v.id]
                if let h = v.height { d["height"] = h }
                if let w = v.width { d["width"] = w }
                if let f = v.frameRate { d["frameRate"] = f }
                if let a = audio { d["audioId"] = a.id }
                return d
            },
        ]
    }

    /// "https://cdn/x/y/seg1.ts?token" -> "https://cdn/x/y/"
    private static func directory(_ s: String) -> String {
        guard let u = URL(string: s) else { return s }
        var c = URLComponents(url: u.deletingLastPathComponent(), resolvingAgainstBaseURL: true)
        c?.query = nil
        return c?.string ?? s
    }

    private static func forwardToApp(_ msg: [String: Any]) -> [String: Any] {
        if let r = IPC.send(msg) { return r }
        // App isn't running: launch it in the background and wait for its socket.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", Bundle.main.bundleURL.path]
        try? open.run()
        open.waitUntilExit()
        for _ in 0 ..< 75 {
            usleep(200_000)
            if let r = IPC.send(msg) { return r }
        }
        return ["ok": false, "error": "Couldn't start the StreamGrab app."]
    }
}
