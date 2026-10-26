import Foundation

/// Output formats for post-download conversion. Only those the installed ffmpeg can encode are offered.
enum ConversionFormat: String, CaseIterable, Codable {
    case h264, h265, h264hw, h265hw, av1, vp9

    var label: String {
        switch self {
        case .h264: "MP4 · H.264 (plays everywhere)"
        case .h265: "MP4 · H.265/HEVC (smaller)"
        case .h264hw: "MP4 · H.264, hardware (fastest)"
        case .h265hw: "MP4 · H.265/HEVC, hardware (fast)"
        case .av1: "MP4 · AV1 (smallest, newer devices)"
        case .vp9: "WebM · VP9"
        }
    }

    /// For file names and the list: "H.264", "H.265"…
    var short: String {
        switch self {
        case .h264, .h264hw: "H.264"
        case .h265, .h265hw: "H.265"
        case .av1: "AV1"
        case .vp9: "VP9"
        }
    }

    var encoder: String {
        switch self {
        case .h264: "libx264"
        case .h265: "libx265"
        case .h264hw: "h264_videotoolbox"
        case .h265hw: "hevc_videotoolbox"
        case .av1: "libsvtav1"
        case .vp9: "libvpx-vp9"
        }
    }

    var fileExtension: String { self == .vp9 ? "webm" : "mp4" }

    /// ffprobe's name for the video codec this format produces.
    var codecName: String {
        switch self {
        case .h264, .h264hw: "h264"
        case .h265, .h265hw: "hevc"
        case .av1: "av1"
        case .vp9: "vp9"
        }
    }

    /// Sound codecs that can be copied into this format's container unchanged.
    var copyableAudio: Set<String> { self == .vp9 ? ["opus", "vorbis"] : ["aac", "mp3", "alac"] }

    /// Constant-quality settings: close to the original's look, at whatever size that takes.
    var qualityArgs: [String] {
        switch self {
        case .h264: ["-crf", "20", "-preset", "medium"]
        case .h265: ["-crf", "22", "-preset", "medium", "-x265-params", "log-level=error"]
        case .h264hw: ["-q:v", "60"]
        case .h265hw: ["-q:v", "60"]
        case .av1: ["-crf", "30", "-preset", "8"]
        case .vp9: ["-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]
        }
    }
    var twoPass: Bool { [.h264, .h265, .vp9].contains(self) }

    /// How much bitrate this codec needs for the same quality as H.264 (for the quality ceiling).
    var efficiency: Double {
        switch self {
        case .h264: 1
        case .h264hw: 1.25
        case .h265: 0.6
        case .h265hw: 0.75
        case .av1: 0.5
        case .vp9: 0.65
        }
    }

    /// Encoders in the installed ffmpeg (asked once).
    static let available: [ConversionFormat] = {
        guard let ffmpeg = Paths.ffmpeg else { return [] }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-encoders"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let names = Set(out.split(separator: "\n").compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) })
        return allCases.filter { names.contains($0.encoder) }
    }()
}

/// Makes a copy of a finished download in a resolution and format that fits a size limit, losing
/// as little quality as possible. It tries, in order:
///  1. copy: same codec, no scaling needed → copy the streams unchanged;
///  2. quality: scale to the resolution at (near) the original's quality, whatever size that gives;
///  3. fitted: only if that's over the limit, pick the bitrate that fits (two passes where the encoder
///     supports it), measure, and shrink again if it still overshoots.
/// A smaller-than-limit result is never inflated to "use up" the limit.
final class Converter: @unchecked Sendable {
    enum Mode: String, Codable { case copy, quality, fitted }
    struct Progress { var fraction: Double; var stage: String }
    private struct TooBig: Error {}

    let ffmpeg: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(ffmpeg: URL) { self.ffmpeg = ffmpeg }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        p?.terminate()
    }

