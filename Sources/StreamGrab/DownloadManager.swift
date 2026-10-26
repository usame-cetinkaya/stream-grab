import AppKit
import Combine

/// One converted copy of a finished download.
struct Conversion: Codable, Identifiable {
    enum State: String, Codable { case waiting, running, done, failed }
    var id = UUID()
    var state: State = .waiting
    var format: ConversionFormat
    var height: Int
    var maxMB: Int
    var progress: Double?
    var stage: String?
    var mode: Converter.Mode?
    var file: URL?
    var size: Int64?
    var error: String?
    var elapsed: Double?

    var isPending: Bool { state == .waiting || state == .running }
    var label: String { "\(height)p · \(format.short)" }
}

struct DownloadItem: Identifiable, Codable {
    enum Status: String, Codable { case queued, downloading, merging, paused, completed, failed }

    var id = UUID()
    var job: Job
    var status: Status = .queued
    var error: String?
    var note: String?
    var file: URL?
    var piecesDone = 0
    var piecesTotal = 0
    var bytesDone: Int64 = 0
    var totalBytes: Int64?
    var speed: Double = 0
    var created = Date()
    /// Time spent actually downloading (paused and queued time excluded). Optional so lists
    /// saved by older versions still load.
    var elapsed: Double?
    var runningSince: Date?
    /// This download's own connection count (nil: use the Settings default).
    var connections: Int?
    /// The server answered "Too many requests" (HTTP 429), so connections were lowered.
    var rateLimited: Bool?
    /// Automatic retries after a temporary failure: how many so far, and when the next one is due.
    var autoRetries: Int?
    var retryAt: Date?
    /// Converted copies, automatic or from the Convert… button, oldest first.
    var conversions: [Conversion]?
    var hasPendingConversion: Bool { conversions?.contains(where: \.isPending) == true }

    var isActive: Bool { status == .downloading || status == .merging }

    mutating func startClock() {
        if runningSince == nil { runningSince = Date() }
    }

    mutating func stopClock() {
        guard let since = runningSince else { return }
        elapsed = (elapsed ?? 0) + Date().timeIntervalSince(since)
        runningSince = nil
    }

    var fraction: Double? {
        if status == .completed { return 1 }
        if let t = totalBytes, t > 0, job.kind == .direct { return min(1, Double(bytesDone) / Double(t)) }
        if piecesTotal > 0 { return Double(piecesDone) / Double(piecesTotal) }
        return nil
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var folder: URL {
        didSet { d.set(folder.path, forKey: "folder") }
    }
    @Published var connections: Int {
        didSet { d.set(connections, forKey: "connections") }
    }
    @Published var simultaneous: Int {
        didSet { d.set(simultaneous, forKey: "simultaneous") }
    }
    @Published var autoRetry: Bool {
        didSet { d.set(autoRetry, forKey: "autoRetry") }
    }
    // Post-download conversion.
    @Published var convert: Bool {
        didSet { d.set(convert, forKey: "convert") }
    }
    @Published var convertHeight: Int {
        didSet { d.set(convertHeight, forKey: "convertHeight") }
    }
    @Published var convertMaxMB: Int {
        didSet {
            if convertMaxMB < 1 { convertMaxMB = 1 }
            d.set(convertMaxMB, forKey: "convertMaxMB")
        }
    }
    @Published var convertFormat: ConversionFormat {
        didSet { d.set(convertFormat.rawValue, forKey: "convertFormat") }
    }
    static let convertHeights = [1080, 720, 480, 360, 240]

    static let connectionChoices = [1, 2, 4, 8, 12, 16]

    private init() {
        folder = d.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Older versions allowed any number; snap to one of the choices the Settings menu offers.
        let saved = d.object(forKey: "connections") as? Int ?? 8
        connections = Self.connectionChoices.min { abs($0 - saved) < abs($1 - saved) } ?? 8
        simultaneous = d.object(forKey: "simultaneous") as? Int ?? 3
        autoRetry = d.object(forKey: "autoRetry") as? Bool ?? true
        convert = d.object(forKey: "convert") as? Bool ?? false
        convertHeight = d.object(forKey: "convertHeight") as? Int ?? 720
        convertMaxMB = max(1, d.object(forKey: "convertMaxMB") as? Int ?? 800)
        convertFormat = d.string(forKey: "convertFormat").flatMap(ConversionFormat.init(rawValue:)) ?? .h264
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Piece layout of downloads started in this session, for the segmented progress bar.
    @Published private(set) var maps: [UUID: Engine.PieceMap] = [:]
    private var engines: [UUID: (engine: Engine, task: Task<Void, Never>)] = [:]
    private var timer: Timer?
    private var piecesAtStart: [UUID: Int] = [:]
    private var network: NetworkWatcher?
    private var dirty = false
    private let store = Paths.support.appendingPathComponent("downloads.json")
    private let settings = Settings.shared

    private init() {
        if let data = try? Data(contentsOf: store),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved.map { item in
                var item = item
                if item.isActive || item.status == .queued { item.status = .paused }
                for i in item.conversions?.indices ?? 0 ..< 0 where item.conversions?[i].state == .running {
                    item.conversions?[i].state = .waiting
                    item.conversions?[i].progress = nil
                }
                item.runningSince = nil // time before an unexpected exit can't be known
                item.speed = 0
                return item
            }
        }
        // Conversions interrupted by quitting pick up again.
        DispatchQueue.main.async { DownloadManager.shared.scheduleConversion() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in DownloadManager.shared.tick() }
        }
        network = NetworkWatcher {
            Task { @MainActor in DownloadManager.shared.networkReturned() }
        }
    }

