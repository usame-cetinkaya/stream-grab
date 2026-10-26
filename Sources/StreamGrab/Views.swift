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

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var manager = DownloadManager.shared

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
                    if let f = item.fraction, item.status != .merging {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary).lineLimit(2)
                if let note = item.note {
                    Label(note, systemImage: "speaker.slash")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
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

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .downloading, .queued:
                iconButton("pause.fill", "Pause") { manager.pause(item.id) }
            case .paused:
                iconButton("play.fill", "Resume") { manager.resume(item.id) }
            case .failed:
                iconButton("arrow.clockwise", "Retry") { manager.resume(item.id) }
            case .completed:
                iconButton("play.rectangle", "Open") { manager.open(item.id) }
                iconButton("magnifyingglass", "Show in Finder") { manager.reveal(item.id) }
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
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .queued: "clock.fill"
        case .downloading, .merging: "arrow.down.circle.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .completed: .green
        case .failed: .red
        case .paused, .queued: .secondary
        case .downloading, .merging: .accentColor
        }
    }

    private var detail: String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch item.status {
        case .completed:
            return [item.totalBytes.map(size), item.file?.lastPathComponent].compactMap { $0 }.joined(separator: " · ")
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
            } header: {
                Text("Downloads")
            } footer: {
                Text("More connections can speed up large video files on servers that allow it.")
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
