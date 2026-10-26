import Foundation

/// MPEG-DASH (.mpd) parsing: lists video/audio representations and the segments of each.
/// Covers SegmentTemplate (with $Number$/$Time$ and SegmentTimeline), SegmentList, and
/// single-file representations (SegmentBase or a bare BaseURL).
enum DASH {
    struct Track {
        enum Kind { case video, audio }
        var kind: Kind
        var id: String
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var frameRate: Double?
        var codecs: String
        var mimeType: String
        var initSegment: (url: URL, range: ClosedRange<Int64>?)?
        var segments: [(url: URL, range: ClosedRange<Int64>?)] = []
        /// Single-file representation: download the whole file instead of segments.
        var file: URL?

        var hasAudio: Bool { kind == .audio || codecs.lowercased().contains("mp4a") || codecs.lowercased().contains("opus") }
        var isWebM: Bool { mimeType.contains("webm") }
        /// Directories this track's media is fetched from (to hide them from the "plain file" list).
        var prefixes: [String] {
            var urls = segments.prefix(1).map { $0.url } + (initSegment.map { [$0.url] } ?? [])
            if let file { urls.append(file) }
            return urls.map { $0.deletingLastPathComponent().absoluteString }
        }
    }

    struct Manifest {
        var tracks: [Track] = []
        var duration: Double = 0
        var isLive = false
        var drm = false

        var videos: [Track] { tracks.filter { $0.kind == .video } }
        var audios: [Track] { tracks.filter { $0.kind == .audio } }

