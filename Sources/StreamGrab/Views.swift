import SwiftUI

/// View-local state. (`@State` is a macro in recent SDKs, which Command Line Tools can't expand.)
final class MainViewState: ObservableObject {
    @Published var newURL = ""
}

struct MainView: View {
    @ObservedObject var manager = DownloadManager.shared
    @StateObject private var state = MainViewState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Paste a video, .m3u8 or .mpd link…", text: $state.newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addURL)
                Button("Download", action: addURL).disabled(URL(string: state.newURL)?.scheme?.hasPrefix("http") != true)
                Divider().frame(height: 18)
                Button { NSWorkspace.shared.open(Settings.shared.folder) } label: { Image(systemName: "folder") }
                    .help("Open download folder")
                Button { manager.clearFinished() } label: { Image(systemName: "checkmark.circle.badge.xmark") }
                    .help("Clear finished downloads")
                    .disabled(!manager.items.contains { $0.status == .completed })
                Button { (NSApp.delegate as? AppDelegate)?.showSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
            .padding(10)
            Divider()
            if manager.items.isEmpty {
                SetupGuide()
            } else {
                List(manager.items) { item in
                    DownloadRow(item: item)
                        .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    private func addURL() {
        let s = state.newURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return }
        let ext = url.pathExtension.lowercased()
        let kind: Job.Kind = ext == "m3u8" || s.contains(".m3u8") ? .hls : ext == "mpd" || s.contains(".mpd") ? .dash : .direct
        let name = url.deletingPathExtension().lastPathComponent
        manager.add(Job(kind: kind, url: s, title: name.isEmpty ? url.host ?? "video" : name))
        state.newURL = ""
    }
}

/// A whole number of megabytes edited as text, applied on every keystroke (digits only), so a
/// button pressed right after typing sees the new value.
func megabytes(_ value: Binding<Int>) -> Binding<String> {
    Binding(get: { String(value.wrappedValue) },
            set: { text in
                let digits = text.filter(\.isNumber).prefix(7)
                if let n = Int(digits) { value.wrappedValue = max(1, n) }
            })
}

/// The Convert… panel's choices for one download.
final class ConvertForm: ObservableObject {
    @Published var shown = false
    @Published var height = Settings.shared.convertHeight
    @Published var maxMB = Settings.shared.convertMaxMB
    @Published var format = Settings.shared.convertFormat
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var manager = DownloadManager.shared
    @StateObject private var form = ConvertForm()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.job.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let q = item.job.quality, !q.isEmpty {
                        Text(q).font(.caption.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if item.status != .completed && item.status != .failed {
                    if let map = manager.maps[item.id], item.status == .downloading || item.status == .paused {
                        PieceBar(map: map, connections: map.runs.filter(\.active).count)
                    } else if let f = item.fraction, item.status != .merging {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary).lineLimit(2)
                    if item.status == .failed, let at = item.retryAt {
                        // Re-rendered every second for the countdown.
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Self.retryText(at: at, now: ctx.date, attempt: item.autoRetries ?? 1))
                                .font(.caption).foregroundStyle(.orange).monospacedDigit()
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 4)
                    if showsConnections { connectionControl }
                }
                if let note = item.note {
                    Label(note, systemImage: "speaker.slash")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.conversions ?? []) { c in ConversionLine(item: item.id, conversion: c) }
            }
            Spacer(minLength: 8)
            buttons
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.status == .completed { manager.open(item.id) } }
        .contextMenu {
            if let page = item.job.pageURL, let url = URL(string: page) {
                Button("Open Web Page") { NSWorkspace.shared.open(url) }
            }
            Button("Copy Media Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.job.url, forType: .string)
            }
            Divider()
            Button("Remove from List") { manager.remove(item.id) }
        }
    }

    /// Only where more than one connection can help: not finished, and more than one piece.
    private var showsConnections: Bool {
        [.downloading, .queued, .paused].contains(item.status) && (item.piecesTotal != 1)
    }