    // MARK: Actions

    @discardableResult
    func add(_ job: Job) -> DownloadItem {
        let item = DownloadItem(job: job)
        items.insert(item, at: 0)
        changed()
        schedule()
        return item
    }

    func pause(_ id: UUID) {
        engines[id]?.task.cancel()
        engines[id] = nil
        set(id) { $0.status = .paused; $0.speed = 0; $0.stopClock() }
        // Keep the finished parts on the bar; nothing is downloading any more.
        maps[id]?.runs.removeAll { $0.active }
        schedule()
    }

    func resume(_ id: UUID) {
        set(id) { $0.status = .queued; $0.error = nil; $0.note = nil; $0.retryAt = nil }
        schedule()
    }

    /// The Retry button: start over with a fresh set of automatic retries.
    func retryNow(_ id: UUID) {
        set(id) { $0.autoRetries = nil }
        resume(id)
    }

    /// Cancel a pending automatic retry; the download stays in the list, paused.
    func stopRetrying(_ id: UUID) {
        set(id) { $0.retryAt = nil; $0.autoRetries = nil; $0.status = .paused }
    }

    /// Back online: retries waiting for a network problem to clear can go now.
    func networkReturned() {
        for item in items where item.status == .failed && item.retryAt != nil {
            set(item.id) { $0.retryAt = Date().addingTimeInterval(2) }
        }
    }