    func convert(input: URL, output: URL, format: ConversionFormat, height: Int, maxBytes: Int64,
                 workDir: URL, progress: @escaping @Sendable (Progress) -> Void) async throws -> Mode {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let info = try probe(input)
        guard info.duration > 0 else { throw GrabError("Couldn't read the video's length.") }
        let fits = { (self.size(of: output) ?? .max) <= maxBytes }
        let audioCopyable = info.audioCodec.map(format.copyableAudio.contains) ?? true
        let container = format.fileExtension == "mp4" ? ["-movflags", "+faststart"] : []
        let tag = format.codecName == "hevc" && format.fileExtension == "mp4" ? ["-tag:v", "hvc1"] : []
        let base = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", "pipe:1", "-i", input.path,
                    "-map", "0:v:0", "-map", "0:a:0?"]

        // 1. Nothing to scale or re-encode: copy the streams as they are.
        if info.videoCodec == format.codecName, (info.height ?? .max) <= height, audioCopyable {
            try await run(base + ["-c", "copy"] + tag + container + [output.path], duration: info.duration) {
                progress(Progress(fraction: $0, stage: "Copying at the original quality"))
            }
            if fits() { return .copy }
        } else {
            // 2. Scale only, keeping the quality; give up early once it's clearly heading over the limit.
            let audio = audioCopyable ? ["-c:a", "copy"]
                : (format == .vp9 ? ["-c:a", "libopus", "-b:a", "160k"] : ["-c:a", "aac", "-b:a", "192k"])
            do {
                try await run(base + ["-vf", "scale=-2:'min(\(height),ih)'", "-pix_fmt", "yuv420p", "-c:v", format.encoder]
                              + format.qualityArgs + tag + audio + container + [output.path],
                              duration: info.duration, abortOver: maxBytes) {
                    progress(Progress(fraction: $0, stage: "Converting at the original quality"))
                }
                if fits() { return .quality }
            } catch is TooBig {}
        }
        try? FileManager.default.removeItem(at: output)

        // 3. Too big at full quality: give the picture whatever the limit leaves after the sound.
        let totalBitsPerSecond = Double(maxBytes) * 8 * 0.97 / info.duration
        var audio = info.hasAudio ? 128_000.0 : 0
        if info.hasAudio, totalBitsPerSecond - audio < audio * 4 { audio = 96_000 }
        if info.hasAudio, totalBitsPerSecond - audio < audio * 2 { audio = 64_000 }
        var video = totalBitsPerSecond - audio
        let needed = Int64(((50_000 + audio) * info.duration / 8 / 0.97) / 1_000_000) + 1
        guard video >= 50_000 else {
            throw GrabError("This video is too long to fit in \(maxBytes / 1_000_000) MB (it needs at least about \(needed) MB).")
        }
        video = min(video, Self.ceiling(height: min(height, info.height ?? height)) * format.efficiency)

