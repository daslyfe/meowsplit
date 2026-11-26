import AppKit
import UniformTypeIdentifiers
import WebKit

/// Settings shared by the Finder flow and the settings window.
enum Settings {
    static let defaults = UserDefaults.standard
    static var odd: OddChannel { OddChannel(rawValue: defaults.string(forKey: "oddChannel") ?? "") ?? .mono }
    static var reveal: Bool { defaults.object(forKey: "revealFolder") as? Bool ?? true }

    static var json: String {
        let obj: [String: Any] = [
            "oddChannel": odd.rawValue,
            "revealFolder": reveal,
            "colours": defaults.dictionary(forKey: "colours") ?? [:],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ obj: [String: Any]) {
        if let v = obj["oddChannel"] as? String, OddChannel(rawValue: v) != nil { defaults.set(v, forKey: "oddChannel") }
        if let v = obj["revealFolder"] as? Bool { defaults.set(v, forKey: "revealFolder") }
        if let v = obj["colours"] as? [String: String] { defaults.set(v, forKey: "colours") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var queue: [URL] = []
    var working = false
    var gotFiles = false
    var finished: [URL] = []
    var window: NSWindow?
    var web: WKWebView?

    /// Shows a status line in the settings window, when it is open.
    func status(_ text: String) {
        guard let web, let data = try? JSONSerialization.data(withJSONObject: [text]) else { return }
        web.evaluateJavaScript("window.meowStatus && window.meowStatus(\(String(decoding: data, as: UTF8.self))[0])")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        // Files opened from Finder arrive just after launch; if none do, the app was opened on its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !self.gotFiles { self.showSettings() }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        gotFiles = true
        queue.append(contentsOf: urls)
        pump()
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showSettings() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { !working }

    // MARK: splitting

    func pump() {
        guard !working else { return }
        guard !queue.isEmpty else { finish(); return }
        working = true
        let url = queue.removeFirst()
        let odd = Settings.odd
        let left = queue.count
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Splitter.split(url, odd: odd) { p in
                DispatchQueue.main.async {
                    NSApp.dockTile.badgeLabel = "\(Int(p * 100))%" + (left > 0 ? "+\(left)" : "")
                    self.status("> SPLITTING \(url.lastPathComponent) \(Int(p * 100))%")
                }
            } }
            DispatchQueue.main.async {
                NSApp.dockTile.badgeLabel = nil
                switch result {
                case .success(let folder):
                    self.finished.append(folder)
                    self.status("> DONE: \(folder.lastPathComponent)/")
                case .failure(let error):
                    self.status("! \(error.localizedDescription)")
                    if self.window?.isVisible != true { self.alert(url, error.localizedDescription) }
                }
                self.working = false
                self.pump()
            }
        }
    }

    func finish() {
        if !finished.isEmpty, Settings.reveal {
            NSWorkspace.shared.activateFileViewerSelecting(finished)
        }
        finished.removeAll()
        if window?.isVisible != true { NSApp.terminate(nil) }
    }

    func alert(_ url: URL, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "! \(message)"
        a.informativeText = url.lastPathComponent
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: settings window

    func showSettings() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "meow")
        // Apply saved colours before the first paint.
        let boot = """
        window.MEOW_SETTINGS = \(Settings.json);
        (function () {
          var c = window.MEOW_SETTINGS.colours || {};
          for (var k in c) document.documentElement.style.setProperty('--' + k, c[k]);
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = DropWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.onDrop = { [weak self] urls in self?.application(NSApp, open: urls) }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "MEOW SPLIT"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.minSize = NSSize(width: 420, height: 360)
        w.contentView = web
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("MeowSplitSettings")

        let ui = Bundle.main.resourceURL!.appendingPathComponent("ui")
        web.loadFileURL(ui.appendingPathComponent("index.html"), allowingReadAccessTo: ui)
        window = w
        self.web = web
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "save":
            if let s = body["settings"] as? [String: Any] { Settings.save(s) }
        case "open":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType.wav]
            panel.allowsMultipleSelection = true
            panel.beginSheetModal(for: window!) { r in
                if r == .OK { self.application(NSApp, open: panel.urls) }
            }
        default:
            break
        }
    }

    // MARK: menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MEOW SPLIT", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MEOW SPLIT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    @objc func openSettings() { showSettings() }
}

/// Accepts WAV files dropped on the settings window.
final class DropWebView: WKWebView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wavs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["wav", "wave"].contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { wavs(info).isEmpty ? [] : .copy }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { wavs(info).isEmpty ? [] : .copy }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let u = wavs(info)
        if !u.isEmpty { onDrop?(u) }
        return !u.isEmpty
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