    /// Cancels (if running), forgets the download, and deletes its pieces. A finished video in the
    /// download folder is kept: removing a finished item only clears it from the list.
    func remove(_ id: UUID) {
        if let c = converting, c.item == id { c.converter.cancel() }
        let task = engines[id]?.task
        task?.cancel()
        engines[id] = nil
        items.removeAll { $0.id == id }
        maps[id] = nil
        changed()
        schedule()
        let dir = workDir(id)
        // Delete only once the download has fully stopped, so a piece that was still arriving
        // can't land in the folder after it's gone.
        Task.detached {
            await task?.value
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func clearFinished() {
        for item in items where item.status == .completed { try? FileManager.default.removeItem(at: workDir(item.id)) }
        items.removeAll { $0.status == .completed && !$0.hasPendingConversion }
        changed()
    }

    // MARK: Conversion

    private var converting: (item: UUID, conversion: UUID, converter: Converter, task: Task<Void, Never>)?

    private func updateConversion(_ item: UUID, _ conversion: UUID, _ change: (inout Conversion) -> Void) {
        set(item) { i in
            guard let k = i.conversions?.firstIndex(where: { $0.id == conversion }) else { return }
            change(&i.conversions![k])
        }
    }

    /// Converts one copy at a time (encoding already uses every core), oldest request first.
    private func scheduleConversion() {
        guard converting == nil, let ffmpeg = Paths.ffmpeg else { return }
        let next = items.reversed().lazy.compactMap { item -> (DownloadItem, Conversion)? in
            guard item.status == .completed, let c = item.conversions?.first(where: { $0.state == .waiting }) else { return nil }
            return (item, c)
        }.first
        guard let (item, c) = next, let input = item.file else { return }
        let itemID = item.id, convID = c.id
        guard FileManager.default.fileExists(atPath: input.path) else {
            updateConversion(itemID, convID) { $0.state = .failed; $0.error = "The downloaded file is no longer there." }
            return scheduleConversion()
        }
        // Next to the original; if that folder can't be written to, the download folder.
        var folder = input.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) { folder = settings.folder }
        let output = Self.uniqueURL(folder
            .appendingPathComponent("\(input.deletingPathExtension().lastPathComponent) (\(c.height)p \(c.format.short))")
            .appendingPathExtension(c.format.fileExtension))
        let converter = Converter(ffmpeg: ffmpeg)
        let scratch = Paths.work.appendingPathComponent("\(convID.uuidString)-convert", isDirectory: true)
        let started = Date()
        updateConversion(itemID, convID) { $0.state = .running; $0.progress = 0; $0.error = nil; $0.stage = nil }
        let task = Task.detached {
            var failure: String?
            var mode: Converter.Mode?
            do {
                mode = try await converter.convert(input: input, output: output, format: c.format, height: c.height,
                                                   maxBytes: Int64(c.maxMB) * 1_000_000, workDir: scratch) { p in
                    Task { @MainActor in DownloadManager.shared.conversionProgress(itemID, convID, p) }
                }
            } catch is CancellationError {
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            try? FileManager.default.removeItem(at: scratch)
            let elapsed = Date().timeIntervalSince(started)
            let cancelled = converter.isCancelled
            let ok = !cancelled && failure == nil
            if !ok { try? FileManager.default.removeItem(at: output) }
            let (result, how) = (failure, mode)
            await MainActor.run {
                DownloadManager.shared.conversionFinished(itemID, convID, output: ok ? output : nil, mode: how,
                                                          error: cancelled ? nil : result, elapsed: elapsed)
            }
        }
        converting = (itemID, convID, converter, task)
    }

    private func conversionProgress(_ item: UUID, _ conversion: UUID, _ p: Converter.Progress) {
        guard converting?.conversion == conversion,
              let i = items.firstIndex(where: { $0.id == item }),
              let k = items[i].conversions?.firstIndex(where: { $0.id == conversion }) else { return }
        items[i].conversions?[k].progress = p.fraction
        items[i].conversions?[k].stage = p.stage
    }

    private func conversionFinished(_ item: UUID, _ conversion: UUID, output: URL?, mode: Converter.Mode?,
                                    error: String?, elapsed: Double) {
        guard converting?.conversion == conversion else { return }
        converting = nil
        if output == nil && error == nil {
            set(item) { $0.conversions?.removeAll { $0.id == conversion } } // cancelled
        } else {
            updateConversion(item, conversion) { c in
                c.progress = nil
                c.stage = nil
                if let output {
                    c.state = .done
                    c.file = output
                    c.mode = mode
                    c.size = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value
                    c.elapsed = elapsed
                } else {
                    c.state = .failed
                    c.error = error
                }
            }
        }
        scheduleConversion()
    }

    // MARK: Videos added from disk

    /// Common video file extensions, for files macOS doesn't know as movies (e.g. .mkv without a player).
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "3gp", "ogv"]

    static func looksLikeVideo(_ url: URL) -> Bool {
        if videoExtensions.contains(url.pathExtension.lowercased()) { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .movie) == true
    }

    /// Adds existing video files as if StreamGrab had just downloaded them: they can be converted
    /// automatically (when that's on) or with Convert…. The files stay where they are.
    /// Returns how many were added (videos already in the list and non-videos are skipped).
    @discardableResult
    func addFiles(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let url = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  Self.looksLikeVideo(url),
                  !items.contains(where: { $0.job.kind == .local && $0.file?.standardizedFileURL == url }) else { continue }
            var item = DownloadItem(job: Job(kind: .local, url: url.absoluteString, title: url.deletingPathExtension().lastPathComponent))
            item.status = .completed
            item.file = url
            item.totalBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
            item.bytesDone = item.totalBytes ?? 0
            items.insert(item, at: 0)
            changed()
            added += 1
            let id = item.id
            if let ffmpeg = Paths.ffmpeg {
                // Show the resolution like downloads do (ffprobe, off the main thread).
                Task.detached {
                    let height = Converter.videoHeight(url, ffmpeg: ffmpeg)
                    await MainActor.run { DownloadManager.shared.set(id) { $0.job.quality = height.map { "\($0)p" } } }
                }
            }
            if settings.convert, Paths.ffmpeg != nil {
                convert(id, format: settings.convertFormat, height: settings.convertHeight, maxMB: settings.convertMaxMB)
            }
        }
        return added
    }

