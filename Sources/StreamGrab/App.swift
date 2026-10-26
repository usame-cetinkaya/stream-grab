import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Chrome launches this same executable as its native-messaging host.
        if NativeHost.isHostLaunch(CommandLine.arguments) { NativeHost.run() }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Setup.run()
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "StreamGrab"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView())
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        _ = DownloadManager.shared

        IPC.serve { message in
            let sema = DispatchSemaphore(value: 0)
            let box = Box()
            Task { @MainActor in
                box.value = AppDelegate.handle(message)
                sema.signal()
            }
            sema.wait()
            return box.value
        }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["STREAMGRAB_SNAPSHOT"] { snapshot(window, to: path) }
        if let path = ProcessInfo.processInfo.environment["STREAMGRAB_SNAPSHOT_SETTINGS"] {
            showSettings()
            snapshot(settingsWindow!, to: path)
        }
        #endif
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "StreamGrab Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() { showSettings() }

    #if DEBUG
    /// Debug builds: render a window to a PNG (for checking the UI without screen-recording access).
    private func snapshot(_ target: NSWindow, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let view = target.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    private final class Box: @unchecked Sendable { var value: [String: Any] = [:] }

    /// Requests forwarded from the browser extension by the native-messaging host.
    static func handle(_ message: [String: Any]) -> [String: Any] {
        let delegate = NSApp.delegate as? AppDelegate
        switch message["type"] as? String {
        case "download":
            guard let raw = message["job"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let job = try? JSONDecoder().decode(Job.self, from: data) else {
                return ["ok": false, "error": "Malformed download request"]
            }
            let item = DownloadManager.shared.add(job)
            delegate?.showWindow(activate: false)
            var reply: [String: Any] = ["ok": true, "id": item.id.uuidString]
            if job.mayNeedMerge, Paths.ffmpeg == nil {
                reply["warning"] = "ffmpeg isn't installed, so the sound will be saved as a separate file."
            }
            return reply
        case "show":
            delegate?.showWindow(activate: true)
            return ["ok": true]
        case "ping":
            return ["ok": true]
        default:
            return ["ok": false, "error": "Unknown request"]
        }
    }

    func showWindow(activate: Bool) {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if !window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil)
            window.orderFrontRegardless()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(activate: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = DownloadManager.shared.items.filter { $0.isActive || $0.status == .queued }.count
        if active > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit while \(active) download\(active == 1 ? " is" : "s are") running?"
            alert.informativeText = "They'll be paused and can be resumed next time."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        DownloadManager.shared.save()
        return .terminateNow
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("StreamGrab", [
            item("About StreamGrab", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(openSettings), ","),
            .separator(),
            item("Hide StreamGrab", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit StreamGrab", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Downloads", #selector(showMain), "0"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func showMain() { showWindow(activate: true) }
}