        /// One entry per resolution; prefers H.264/HEVC (play everywhere), then the highest bitrate.
        var videoQualities: [Track] {
            func rank(_ t: Track) -> (Int, Int) {
                let c = t.codecs.lowercased()
                return (c.hasPrefix("avc") || c.hasPrefix("hvc") || c.hasPrefix("hev") ? 1 : 0, t.bandwidth)
            }
            var best: [Int: Track] = [:]
            for t in videos {
                let k = t.height ?? 0
                if let cur = best[k], rank(cur) >= rank(t) { continue }
                best[k] = t
            }
            return best.values.sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) }
        }

        /// The audio to merge with `video`: AAC first (fits in .mp4), then the highest bitrate.
        func audio(for video: Track) -> Track? {
            guard !video.hasAudio else { return nil }
            let sameContainer = audios.filter { $0.isWebM == video.isWebM }
            let pool = sameContainer.isEmpty ? audios : sameContainer
            return pool.max { a, b in
                let ra = (a.codecs.lowercased().contains("mp4a") ? 1 : 0, a.bandwidth)
                let rb = (b.codecs.lowercased().contains("mp4a") ? 1 : 0, b.bandwidth)
                return ra < rb
            }
        }
    }

    static func isManifest(_ text: String) -> Bool { text.contains("<MPD") }

    static func parse(_ text: String, base: URL) throws -> Manifest {
        guard let root = XMLTree.parse(Data(text.utf8)), root.name == "MPD" else { throw GrabError("Not a DASH manifest.") }
        var m = Manifest()
        m.isLive = root.attrs["type"] == "dynamic"
        m.duration = root.attrs["mediaPresentationDuration"].flatMap(isoDuration) ?? 0
        var mpdBase = base
        if let b = root.child("BaseURL")?.text, let u = URL(string: b, relativeTo: base) { mpdBase = u }

        // Multi-period manifests are usually ads around the main content: take the longest period.
        let periods = root.children("Period")
        let total = m.duration
        let period = periods.max { periodDuration($0, total, count: periods.count) < periodDuration($1, total, count: periods.count) }
        guard let period else { return m }
        let pDuration = periodDuration(period, m.duration, count: periods.count)
        if m.duration == 0 { m.duration = pDuration }
        let periodBase = baseURL(period, mpdBase)

        for set in period.children("AdaptationSet") {
            if set.child("ContentProtection") != nil { m.drm = true }
            let setBase = baseURL(set, periodBase)
            for rep in set.children("Representation") {
                if rep.child("ContentProtection") != nil { m.drm = true }
                func attr(_ k: String) -> String? { rep.attrs[k] ?? set.attrs[k] }
                let mime = attr("mimeType") ?? ""
                let contentType = set.attrs["contentType"] ?? String(mime.split(separator: "/").first ?? "")
                let kind: Track.Kind
                switch contentType {
                case "video": kind = .video
                case "audio": kind = .audio
                default: continue // subtitles, images
                }
                let id = rep.attrs["id"] ?? UUID().uuidString
                let bandwidth = Int(rep.attrs["bandwidth"] ?? "") ?? 0
                var t = Track(kind: kind, id: id, bandwidth: bandwidth,
                              width: attr("width").flatMap { Int($0) }, height: attr("height").flatMap { Int($0) },
                              frameRate: attr("frameRate").flatMap(frameRate), codecs: attr("codecs") ?? "", mimeType: mime)
                let repBase = baseURL(rep, setBase)
                let vars = ["RepresentationID": id, "Bandwidth": String(bandwidth)]

                let templates = [period.child("SegmentTemplate"), set.child("SegmentTemplate"), rep.child("SegmentTemplate")].compactMap { $0 }
                let lists = [period.child("SegmentList"), set.child("SegmentList"), rep.child("SegmentList")].compactMap { $0 }
                if !templates.isEmpty {
                    applyTemplate(merge(templates), base: repBase, vars: vars, duration: pDuration, to: &t)
                } else if let list = lists.last {
                    applyList(list, base: repBase, to: &t)
                } else {
                    t.file = repBase
                }
                if t.file != nil || !t.segments.isEmpty { m.tracks.append(t) }
            }
        }
        return m
    }

    // MARK: - Segment addressing

    private static func applyTemplate(_ tpl: XMLTree, base: URL, vars: [String: String], duration: Double, to t: inout Track) {
        let a = tpl.attrs
        let timescale = Double(a["timescale"] ?? "") ?? 1
        let startNumber = Int(a["startNumber"] ?? "") ?? 1
        if let i = a["initialization"], let u = URL(string: expand(i, vars), relativeTo: base) { t.initSegment = (u, nil) }
        guard let media = a["media"] else { return }

        func add(number: Int, time: Int64) {
            var v = vars
            v["Number"] = String(number)
            v["Time"] = String(time)
            if let u = URL(string: expand(media, v), relativeTo: base) { t.segments.append((u, nil)) }
        }

        if let timeline = tpl.child("SegmentTimeline") {
            let end = Int64(duration * timescale) + (Int64(a["presentationTimeOffset"] ?? "") ?? 0)
            var time: Int64 = 0
            var number = startNumber
            let entries = timeline.children("S")
            for (i, s) in entries.enumerated() {
                if let st = Int64(s.attrs["t"] ?? "") { time = st }
                guard let d = Int64(s.attrs["d"] ?? ""), d > 0 else { continue }
                var repeats = Int(s.attrs["r"] ?? "") ?? 0
                if repeats < 0 { // repeat until the next entry, or the end of the period
                    let next = i + 1 < entries.count ? Int64(entries[i + 1].attrs["t"] ?? "") : nil
                    let stop = next ?? end
                    repeats = stop > time ? Int((stop - time + d - 1) / d) - 1 : 0
                }
                for _ in 0 ... max(0, repeats) {
                    add(number: number, time: time)
                    time += d
                    number += 1
                }
            }
        } else if let d = Double(a["duration"] ?? ""), d > 0, duration > 0 {
            let count = Int((duration * timescale / d).rounded(.up))
            for n in 0 ..< count { add(number: startNumber + n, time: Int64(Double(n) * d)) }
        }
    }

    private static func applyList(_ list: XMLTree, base: URL, to t: inout Track) {
        if let i = list.child("Initialization") {
            let u = i.attrs["sourceURL"].flatMap { URL(string: $0, relativeTo: base) } ?? base
            t.initSegment = (u, i.attrs["range"].flatMap(byteRange))
        }
        for s in list.children("SegmentURL") {
            let u = s.attrs["media"].flatMap { URL(string: $0, relativeTo: base) } ?? base
            t.segments.append((u, s.attrs["mediaRange"].flatMap(byteRange)))
        }
    }

    /// Later (more specific) templates override earlier ones attribute by attribute.
    private static func merge(_ templates: [XMLTree]) -> XMLTree {
        let merged = XMLTree(name: "SegmentTemplate")
        for t in templates {
            merged.attrs.merge(t.attrs) { _, new in new }
            if let tl = t.child("SegmentTimeline") { merged.elements = [tl] }
        }
        return merged
    }

    /// Fills `$RepresentationID$`, `$Number%05d$`, `$Time$`, `$Bandwidth$` and `$$`.
    static func expand(_ template: String, _ vars: [String: String]) -> String {
        let regex = try! NSRegularExpression(pattern: #"\$(RepresentationID|Number|Time|Bandwidth|)(?:%0(\d+)d)?\$"#)
        var out = ""
        var last = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            let r = Range(match.range, in: template)!
            out += template[last ..< r.lowerBound]
            let name = String(template[Range(match.range(at: 1), in: template)!])
            if name.isEmpty {
                out += "$"
            } else {
                var value = vars[name] ?? ""
                if let wr = Range(match.range(at: 2), in: template), let width = Int(template[wr]), value.count < width {
                    value = String(repeating: "0", count: width - value.count) + value
                }
                out += value
            }
            last = r.upperBound
        }
        return out + template[last...]
    }

    // MARK: - Helpers

    private static func baseURL(_ node: XMLTree, _ parent: URL) -> URL {
        guard let b = node.child("BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty,
              let u = URL(string: b, relativeTo: parent) else { return parent }
        return u.absoluteURL
    }

    private static func periodDuration(_ p: XMLTree, _ total: Double, count: Int) -> Double {
        p.attrs["duration"].flatMap(isoDuration) ?? (count == 1 ? total : 0)
    }

    /// ISO 8601 durations such as "PT1H2M3.5S" or "P1DT2H".
    static func isoDuration(_ s: String) -> Double? {
        let regex = try! NSRegularExpression(pattern: #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#)
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let mult: [Double] = [86400, 3600, 60, 1]
        var total = 0.0
        for i in 1 ... 4 {
            if let r = Range(m.range(at: i), in: s), let v = Double(s[r]) { total += v * mult[i - 1] }
        }
        return total
    }

    private static func frameRate(_ s: String) -> Double? {
        let parts = s.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first
    }

    private static func byteRange(_ s: String) -> ClosedRange<Int64>? {
        let p = s.split(separator: "-").compactMap { Int64($0) }
        return p.count == 2 && p[1] >= p[0] ? p[0] ... p[1] : nil
    }
}

/// A tiny DOM built with XMLParser (namespace prefixes stripped).
final class XMLTree: NSObject, XMLParserDelegate {
    let name: String
    var attrs: [String: String] = [:]
    var elements: [XMLTree] = []
    var text = ""
    private var stack: [XMLTree] = []

    init(name: String) { self.name = name }

    static func parse(_ data: Data) -> XMLTree? {
        let doc = XMLTree(name: "#document")
        doc.stack = [doc]
        let parser = XMLParser(data: data)
        parser.delegate = doc
        let ok = parser.parse()
        doc.stack = []
        return ok ? doc.elements.first : nil
    }

    func child(_ name: String) -> XMLTree? { elements.first { $0.name == name } }
    func children(_ name: String) -> [XMLTree] { elements.filter { $0.name == name } }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = XMLTree(name: local)
        node.attrs = attributeDict
        stack.last?.elements.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
}