    /// The Convert… button on a finished download: its own settings, whatever the global ones are.
    /// Works any number of times; every copy is kept and listed.
    func convert(_ id: UUID, format: ConversionFormat, height: Int, maxMB: Int) {
        set(id) { $0.conversions = ($0.conversions ?? []) + [Conversion(format: format, height: height, maxMB: max(1, maxMB))] }
        scheduleConversion()
    }

    func cancelConversion(_ item: UUID, _ conversion: UUID) {
        if let c = converting, c.conversion == conversion {
            c.converter.cancel()
        } else {
            set(item) { $0.conversions?.removeAll { $0.id == conversion } }
        }
    }

    /// Removes a finished or failed copy's line; a converted file stays on disk.
    func dismissConversion(_ item: UUID, _ conversion: UUID) {
        set(item) { $0.conversions?.removeAll { $0.id == conversion } }
    }

    func retryConversion(_ item: UUID, _ conversion: UUID) {
        updateConversion(item, conversion) { $0.state = .waiting; $0.error = nil; $0.progress = nil }
        scheduleConversion()
    }

    private func convertedFile(_ item: UUID, _ conversion: UUID) -> URL? {
        items.first { $0.id == item }?.conversions?.first { $0.id == conversion }?.file
    }

    func revealConverted(_ item: UUID, _ conversion: UUID) {
        if let f = convertedFile(item, conversion) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
    }

    func openConverted(_ item: UUID, _ conversion: UUID) {
        if let f = convertedFile(item, conversion) { NSWorkspace.shared.open(f) }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var target = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return target
    }

    /// The − / + on a download row.
    func setConnections(_ id: UUID, _ n: Int) {
        let n = min(max(1, n), Engine.maxConnections)
        set(id) { $0.connections = n; $0.rateLimited = nil }
        engines[id]?.engine.setConnections(n)
    }

    func connections(of item: DownloadItem) -> Int { item.connections ?? settings.connections }

