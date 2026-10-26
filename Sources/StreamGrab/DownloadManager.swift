import AppKit
import Combine

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

    static let connectionChoices = [1, 2, 4, 8, 12, 16]

    private init() {
        folder = d.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Older versions allowed any number; snap to one of the choices the Settings menu offers.
        let saved = d.object(forKey: "connections") as? Int ?? 8
        connections = Self.connectionChoices.min { abs($0 - saved) < abs($1 - saved) } ?? 8
        simultaneous = d.object(forKey: "simultaneous") as? Int ?? 3
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
    private var dirty = false
    private let store = Paths.support.appendingPathComponent("downloads.json")
    private let settings = Settings.shared

    private init() {
        if let data = try? Data(contentsOf: store),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved.map { item in
                var item = item
                if item.isActive || item.status == .queued { item.status = .paused }
                item.runningSince = nil // time before an unexpected exit can't be known
                item.speed = 0
                return item
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in DownloadManager.shared.tick() }
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
        set(id) { $0.status = .queued; $0.error = nil; $0.note = nil }
        schedule()
    }

    /// Cancels (if running), forgets the download, and deletes its pieces. A finished video in the
    /// download folder is kept: removing a finished item only clears it from the list.
    func remove(_ id: UUID) {
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
        items.removeAll { $0.status == .completed }
        changed()
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
                item.file = file
                item.note = note
                item.job.headers = [:] // don't keep cookies around once they're no longer needed
                item.totalBytes = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? item.bytesDone
                item.bytesDone = item.totalBytes ?? item.bytesDone
            } else {
                item.status = .failed
                item.error = (error as NSError?).map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
            }
        }
        if file != nil { try? FileManager.default.removeItem(at: workDir(id)) }
        if file != nil { maps[id] = nil } else { maps[id]?.runs.removeAll { $0.active } }
        if file != nil { NSApp.requestUserAttention(.informationalRequest) }
        schedule()
    }

    private func tick() {
        for (id, entry) in engines { apply(entry.engine.snapshot(), to: id) }
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

    private func set(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
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
