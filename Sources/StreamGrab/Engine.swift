import Foundation

/// What the browser extension (or the "Add URL" field) asks us to download.
struct Job: Codable, Hashable {
    enum Kind: String, Codable { case hls, dash, direct }
    var kind: Kind
    var url: String
    /// Separate audio: an HLS audio playlist, or an audio file to merge with a direct video file.
    var audioURL: String?
    /// DASH: the chosen representations (best available when missing).
    var videoID: String?
    var audioID: String?
    var title: String
    var quality: String?
    var pageURL: String?
    var headers: [String: String] = [:]

    init(kind: Kind, url: String, title: String) {
        self.kind = kind; self.url = url; self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        audioURL = try c.decodeIfPresent(String.self, forKey: .audioURL)
        videoID = try c.decodeIfPresent(String.self, forKey: .videoID)
        audioID = try c.decodeIfPresent(String.self, forKey: .audioID)
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
        pageURL = try c.decodeIfPresent(String.self, forKey: .pageURL)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }

    /// Whether this download has to merge a separate audio track (which needs ffmpeg).
    var mayNeedMerge: Bool { audioURL != nil || kind == .dash }
}

/// Downloads one job into a work folder, piece by piece, then merges it into the final file.
/// Finished pieces stay on disk, so a paused or interrupted download resumes where it left off.
final class Engine: @unchecked Sendable {
    enum Phase: String { case preparing, downloading, merging }

    struct Snapshot {
        var phase: Phase = .preparing
        var piecesDone = 0
        var piecesTotal = 0
        var bytesDone: Int64 = 0
        var totalBytes: Int64?   // exact for direct downloads, estimated for streams
        var bytesPerSecond: Double = 0
        var map: PieceMap?
        var connections = 1
        /// The server answered HTTP 429 and the connection count was lowered.
        var rateLimited = false
    }

    static let maxConnections = 16

    /// The file laid out as pieces, for the progress bar: finished runs and the pieces
    /// each connection is fetching right now (positions are fractions of the whole file).
    struct PieceMap: Equatable {
        struct Run: Equatable {
            var start: Double
            var length: Double
            var fill: Double     // 1 for finished pieces, 0..<1 for a piece being downloaded
            var active: Bool
        }
        var runs: [Run] = []
    }

    /// Per-piece state behind `PieceMap`.
    private struct PieceState {
        var group: Character         // "v"ideo, "a"udio, "d"irect, "x" separate audio
        var known: Int64?            // exact size once finished (or from its byte range)
        var done = false
        var got: Int64 = 0           // while downloading
        var expected: Int64?
    }

    struct Output {
        var file: URL
        /// Something the user should know, e.g. audio saved separately because ffmpeg is missing.
        var note: String?
    }

    private struct Piece {
        var name: String
        var url: URL
        var range: ClosedRange<Int64>?
        var key: HLS.Key?
    }

    static let noFFmpegNote = "Sound was saved as a separate file because ffmpeg isn't installed. Run “brew install ffmpeg” to get one file with sound."

    let job: Job
    let workDir: URL
    private var limit: Int          // connections allowed right now; changes with 429s and the user's − / +
    private var rateLimited = false
    /// Bumped whenever `limit` changes. A 429 only lowers the limit if its request was sent
    /// under the current limit; requests sent in the same overloaded burst don't count again.
    private var epoch = 0
    private let fetcher: Fetcher
    private let lock = NSLock()
    private var snap = Snapshot()
    private var keys: [URL: Data] = [:]
    private var lastSample = Date()
    private var pieceStates: [PieceState] = []

    init(job: Job, workDir: URL, connections: Int) {
        self.job = job
        self.workDir = workDir
        limit = min(max(1, connections), Self.maxConnections)
        fetcher = Fetcher(headers: job.headers)
    }

    deinit { fetcher.invalidate() }

    func snapshot() -> Snapshot {
        let now = Date()
        let bytes = fetcher.takeReceivedBytes()
        lock.lock(); defer { lock.unlock() }
        let dt = now.timeIntervalSince(lastSample)
        lastSample = now
        if dt > 0 {
            let instant = Double(bytes) / dt
            snap.bytesPerSecond = snap.bytesPerSecond == 0 ? instant : snap.bytesPerSecond * 0.6 + instant * 0.4
        }
        var s = snap
        if !pieceStates.isEmpty { s.map = buildMap() }
        s.connections = limit
        s.rateLimited = rateLimited
        return s
    }