    func reveal(_ id: UUID) {
        guard let file = items.first(where: { $0.id == id })?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func open(_ id: UUID) {
        guard let file = items.first(where: { $0.id == id })?.file else { return }
        NSWorkspace.shared.open(file)
    }

    // MARK: Scheduling

    private func workDir(_ id: UUID) -> URL { Paths.work.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func schedule() {
        let running = items.filter(\.isActive).count
        let slots = max(0, settings.simultaneous - running)
        for item in items.reversed().filter({ $0.status == .queued }).prefix(slots) { start(item) }
        updateBadge()
    }

    private func start(_ item: DownloadItem) {
        let id = item.id
        let engine = Engine(job: item.job, workDir: workDir(id), connections: item.connections ?? settings.connections)
        piecesAtStart[id] = item.piecesDone
        let folder = settings.folder
        set(id) { $0.status = .downloading; $0.error = nil; $0.startClock() }
        let task = Task.detached { [engine] in
            do {
                let out = try await engine.run(destination: folder, ffmpeg: Paths.ffmpeg)
                await MainActor.run { DownloadManager.shared.finished(id, file: out.file, note: out.note, error: nil) }
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { DownloadManager.shared.finished(id, file: nil, note: nil, error: error) }
            }
        }
        engines[id] = (engine, task)
    }

    private func finished(_ id: UUID, file: URL?, note: String?, error: Error?) {
        guard engines[id] != nil else { return }
        if let snap = engines[id]?.engine.snapshot() { apply(snap, to: id) }
        engines[id] = nil
        set(id) { item in
            item.speed = 0
            item.stopClock()
            if let file {
                item.status = .completed
                item.autoRetries = nil
                item.file = file
                item.note = note
                item.job.headers = [:] // don't keep cookies around once they're no longer needed
                item.totalBytes = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? item.bytesDone
                item.bytesDone = item.totalBytes ?? item.bytesDone
            } else {
                item.status = .failed
                item.error = (error as NSError?).map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
                // Temporary problem: try again later, waiting longer each time. A try that got
                // somewhere before failing starts the count over.
                if settings.autoRetry, let error, RetryPolicy.isTransient(error) {
                    let progressed = item.piecesDone > (piecesAtStart[id] ?? item.piecesDone)
                    let attempt = (progressed ? 0 : item.autoRetries ?? 0) + 1
                    if attempt <= RetryPolicy.maxAttempts {
                        item.autoRetries = attempt
                        item.retryAt = Date().addingTimeInterval(RetryPolicy.delay(attempt: attempt, retryAfter: RetryPolicy.retryAfter(error)))
                    } else {
                        item.retryAt = nil
                        item.error = (item.error ?? "Failed") + " (gave up after \(RetryPolicy.maxAttempts) automatic retries)"
                    }
                } else {
                    item.retryAt = nil
                }
            }
        }
        piecesAtStart[id] = nil
        if file != nil { try? FileManager.default.removeItem(at: workDir(id)) }
        if file != nil { maps[id] = nil } else { maps[id]?.runs.removeAll { $0.active } }
        if file != nil { NSApp.requestUserAttention(.informationalRequest) }
        if file != nil, settings.convert, Paths.ffmpeg != nil {
            convert(id, format: settings.convertFormat, height: settings.convertHeight, maxMB: settings.convertMaxMB)
        }
        schedule()
    }

    private func tick() {
        for (id, entry) in engines { apply(entry.engine.snapshot(), to: id) }
        let now = Date()
        for item in items where item.status == .failed {
            if let at = item.retryAt, at <= now { resume(item.id) }
        }
        if dirty { save() }
    }

    private func apply(_ s: Engine.Snapshot, to id: UUID) {
        set(id) { item in
            item.connections = s.connections
            item.rateLimited = s.rateLimited ? true : nil
            item.status = s.phase == .merging ? .merging : .downloading
            item.piecesDone = s.piecesDone
            item.piecesTotal = s.piecesTotal
            item.bytesDone = s.bytesDone
            item.totalBytes = s.totalBytes
            item.speed = s.phase == .downloading ? s.bytesPerSecond : 0
        }
        if let map = s.map, s.phase == .downloading, maps[id] != map { maps[id] = map }
    }

    fileprivate func set(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        changed()
    }

    private func changed() {
        dirty = true
        updateBadge()
    }

    private func updateBadge() {
        let n = items.filter { $0.isActive || $0.status == .queued }.count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// Called on quit: count the time of running downloads up to now.
    func stopClocks() {
        for i in items.indices where items[i].runningSince != nil { items[i].stopClock() }
        dirty = true
    }

    func save() {
        dirty = false
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: store, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    }
}