        for attempt in 1 ... 3 {
            try await encode(input: input, output: output, format: format, height: height,
                             videoBitrate: Int(video), audioBitrate: Int(audio), duration: info.duration,
                             workDir: workDir, stage: "Fitting into \(maxBytes / 1_000_000) MB", progress: progress)
            if fits() { return .fitted }
            if attempt == 3 { break }
            // Over the limit: shrink the picture's share by the overshoot, plus a margin.
            let over = Double(size(of: output) ?? maxBytes) / Double(maxBytes)
            video = max(30_000, (video + audio) / over * 0.95 - audio)
        }
        try? FileManager.default.removeItem(at: output)
        throw GrabError("Couldn't get the video under \(maxBytes / 1_000_000) MB in \(format.short).")
    }

    private func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Video bitrate (H.264) beyond which a resolution doesn't visibly improve.
    private static func ceiling(height: Int) -> Double {
        switch height {
        case 1440...: 14_000_000
        case 1080...: 8_000_000
        case 720...: 5_000_000
        case 480...: 2_500_000
        case 360...: 1_200_000
        default: 700_000
        }
    }

    // MARK: - ffmpeg

    private func encode(input: URL, output: URL, format: ConversionFormat, height: Int, videoBitrate: Int,
                        audioBitrate: Int, duration: Double, workDir: URL, stage: String,
                        progress: @escaping @Sendable (Progress) -> Void) async throws {
        let scale = ["-vf", "scale=-2:'min(\(height),ih)'", "-pix_fmt", "yuv420p"]
        let rate = "\(videoBitrate / 1000)k"
        var video = ["-c:v", format.encoder, "-b:v", rate]
        let log = workDir.appendingPathComponent("pass").path
        switch format {
        case .h264: video += ["-preset", "medium"]
        case .h265: video += ["-preset", "medium", "-tag:v", "hvc1"]
        case .h264hw: video += ["-maxrate", rate, "-bufsize", "\(videoBitrate * 2 / 1000)k"]
        case .h265hw: video += ["-maxrate", rate, "-bufsize", "\(videoBitrate * 2 / 1000)k", "-tag:v", "hvc1"]
        case .av1: video += ["-preset", "8"]
        case .vp9: video += ["-deadline", "good", "-row-mt", "1"]
        }
        let sound: [String] = audioBitrate == 0 ? ["-an"]
            : (format == .vp9 ? ["-c:a", "libopus"] : ["-c:a", "aac"]) + ["-b:a", "\(audioBitrate / 1000)k"]
        let container = format.fileExtension == "mp4" ? ["-movflags", "+faststart"] : []
        let base = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", "pipe:1", "-i", input.path,
                    "-map", "0:v:0", "-map", "0:a:0?"]

        if format.twoPass {
            func passArgs(_ n: Int) -> [String] {
                switch format {
                case .h265: return ["-x265-params", "pass=\(n):stats=\(log).x265:log-level=error"]
                case .vp9: return ["-pass", "\(n)", "-passlogfile", log, "-cpu-used", n == 1 ? "4" : "2"]
                default: return ["-pass", "\(n)", "-passlogfile", log]
                }
            }
            try await run(base + scale + video + passArgs(1) + ["-an", "-f", "null", "/dev/null"], duration: duration) {
                progress(Progress(fraction: $0 / 2, stage: stage))
            }
            try await run(base + scale + video + passArgs(2) + sound + container + [output.path], duration: duration) {
                progress(Progress(fraction: 0.5 + $0 / 2, stage: stage))
            }
        } else {
            try await run(base + scale + video + sound + container + [output.path], duration: duration) {
                progress(Progress(fraction: $0, stage: stage))
            }
        }
    }

    /// Runs ffmpeg, reporting how far through the video it is from its `-progress` output.
    private func run(_ args: [String], duration: Double, abortOver: Int64? = nil,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let p = Process()
        let out = Pipe()
        let err = Pipe()
        p.executableURL = ffmpeg
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        let tooBig = Flag()
        out.fileHandleForReading.readabilityHandler = { h in
            guard let text = String(data: h.availableData, encoding: .utf8) else { return }
            var written: Double?
            for line in text.split(separator: "\n") {
                if line.hasPrefix("total_size="), let n = Double(line.dropFirst(11)) { written = n }
                guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), us > 0 else { continue }
                let fraction = min(1, us / 1_000_000 / duration)
                progress(fraction)
                // Projected final size well over the limit after a fair sample: stop wasting time.
                if let limit = abortOver, let w = written, fraction >= 0.08, w / fraction > Double(limit) * 1.1 {
                    tooBig.set()
                    p.terminate()
                }
            }
        }
        if !register(p) { throw CancellationError() }
        try p.run()
        let errData = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let data = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: data)
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        if unregister() { throw CancellationError() }
        if tooBig.isSet { throw TooBig() }
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
            throw GrabError("ffmpeg failed\(msg.isEmpty ? "" : ": \(msg)")")
        }
    }

    /// Remembers the running ffmpeg so `cancel()` can stop it. False if already cancelled.
    private func register(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    /// Forgets the finished ffmpeg; true if it was cancelled.
    private func unregister() -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = nil
        return cancelled
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct Info {
        var duration: Double
        var height: Int?
        var videoCodec: String?
        var audioCodec: String?
        var hasAudio: Bool { audioCodec != nil }
    }

    private func probe(_ file: URL) throws -> Info {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let p = Process()
        let pipe = Pipe()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,height", "-of", "json", file.path]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        return Info(duration: duration, height: video?["height"] as? Int,
                    videoCodec: video?["codec_name"] as? String, audioCodec: audio?["codec_name"] as? String)
    }
}