    /// Sizes of pieces not downloaded yet are estimated from finished pieces of the same track.
    private func buildMap() -> PieceMap {
        var sums: [Character: (Int64, Int)] = [:]
        for p in pieceStates { if let k = p.known { sums[p.group, default: (0, 0)].0 += k; sums[p.group, default: (0, 0)].1 += 1 } }
        let overall = sums.values.reduce((Int64(0), 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        func weight(_ p: PieceState) -> Double {
            if let k = p.known { return Double(max(k, 1)) }
            if let e = p.expected, e > 0 { return Double(e) }
            if let (sum, n) = sums[p.group], n > 0 { return Double(sum) / Double(n) }
            return overall.1 > 0 ? Double(overall.0) / Double(overall.1) : 1
        }
        let weights = pieceStates.map(weight)
        let total = weights.reduce(0, +)
        guard total > 0 else { return PieceMap() }
        var map = PieceMap()
        var x = 0.0
        for (p, w) in zip(pieceStates, weights) {
            let len = w / total
            if p.done {
                // Merge neighbouring finished pieces into one run.
                if let last = map.runs.last, !last.active, abs(last.start + last.length - x) < 1e-9 {
                    map.runs[map.runs.count - 1].length += len
                } else {
                    map.runs.append(.init(start: x, length: len, fill: 1, active: false))
                }
            } else if p.got > 0 || p.expected != nil {
                let fill = p.expected.map { $0 > 0 ? min(1, Double(p.got) / Double($0)) : 0 } ?? 0
                map.runs.append(.init(start: x, length: len, fill: fill, active: true))
            }
            x += len
        }
        return map
    }

    /// The user's − / + on a download. Takes effect for the next pieces (running ones finish first).
    func setConnections(_ n: Int) {
        withLock {
            limit = min(max(1, n), Self.maxConnections)
            rateLimited = false
            epoch += 1
        }
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); change(&snap); lock.unlock()
    }

    /// Runs the whole download and returns the finished file in `destination`.
    func run(destination: URL, ffmpeg: URL?) async throws -> Output {
        try Task.checkCancellation() // cancelled before it began: don't create a folder
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        switch job.kind {
        case .direct: return try await runDirect(destination: destination, ffmpeg: ffmpeg)
        case .hls: return try await runHLS(destination: destination, ffmpeg: ffmpeg)
        case .dash: return try await runDASH(destination: destination, ffmpeg: ffmpeg)
        }
    }

    // MARK: - Direct files (multi-connection, like IDM)

    private func runDirect(destination: URL, ffmpeg: URL?) async throws -> Output {
        guard let url = URL(string: job.url) else { throw GrabError("Invalid URL.") }
        let (videoPieces, videoTotal, videoMIME) = try await filePieces(url, prefix: "d")
        var audioPieces: [Piece] = []
        var audioTotal: Int64? = 0
        var audioMIME: String?
        if let a = job.audioURL.flatMap(URL.init(string:)) {
            (audioPieces, audioTotal, audioMIME) = try await filePieces(a, prefix: "x")
        }
        update { $0.totalBytes = videoTotal.flatMap { v in audioTotal.map { v + $0 } } }

        try await fetchAll(videoPieces + audioPieces)
        update { $0.phase = .merging }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 4 { ext = Self.fileExtension(forMIME: videoMIME) ?? "mp4" }
        let videoFile = workDir.appendingPathComponent("video.\(ext)")
        try concatenate(videoPieces.map(\.name), into: videoFile)
        guard !audioPieces.isEmpty else {
            return Output(file: try moveToDestination(videoFile, folder: destination, ext: ext))
        }
        var aExt = job.audioURL.flatMap(URL.init(string:))?.pathExtension.lowercased() ?? ""
        if aExt.isEmpty || aExt.count > 4 { aExt = Self.fileExtension(forMIME: audioMIME) ?? "m4a" }
        let audioFile = workDir.appendingPathComponent("audio.\(aExt)")
        try concatenate(audioPieces.map(\.name), into: audioFile)
        // A file that already has its own sound keeps it; the separate track was a wrong guess.
        if let ffmpeg, Self.hasAudioStream(videoFile, ffmpeg: ffmpeg) {
            return Output(file: try moveToDestination(videoFile, folder: destination, ext: ext))
        }
        return try await finish(video: videoFile, audio: audioFile, rawExt: ext, destination: destination, ffmpeg: ffmpeg)
    }

    /// A whole file as ranged pieces (or one piece when the server can't do ranges).
    private func filePieces(_ url: URL, prefix: String) async throws -> ([Piece], Int64?, String?) {
        let probe = try await fetcher.head(url, range: 0 ... 0)
        if probe.statusCode == 206, let cr = probe.value(forHTTPHeaderField: "Content-Range"),
           let size = cr.split(separator: "/").last.flatMap({ Int64($0) }), size > 0 {
            let chunk = max(4 << 20, size / 2000)
            var pieces: [Piece] = []
            var start: Int64 = 0
            while start < size {
                let end = min(start + chunk, size) - 1
                pieces.append(Piece(name: String(format: "\(prefix)%06d", pieces.count), url: url, range: start ... end))
                start = end + 1
            }
            return (pieces, size, probe.mimeType)
        }
        // No range support: one connection, restarts from zero after a pause.
        let total = probe.expectedContentLength > 0 ? probe.expectedContentLength : nil
        return ([Piece(name: "\(prefix)000000", url: url)], total, probe.mimeType)
    }

    // MARK: - HLS

    private func runHLS(destination: URL, ffmpeg: URL?) async throws -> Output {
        guard let url = URL(string: job.url) else { throw GrabError("Invalid URL.") }
        var (text, base) = try await fetcher.text(url)
        var audioURL = job.audioURL.flatMap(URL.init(string:))
        if HLS.isMaster(text) {
            // Given a master playlist (e.g. pasted by hand): take the best quality.
            guard let best = HLS.parseMaster(text, base: base).first, let u = URL(string: best.url) else {
                throw GrabError("The playlist has no playable variants.")
            }
            audioURL = audioURL ?? best.audioURL.flatMap(URL.init(string:))
            (text, base) = try await fetcher.text(u)
        }
        let video = HLS.parseMedia(text, base: base)
        var audio: HLS.MediaPlaylist?
        if let audioURL {
            let (t, b) = try await fetcher.text(audioURL)
            audio = HLS.parseMedia(t, base: b)
        }
        if video.drm || audio?.drm == true {
            throw GrabError("This video is DRM-protected, so it can't be downloaded.")
        }
        if video.isLive { throw GrabError("This is a live stream. Only on-demand videos can be downloaded.") }
        if video.segments.isEmpty { throw GrabError("The playlist has no segments.") }

        func pieces(_ p: HLS.MediaPlaylist, prefix: String) -> [Piece] {
            var list: [Piece] = []
            if let i = p.initSegment { list.append(Piece(name: "\(prefix)init", url: i.url, range: i.range)) }
            for (n, s) in p.segments.enumerated() {
                list.append(Piece(name: String(format: "\(prefix)%06d", n), url: s.url, range: s.range, key: s.key))
            }
            return list
        }
        let videoPieces = pieces(video, prefix: "v")
        let audioPieces = audio.map { pieces($0, prefix: "a") } ?? []

        try await fetchAll(videoPieces + audioPieces)
        update { $0.phase = .merging }

        let vExt = video.isFragmentedMP4 ? "mp4" : "ts"
        let videoFile = workDir.appendingPathComponent("video.\(vExt)")
        try concatenate(videoPieces.map(\.name), into: videoFile)
        var audioFile: URL?
        if let audio {
            let aExt = audio.isFragmentedMP4 ? "m4a" : (audio.segments.first?.url.pathExtension.lowercased() == "aac" ? "aac" : "ts")
            audioFile = workDir.appendingPathComponent("audio.\(aExt)")
            try concatenate(audioPieces.map(\.name), into: audioFile!)
        }
        return try await finish(video: videoFile, audio: audioFile, rawExt: vExt, destination: destination, ffmpeg: ffmpeg)
    }

    // MARK: - DASH

    private func runDASH(destination: URL, ffmpeg: URL?) async throws -> Output {
        guard let url = URL(string: job.url) else { throw GrabError("Invalid URL.") }
        let (text, base) = try await fetcher.text(url)
        let mpd = try DASH.parse(text, base: base)
        if mpd.drm { throw GrabError("This video is DRM-protected, so it can't be downloaded.") }
        if mpd.isLive { throw GrabError("This is a live stream. Only on-demand videos can be downloaded.") }
        guard let video = mpd.videos.first(where: { $0.id == job.videoID }) ?? mpd.videoQualities.first else {
            throw GrabError("The manifest has no video.")
        }
        let audio = job.audioID.flatMap { id in mpd.audios.first { $0.id == id } } ?? mpd.audio(for: video)

        func pieces(_ t: DASH.Track, prefix: String) async throws -> [Piece] {
            if let file = t.file { return try await filePieces(file, prefix: prefix).0 }
            var list: [Piece] = []
            if let i = t.initSegment { list.append(Piece(name: "\(prefix)init", url: i.url, range: i.range)) }
            for (n, s) in t.segments.enumerated() {
                list.append(Piece(name: String(format: "\(prefix)%06d", n), url: s.url, range: s.range))
            }
            return list
        }
        let videoPieces = try await pieces(video, prefix: "v")
        var audioPieces: [Piece] = []
        if let audio { audioPieces = try await pieces(audio, prefix: "a") }

        try await fetchAll(videoPieces + audioPieces)
        update { $0.phase = .merging }

        let vExt = video.isWebM ? "webm" : "mp4"
        let videoFile = workDir.appendingPathComponent("video.\(vExt)")
        try concatenate(videoPieces.map(\.name), into: videoFile)
        var audioFile: URL?
        if let audio {
            audioFile = workDir.appendingPathComponent("audio.\(audio.isWebM ? "webm" : "m4a")")
            try concatenate(audioPieces.map(\.name), into: audioFile!)
        }
        return try await finish(video: videoFile, audio: audioFile, rawExt: vExt, destination: destination, ffmpeg: ffmpeg)
    }

    // MARK: - Merging

    /// Remuxes video (+ separate audio) into one file. Without ffmpeg, keeps the raw files and says so.
    private func finish(video: URL, audio: URL?, rawExt: String, destination: URL, ffmpeg: URL?) async throws -> Output {
        if let ffmpeg {
            for ext in ["mp4", "mkv"] {
                let out = workDir.appendingPathComponent("final.\(ext)")
                if try await Self.remux(ffmpeg: ffmpeg, video: video, audio: audio, output: out) {
                    return Output(file: try moveToDestination(out, folder: destination, ext: ext))
                }
            }
        }
        // No ffmpeg (or it failed): keep the raw stream; .ts plays in IINA/VLC, fMP4 plays everywhere.
        let result = try moveToDestination(video, folder: destination, ext: rawExt)
        guard let audio else { return Output(file: result) }
        _ = try moveToDestination(audio, folder: destination, ext: audio.pathExtension, suffix: " (audio)")
        return Output(file: result, note: ffmpeg == nil ? Self.noFFmpegNote
            : "ffmpeg couldn't merge the sound, so it was saved as a separate “(audio)” file.")
    }

    private static func hasAudioStream(_ file: URL, ffmpeg: URL) -> Bool {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return false }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", file.path]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !(String(data: out, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func remux(ffmpeg: URL, video: URL, audio: URL?, output: URL) async throws -> Bool {
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path]
        if let audio { args += ["-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"] }
        else { args += ["-map", "0:v?", "-map", "0:a?"] }
        args += ["-c", "copy"]
        if output.pathExtension == "mp4" { args += ["-movflags", "+faststart"] }
        args.append(output.path)

        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async { p.waitUntilExit(); cont.resume() }
            }
        } onCancel: { p.terminate() }
        try Task.checkCancellation()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
    }

    // MARK: - Pieces

    private func fetchAll(_ pieces: [Piece]) async throws {
        let fm = FileManager.default
        var todo: [(Int, Piece)] = []
        var doneBytes: Int64 = 0
        var states: [PieceState] = []
        for (i, p) in pieces.enumerated() {
            let path = workDir.appendingPathComponent(p.name).path
            var state = PieceState(group: p.name.first ?? "d", known: p.range.map { $0.upperBound - $0.lowerBound + 1 })
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                doneBytes += size.int64Value
                state.done = true
                state.known = size.int64Value
            } else {
                todo.append((i, p))
            }
            states.append(state)
        }
        withLock { pieceStates = states }
        let alreadyDone = pieces.count - todo.count
        update {
            $0.phase = .downloading
            $0.piecesTotal = pieces.count
            $0.piecesDone = alreadyDone
            $0.bytesDone = doneBytes
        }

        // Pieces wait in `queue`; a piece the server refused with HTTP 429 goes back to the front
        // with a not-before time, and the number running at once follows `limit`, which drops by
        // one per 429 burst (down to 1) and follows the user's − / +.
        enum Event { case done(Int64), refused(Int, Piece, TimeInterval?, epoch: Int), tick }
        var queue = todo
        var notBefore: [Int: Date] = [:]
        var refusals: [Int: Int] = [:]
        var running = 0

        try await withThrowingTaskGroup(of: Event.self) { group in
            // A heartbeat, so a raised limit or an expired wait is noticed without a piece finishing.
            group.addTask { try await Task.sleep(nanoseconds: 400_000_000); return .tick }
            while true {
                let now = Date()
                while running < withLock({ limit }),
                      let pos = queue.firstIndex(where: { (notBefore[$0.0] ?? .distantPast) <= now }) {
                    let (i, p) = queue.remove(at: pos)
                    running += 1
                    let sentIn = withLock { epoch }
                    group.addTask {
                        do { return .done(try await self.fetchPiece(p, index: i)) }
                        catch let e as HTTPStatusError where e.status == 429 { return .refused(i, p, e.retryAfter, epoch: sentIn) }
                    }
                }
                if running == 0 && queue.isEmpty { group.cancelAll(); break }
                guard let event = try await group.next() else { break }
                switch event {
                case .tick:
                    group.addTask { try await Task.sleep(nanoseconds: 400_000_000); return .tick }
                case let .done(bytes):
                    running -= 1
                    update {
                        $0.piecesDone += 1
                        $0.bytesDone += bytes
                        if job.kind != .direct, $0.piecesDone > 0 {
                            $0.totalBytes = $0.bytesDone * Int64($0.piecesTotal) / Int64($0.piecesDone)
                        }
                    }
                case let .refused(i, p, retryAfter, sentIn):
                    running -= 1
                    let n = (refusals[i] ?? 0) + 1
                    refusals[i] = n
                    let atOne = withLock { () -> Bool in
                        let wasOne = limit == 1
                        if sentIn == epoch {
                            limit = max(1, limit - 1)
                            epoch += 1
                        }
                        rateLimited = true
                        return wasOne
                    }
                    // Still refused with a single connection, again and again: give up.
                    if atOne && n > 12 {
                        throw HTTPStatusError(status: 429, retryAfter: nil, name: p.url.lastPathComponent)
                    }
                    notBefore[i] = Date().addingTimeInterval(min(retryAfter ?? min(pow(2, Double(n - 1)), 30), 120))
                    queue.insert((i, p), at: 0)
                }
            }
        }
    }

    private func fetchPiece(_ piece: Piece, index: Int) async throws -> Int64 {
        let final = workDir.appendingPathComponent(piece.name)
        let tmp = workDir.appendingPathComponent(piece.name + ".part")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await fetcher.download(piece.url, range: piece.range, to: tmp) { [weak self] got, expected in
                    self?.withLock {
                        self?.pieceStates[index].got = got
                        self?.pieceStates[index].expected = expected > 0 ? expected : nil
                    }
                }
                if let key = piece.key {
                    let data = try HLS.decryptAES128(try Data(contentsOf: tmp), key: try await keyData(key.url), iv: key.iv ?? Data(count: 16))
                    try data.write(to: tmp)
                }
                try FileManager.default.moveItem(at: tmp, to: final)
                let size = ((try? FileManager.default.attributesOfItem(atPath: final.path))?[.size] as? NSNumber)?.int64Value ?? 0
                withLock {
                    pieceStates[index].done = true
                    pieceStates[index].known = size
                }
                return size
            } catch {
                withLock { pieceStates[index].got = 0; pieceStates[index].expected = nil }
                // "Too many requests": hand the piece back to the scheduler, which slows down.
                if let e = error as? HTTPStatusError, e.status == 429 { throw e }
                attempt += 1
                if Task.isCancelled || error is CancellationError || attempt >= 5 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private func keyData(_ url: URL) async throws -> Data {
        if let cached = withLock({ keys[url] }) { return cached }
        let data = try await fetcher.data(url)
        guard data.count == 16 else { throw GrabError("The decryption key looks wrong (\(data.count) bytes).") }
        withLock { keys[url] = data }
        return data
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Files

    private func concatenate(_ names: [String], into output: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        fm.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        for name in names {
            let input = try FileHandle(forReadingFrom: workDir.appendingPathComponent(name))
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
        }
    }

    private func moveToDestination(_ file: URL, folder: URL, ext: String, suffix: String = "") throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = Self.sanitize(job.title)
        if let q = job.quality, !q.isEmpty { base += " [\(Self.sanitize(q))]" }
        base += suffix
        var target = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        try fm.moveItem(at: file, to: target)
        return target
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t").union(.controlCharacters)
        var cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "video" : cleaned
    }

    static func fileExtension(forMIME mime: String?) -> String? {
        switch mime?.lowercased() {
        case "video/mp4": "mp4"
        case "video/webm": "webm"
        case "video/quicktime": "mov"
        case "video/x-matroska": "mkv"
        case "video/x-flv": "flv"
        case "video/mp2t": "ts"
        case "audio/mp4": "m4a"
        case "audio/mpeg": "mp3"
        default: nil
        }
    }
}
