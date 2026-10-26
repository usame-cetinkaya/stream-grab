import CommonCrypto
import Foundation

/// Minimal HLS (m3u8) parsing: enough to list qualities from a master playlist
/// and to turn a media playlist into a list of downloadable pieces.
enum HLS {
    struct Variant: Codable {
        var url: String
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var frameRate: Double?
        var codecs: String?
        var audioURL: String?
    }

    struct Key: Hashable {
        var url: URL
        var iv: Data?
    }

    struct Segment {
        var url: URL
        var range: ClosedRange<Int64>?
        var duration: Double
        var sequence: Int
        var key: Key?
    }

    struct MediaPlaylist {
        var segments: [Segment] = []
        var initSegment: (url: URL, range: ClosedRange<Int64>?)?
        var isLive = true
        var drm = false

        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
        var isFragmentedMP4: Bool {
            initSegment != nil || segments.first.map { ["m4s", "mp4", "m4v", "cmfv"].contains($0.url.pathExtension.lowercased()) } == true
        }
    }

    static func isMaster(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    // MARK: - Master playlist

    static func parseMaster(_ text: String, base: URL) -> [Variant] {
        var audioGroups: [String: String] = [:] // GROUP-ID -> URI (default or first)
        var variants: [(Variant, audioGroup: String?)] = []
        var pending: [String: String]?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(line)
                guard a["TYPE"] == "AUDIO", let group = a["GROUP-ID"], let uri = a["URI"],
                      let url = URL(string: uri, relativeTo: base)?.absoluteString else { continue }
                if audioGroups[group] == nil || a["DEFAULT"] == "YES" { audioGroups[group] = url }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line)
            } else if let a = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: base)?.absoluteString else { continue }
                var v = Variant(url: url, bandwidth: Int(a["AVERAGE-BANDWIDTH"] ?? a["BANDWIDTH"] ?? "") ?? 0)
                if let res = a["RESOLUTION"]?.lowercased().split(separator: "x"), res.count == 2 {
                    v.width = Int(res[0]); v.height = Int(res[1])
                }
                v.frameRate = a["FRAME-RATE"].flatMap(Double.init)
                v.codecs = a["CODECS"]
                variants.append((v, a["AUDIO"]))
            }
        }
        // Audio groups may be declared after the variants that use them, so resolve at the end.
        let resolved = variants.map { v, group in
            var v = v
            v.audioURL = group.flatMap { audioGroups[$0] }
            return v
        }
        // Skip audio-only entries when real video variants exist.
        let withVideo = resolved.filter { $0.height != nil }
        let list = withVideo.isEmpty ? resolved : withVideo
        // One entry per resolution: prefer AAC audio (plays everywhere), then the highest bitrate.
        func rank(_ v: Variant) -> (Int, Int) {
            let codecs = v.codecs?.lowercased() ?? "mp4a"
            return (codecs.contains("mp4a") ? 1 : 0, v.bandwidth)
        }
        var best: [String: Variant] = [:]
        for v in list {
            let k = v.height.map(String.init) ?? v.url
            if let cur = best[k], rank(cur) >= rank(v) { continue }
            best[k] = v
        }
        return best.values.sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) }
    }

    // MARK: - Media playlist

    static func parseMedia(_ text: String, base: URL) -> MediaPlaylist {
        var p = MediaPlaylist()
        var sequence = 0
        var duration = 0.0
        var key: Key?
        var keyIsSequenceIV = false
        var nextRange: (length: Int64, offset: Int64?)?
        var lastRangeEnd: [URL: Int64] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") || line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD") {
                p.isLive = false
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                nextRange = byteRange(String(line.dropFirst(17)))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line)
                if let uri = a["URI"], let url = URL(string: uri, relativeTo: base) {
                    var r: ClosedRange<Int64>?
                    if let br = a["BYTERANGE"].flatMap(byteRange) {
                        let start = br.offset ?? 0
                        r = start ... start + br.length - 1
                    }
                    p.initSegment = (url, r)
                }
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let a = attributes(line)
                let method = a["METHOD"] ?? "NONE"
                let format = a["KEYFORMAT"] ?? "identity"
                if method == "NONE" {
                    key = nil
                } else if method == "AES-128", format == "identity",
                          let uri = a["URI"], let url = URL(string: uri, relativeTo: base),
                          ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") {
                    key = Key(url: url, iv: a["IV"].flatMap(hexData))
                    keyIsSequenceIV = key?.iv == nil
                } else if format != "identity" || method.hasPrefix("SAMPLE-AES") {
                    p.drm = true // FairPlay / Widevine / PlayReady: not downloadable, by design.
                }
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base) else { continue }
                var range: ClosedRange<Int64>?
                if let r = nextRange {
                    let start = r.offset ?? lastRangeEnd[url] ?? 0
                    range = start ... start + r.length - 1
                    lastRangeEnd[url] = start + r.length
                    nextRange = nil
                }
                var segKey = key
                if keyIsSequenceIV, segKey != nil { segKey?.iv = sequenceIV(sequence) }
                p.segments.append(Segment(url: url, range: range, duration: duration, sequence: sequence, key: segKey))
                sequence += 1
                duration = 0
            }
        }
        return p
    }

    // MARK: - Helpers

    /// Parses `KEY=VALUE,KEY="quoted, value"` attribute lists.
    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k.uppercased()] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in line[line.index(after: colon)...] {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { key = "" } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == ",", !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }

    private static func byteRange(_ s: String) -> (length: Int64, offset: Int64?)? {
        let parts = s.split(separator: "@")
        guard let len = Int64(parts.first ?? "") else { return nil }
        return (len, parts.count > 1 ? Int64(parts[1]) : nil)
    }

    private static func hexData(_ s: String) -> Data? {
        var hex = s.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        hex = String(repeating: "0", count: max(0, 32 - hex.count)) + hex
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx ..< next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }

    private static func sequenceIV(_ n: Int) -> Data {
        var iv = Data(count: 16)
        var v = UInt64(n).bigEndian
        withUnsafeBytes(of: &v) { iv.replaceSubrange(8 ..< 16, with: $0) }
        return iv
    }

    static func decryptAES128(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, i.baseAddress, d.baseAddress, data.count,
                                o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw GrabError("Couldn't decrypt a segment (AES-128 error \(status)).") }
        out.count = moved
        return out
    }
}

struct GrabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