    private var connectionControl: some View {
        let n = manager.connections(of: item)
        return HStack(spacing: 2) {
            if item.rateLimited == true {
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(.orange)
                    .help("The server answered “Too many requests” (HTTP 429), so StreamGrab lowered the connections for this download.")
            }
            Button { manager.setConnections(item.id, n - 1) } label: { Image(systemName: "minus") }
                .disabled(n <= 1)
                .help("Fewer connections")
            Text("\(n) \(n == 1 ? "connection" : "connections")")
                .monospacedDigit()
                .frame(minWidth: 82)
            Button { manager.setConnections(item.id, n + 1) } label: { Image(systemName: "plus") }
                .disabled(n >= Engine.maxConnections)
                .help("More connections")
        }
        .font(.caption)
        .foregroundStyle(item.rateLimited == true ? .orange : .secondary)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .downloading, .queued:
                iconButton("pause.fill", "Pause") { manager.pause(item.id) }
            case .paused:
                iconButton("play.fill", "Resume") { manager.resume(item.id) }
            case .failed:
                iconButton("arrow.clockwise", item.retryAt == nil ? "Retry" : "Retry now") { manager.retryNow(item.id) }
                if item.retryAt != nil {
                    iconButton("pause.fill", "Stop retrying automatically") { manager.stopRetrying(item.id) }
                }
            case .completed:
                iconButton("play.rectangle", "Open") { manager.open(item.id) }
                iconButton("magnifyingglass", "Show in Finder") { manager.reveal(item.id) }
                if Paths.ffmpeg != nil {
                    iconButton("arrow.triangle.2.circlepath", "Convert…") {
                        // Start from the global choices each time the panel opens.
                        form.height = Settings.shared.convertHeight
                        form.maxMB = Settings.shared.convertMaxMB
                        form.format = Settings.shared.convertFormat
                        form.shown = true
                    }
                    .popover(isPresented: $form.shown, arrowEdge: .bottom) {
                        ConvertPanel(form: form) {
                            form.shown = false
                            manager.convert(item.id, format: form.format, height: form.height, maxMB: form.maxMB)
                        }
                    }
                }
            case .merging:
                EmptyView()
            }
            iconButton("xmark", item.status == .completed ? "Remove from list" : "Cancel and remove") { manager.remove(item.id) }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }.help(help)
    }

    private var icon: String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .failed: item.retryAt == nil ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle.fill"
        case .paused: "pause.circle.fill"
        case .queued: "clock.fill"
        case .downloading, .merging: "arrow.down.circle.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .completed: .green
        case .failed: item.retryAt == nil ? .red : .orange
        case .paused, .queued: .secondary
        case .downloading, .merging: .accentColor
        }
    }

    /// "Retrying in 0:25 (try 2 of 8)"
    static func retryText(at: Date, now: Date, attempt: Int) -> String {
        let secs = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
        let when = secs == 0 ? "Retrying…" : "Retrying in \(secs / 60):\(String(format: "%02d", secs % 60))"
        return "\(when) (try \(attempt) of \(RetryPolicy.maxAttempts))"
    }

    /// "under 1s", "12s", "1m 12s", "1h 5m"
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "under 1s" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds.rounded()) ?? "\(Int(seconds))s"
    }

    private var detail: String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch item.status {
        case .completed:
            var took: String?
            var average: String?
            if let t = item.elapsed {
                took = "took \(Self.duration(t))"
                if t >= 1, let total = item.totalBytes { average = "\(size(Int64(Double(total) / t)))/s" }
            }
            return [item.totalBytes.map(size), took, average, item.file?.lastPathComponent].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return item.error ?? "Failed"
        case .merging:
            return "Joining pieces into the final file…"
        case .queued:
            return "Waiting…"
        case .paused, .downloading:
            var parts: [String] = []
            if let f = item.fraction { parts.append("\(Int(f * 100))%") }
            let approx = item.job.kind != .direct ? "~" : ""
            if let t = item.totalBytes { parts.append("\(size(item.bytesDone)) of \(approx)\(size(t))") }
            else if item.bytesDone > 0 { parts.append(size(item.bytesDone)) }
            if item.job.kind != .direct, item.piecesTotal > 0 { parts.append("\(item.piecesDone)/\(item.piecesTotal) segments") }
            if item.status == .paused { parts.append("Paused") }
            else if item.speed > 0 {
                parts.append("\(size(Int64(item.speed)))/s")
                if let t = item.totalBytes, t > item.bytesDone {
                    let secs = Double(t - item.bytesDone) / item.speed
                    let f = DateComponentsFormatter()
                    f.allowedUnits = secs >= 3600 ? [.hour, .minute] : [.minute, .second]
                    f.unitsStyle = .abbreviated
                    if let s = f.string(from: secs) { parts.append("\(s) left") }
                }
            } else if item.piecesTotal == 0 {
                parts.append("Starting…")
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Resolution, size and format for converting one download.
struct ConvertPanel: View {
    @ObservedObject var form: ConvertForm
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert a Copy").font(.headline)
            Form {
                Picker("Resolution", selection: $form.height) {
                    ForEach(Settings.convertHeights, id: \.self) { Text("\($0)p").tag($0) }
                }
                LabeledContent("Maximum size") {
                    HStack(spacing: 6) {
                        TextField("Maximum size", text: megabytes($form.maxMB))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                Picker("Format", selection: $form.format) {
                    ForEach(ConversionFormat.available, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Text("The original is kept. These choices apply to this download only.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Convert", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.maxMB < 1)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// One converted copy's status under a finished download.
struct ConversionLine: View {
    let item: UUID
    let conversion: Conversion
    @ObservedObject var manager = DownloadManager.shared

    var body: some View {
        let c = conversion
        let target = "\(c.label), up to \(c.maxMB) MB"
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                switch c.state {
                case .waiting:
                    Label("Waiting to convert to \(target)", systemImage: "clock").foregroundStyle(.secondary)
                case .running:
                    let pct = Int((c.progress ?? 0) * 100)
                    Label("\(c.stage ?? "Converting") to \(target) · \(pct)%", systemImage: "gearshape.2").foregroundStyle(.secondary)
                case .done:
                    let size = c.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                    let how = switch c.mode {
                    case .copy: "original quality, copied"
                    case .quality: "original quality"
                    case .fitted: "sized to fit \(c.maxMB) MB"
                    case nil: ""
                    }
                    let took = c.elapsed.map { " · took \(DownloadRow.duration($0))" } ?? ""
                    Label("\(c.label) copy: \(size) (\(how))\(took)", systemImage: "checkmark.circle").foregroundStyle(.green)
                        .help(c.file?.lastPathComponent ?? "")
                case .failed:
                    Label("\(c.label): \(c.error ?? "Conversion failed")", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Group {
                    switch c.state {
                    case .waiting, .running:
                        Button { manager.cancelConversion(item, c.id) } label: { Image(systemName: "xmark.circle") }
                            .help("Cancel this conversion (the original is kept)")
                    case .done:
                        Button { manager.openConverted(item, c.id) } label: { Image(systemName: "play.rectangle") }
                            .help("Open the converted copy")
                        Button { manager.revealConverted(item, c.id) } label: { Image(systemName: "magnifyingglass") }
                            .help("Show the converted copy in Finder")
                        Button { manager.dismissConversion(item, c.id) } label: { Image(systemName: "xmark") }
                            .help("Remove from the list (the file is kept)")
                    case .failed:
                        Button { manager.retryConversion(item, c.id) } label: { Image(systemName: "arrow.clockwise") }
                            .help("Try converting again")
                        Button { manager.dismissConversion(item, c.id) } label: { Image(systemName: "xmark") }
                            .help("Remove from the list")
                    }
                }
                .buttonStyle(.borderless)
            }
            if c.state == .running { ProgressView(value: c.progress ?? 0).controlSize(.small) }
        }
        .font(.caption)
        .lineLimit(2)
    }
}

/// IDM-style bar: finished parts in the accent colour, and each piece a connection is
/// downloading right now as its own segment that fills up as it arrives.
struct PieceBar: View {
    let map: Engine.PieceMap
    let connections: Int

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: h / 2),
                      with: .color(.secondary.opacity(0.18)))
            ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: h / 2))
            for run in map.runs {
                let x = run.start * size.width
                let w = max(run.length * size.width, run.active ? 2 : 0.5)
                if run.active {
                    // The whole piece this connection owns, faintly, then what has arrived so far.
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: h)), with: .color(Self.active.opacity(0.28)))
                    ctx.fill(Path(CGRect(x: x, y: 0, width: max(w * run.fill, 1), height: h)), with: .color(Self.active))
                    // A divider so neighbouring connections stay distinguishable.
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: h)), with: .color(.black.opacity(0.35)))
                } else {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: h)), with: .color(.accentColor))
                }
            }
        }
        .frame(height: 8)
        .help(connections > 0
              ? "Blue: downloaded. Green: \(connections) piece\(connections == 1 ? "" : "s") being downloaded right now, one per connection."
              : "Blue: downloaded.")
        .accessibilityLabel("Download progress by piece")
    }

    static let active = Color(nsColor: .systemGreen)
}

