import AppKit

/// Wires the app to Chromium-based browsers. Runs on every launch so the
/// native-messaging manifest always points at wherever the app currently lives.
enum Setup {
    /// Browser profile roots (under ~/Library/Application Support) that read NativeMessagingHosts.
    private static let browsers = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]

    static func run() {
        installHostManifests()
        installExtensionFolder()
    }

    static func installHostManifests() {
        guard let exe = Bundle.main.executableURL?.path else { return }
        let manifest: [String: Any] = [
            "name": Paths.hostName,
            "description": "StreamGrab video downloader",
            "path": exe,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Paths.extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for browser in browsers {
            let root = appSupport.appendingPathComponent(browser)
            guard fm.fileExists(atPath: root.path) else { continue }
            let dir = root.appendingPathComponent("NativeMessagingHosts")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(Paths.hostName).json"))
        }
    }

    /// Chrome needs an unpacked extension to stay put, so keep a copy outside the app bundle.
    static func installExtensionFolder() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Extension"),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        let target = Paths.installedExtension
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: bundled, to: target)
    }

    static func revealExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.installedExtension])
    }

    static func openExtensionsPage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("chrome://extensions", forType: .string)
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = FileManager.default.fileExists(atPath: chrome.path)
            ? ["-a", chrome.path, "chrome://extensions"] : []
        if !(p.arguments ?? []).isEmpty { try? p.run() }
    }
}
