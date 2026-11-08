import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private lazy var editor: EditorWindowController = {
        let controller = EditorWindowController(workspace: Workspace())
        controller.onHide = { [weak self] in self?.updateActivationPolicy() }
        return controller
    }()
    private var editorShown = false
    private var settingsController: SettingsWindowController?
    private var settingsOpen = false
    private var captureItems: [CaptureAction: NSMenuItem] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PrimeSnap")
        statusItem.menu = buildStatusMenu()

        NSApp.mainMenu = buildMainMenu() // only visible while we're a regular (Dock) app

        // Re-register whenever shortcuts change; drop them entirely while a recorder is listening.
        settings.$shortcuts.combineLatest(settings.$isRecording)
            .sink { [weak self] shortcuts, recording in
                self?.registerHotKeys(recording ? [:] : shortcuts)
            }
            .store(in: &cancellables)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Hotkeys

    private func registerHotKeys(_ shortcuts: [CaptureAction: Shortcut]) {
        hotKeys = [] // unregister first: Carbon refuses a combo that's still registered
        hotKeys = CaptureAction.allCases.compactMap { action in
            guard let shortcut = shortcuts[action] else { return nil }
            return HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, id: action.hotKeyID) { [weak self] in
                self?.capture(action.mode)
            }
        }
    }

    // MARK: Menus

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for action in CaptureAction.allCases {
            let mi = NSMenuItem(title: action.title, action: #selector(captureFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = action.rawValue
            captureItems[action] = mi
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(item("Recent Captures", #selector(showEditor)))
        menu.addItem(item("Edit Clipboard Image", #selector(editClipboard)))
        menu.addItem(item("Open Image…", #selector(openImage)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit PrimeSnap", #selector(quit), key: "q"))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (action, mi) in captureItems {
            let shortcut = settings.shortcuts[action]
            if let shortcut, let key = shortcut.menuKeyEquivalent {
                mi.title = action.title
                mi.keyEquivalent = key
                mi.keyEquivalentModifierMask = shortcut.eventModifiers
            } else {
                mi.title = shortcut.map { "\(action.title)    \($0.display)" } ?? action.title
                mi.keyEquivalent = ""
                mi.keyEquivalentModifierMask = []
            }
        }
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PrimeSnap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PrimeSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    /// primesnap://settings, primesnap://capture/area|window|screen, primesnap://clipboard
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "primesnap" {
            switch url.host {
            case "settings": openSettings()
            case "clipboard": editClipboard()
            case "capture":
                let name = url.pathComponents.dropFirst().first ?? "area"
                if let action = CaptureAction(rawValue: name) { capture(action.mode) }
            default: break
            }
        }
    }

    // MARK: Dock presence

    /// Dock icon only while one of our windows is open.
    private func updateActivationPolicy() {
        editorShown = editor.isShown
        let wantsDock = editorShown || settingsOpen
        let target: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if wantsDock { NSApp.activate(ignoringOtherApps: true) } // makes the Dock tile appear immediately
    }

    /// Clicking the Dock icon brings our windows back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if editorShown || !settingsOpen { showEditor() }
        if settingsOpen { settingsController?.window?.makeKeyAndOrderFront(nil) }
        return false
    }

    // MARK: Actions

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CaptureAction(rawValue: raw) else { return }
        capture(action.mode)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showPermissionAlert() {
        CGRequestScreenCaptureAccess() // makes sure PrimeSnap is listed in System Settings
        let alert = NSAlert()
        alert.messageText = "PrimeSnap needs Screen Recording"
        alert.informativeText = """
        Turn on PrimeSnap in System Settings → Privacy & Security → Screen & System Audio Recording.

        If it's already on, PrimeSnap just needs a relaunch for macOS to apply it.
        """
        alert.addButton(withTitle: "Relaunch PrimeSnap")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.level = .floating
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onClose = { [weak self] in
                self?.settingsOpen = false
                self?.updateActivationPolicy()
            }
            settingsController = controller
        }
        settingsOpen = true
        updateActivationPolicy()
        settingsController?.present()
    }

    @objc private func editClipboard() {
        guard let img = NSImage(pasteboard: .general), let loaded = LoadedImage(nsImage: img) else {
            NSSound.beep()
            return
        }
        openEditor(loaded, title: "Clipboard image")
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let loaded = LoadedImage(url: url) else { return }
        openEditor(loaded, title: url.deletingPathExtension().lastPathComponent)
    }

    private func capture(_ mode: CaptureMode) {
        // Without an *active* grant, screencapture silently returns a black/wallpaper-only image.
        // The grant only takes effect after a relaunch, and this process checks its own state here.
        guard CGPreflightScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }
        Capture.run(mode) { [weak self] loaded in
            guard let loaded else { return }
            guard let self else { return }
            if Prefs.afterCapture == .copy {
                // Quick mode: frame + copy without showing the editor; it's still in Recent Captures.
                editor.workspace.open(loaded, title: mode.title)
                editor.workspace.editor?.copy()
            } else {
                openEditor(loaded, title: mode.title)
            }
        }
    }

    private func openEditor(_ loaded: LoadedImage, title: String) {
        editor.workspace.open(loaded, title: title)
        showEditor()
    }

    @objc private func showEditor() {
        editor.present()
        updateActivationPolicy()
    }
}