struct SetupGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect StreamGrab to Chrome").font(.title2.bold())
            Text("Once the extension is installed, a **Download this video** button appears over videos you play while StreamGrab is open. Pick a quality and the download shows up here.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open **chrome://extensions** and turn on **Developer mode** (top right).")
                step(2, "Click **Load unpacked** and choose the **Chrome Extension** folder.")
                step(3, "Reload any page that's already open, then play a video.")
            }
            HStack {
                Button("Open chrome://extensions") { Setup.openExtensionsPage() }
                Button("Show Extension Folder") { Setup.revealExtension() }
            }
            Text("Tip: in the Load unpacked dialog, press ⌘⇧G and paste the folder path:\n\(Paths.installedExtension.path)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.callout.bold()).frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Save videos to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: settings.folder.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: settings.folder.path))
                            .lineLimit(1).truncationMode(.middle)
                            .help(settings.folder.path)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Connections per download", selection: $settings.connections) {
                    ForEach(Settings.connectionChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Downloads at the same time", selection: $settings.simultaneous) {
                    ForEach(1 ... 6, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Retry failed downloads automatically", isOn: $settings.autoRetry)
            } header: {
                Text("Downloads")
            } footer: {
                Text("More connections can speed up large video files on servers that allow it. Downloads that fail because of a network or server problem are retried up to 8 times, waiting longer each time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Convert finished downloads", isOn: $settings.convert)
                    .disabled(Paths.ffmpeg == nil)
                Group {
                    Picker("Resolution", selection: $settings.convertHeight) {
                        ForEach(Settings.convertHeights, id: \.self) { Text("\($0)p").tag($0) }
                    }
                    LabeledContent("Maximum size") {
                        HStack(spacing: 6) {
                            TextField("Maximum size", text: megabytes($settings.convertMaxMB))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("MB").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Format", selection: $settings.convertFormat) {
                        ForEach(ConversionFormat.available, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .disabled(!settings.convert || Paths.ffmpeg == nil)
            } header: {
                Text("After Download")
            } footer: {
                Text(Paths.ffmpeg == nil
                     ? "Needs ffmpeg (see below)."
                     : "When on, every finished download also gets a converted copy next to the original, scaled down to the resolution (never up). If that copy fits the maximum size at the original's quality it's kept as is; only if it doesn't is the quality lowered to fit. With it off, or to make more copies, use the Convert… button on a finished download.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("ffmpeg") {
                    if Paths.ffmpeg != nil {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Video & Sound")
            } footer: {
                Group {
                    if let f = Paths.ffmpeg {
                        Text("Used to merge video and sound into one .mp4 file. Found at \(f.path).")
                    } else {
                        Text("Without ffmpeg, sound that comes as a separate track is saved as a separate file, and some streams are saved as .ts. Install it with Homebrew: brew install ffmpeg")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section {
                LabeledContent("Extensions page") {
                    Button("Open in Chrome") { Setup.openExtensionsPage() }
                }
                LabeledContent("Extension folder") {
                    Button("Show in Finder") { Setup.revealExtension() }
                }
            } header: {
                Text("Chrome Extension")
            } footer: {
                Text("On the extensions page, turn on Developer mode, click Load unpacked, and choose the extension folder. The download button appears on pages while StreamGrab is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 6)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.folder
        if panel.runModal() == .OK, let url = panel.url { settings.folder = url }
    }
}
