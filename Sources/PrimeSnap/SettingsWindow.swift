import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Window

/// Standard macOS settings window: icon tabs in the toolbar, each tab sized to its content.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.frame(width: 520).fixedSize(horizontal: false, vertical: true))
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", GeneralSettings())
        add("Shortcuts", "keyboard", ShortcutSettings(settings: .shared))
        add("Capture", "camera.viewfinder", CaptureSettings())
        add("History", "clock.arrow.circlepath", HistorySettings(history: .shared))
        add("About", "info.circle", AboutSettings())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        WindowPresenter.bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.afterCapture) private var afterCapture = Prefs.AfterCapture.editor.rawValue
    @AppStorage(Prefs.Key.playSounds) private var playSounds = true
    @AppStorage(Prefs.Key.saveFolder) private var saveFolder = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var autoRedact = Style.load().autoRedact

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Play sounds", isOn: $playSounds)
            }

            Section {
                Picker("After taking a screenshot", selection: $afterCapture) {
                    ForEach(Prefs.AfterCapture.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Redact sensitive data automatically", isOn: $autoRedact)
                    .onChange(of: autoRedact) { _, on in
                        var style = Style.load()
                        style.autoRedact = on
                        style.save()
                    }
            } footer: {
                Text(afterCapture == Prefs.AfterCapture.copy.rawValue
                     ? "The framed image goes straight to the clipboard and into Recent Captures. Open it from the menu bar to edit."
                     : "Redaction reads the text in each screenshot on your Mac to hide emails, keys and tokens. It can take a moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Save with ⌘S to") {
                    HStack(spacing: 8) {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .help(folder.path)
                        Button("Choose…", action: chooseFolder)
                        if !saveFolder.isEmpty {
                            Button("Reset") { saveFolder = "" }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var folder: URL { saveFolder.isEmpty ? Prefs.defaultSaveFolder : URL(fileURLWithPath: saveFolder) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(shortcut: settings.binding(for: action), settings: settings)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                HStack(alignment: .top) {
                    Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ turns it off. Use ⌘, ⌃ or ⌥ (F-keys work alone).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { settings.resetToDefaults() }
                        .controlSize(.small)
                }
            }

            Section("In the editor") {
                ForEach(Self.editorKeys, id: \.0) { key, what in
                    LabeledContent(what) {
                        Text(key).font(.system(.body, design: .rounded).weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private static let editorKeys: [(String, String)] = [
        ("⌘C", "Copy image"),
        ("⌘S  ·  ⇧⌘S", "Save  ·  Save As"),
        ("V  1–5", "Select  ·  Text, Arrow, Redact, Box, Highlight"),
        ("⌘Z  ·  ⇧⌘Z", "Undo  ·  Redo"),
        ("⌘0  ⌘1  ⌘+  ⌘−", "Zoom to fit, 100%, in, out"),
        ("⌘\\", "Show or hide recent captures"),
        ("Esc", "Deselect, then hide the window"),
    ]
}

// MARK: - Capture

private struct CaptureSettings: View {
    @AppStorage(Prefs.Key.windowShadow) private var windowShadow = false
    @AppStorage(Prefs.Key.showCursor) private var showCursor = false
    @AppStorage(Prefs.Key.screenDelay) private var screenDelay = 0

    var body: some View {
        Form {
            Section("Window") {
                Toggle("Include the macOS window shadow", isOn: $windowShadow)
                Text("Off gives a clean edge, and PrimeSnap draws its own shadow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Full screen") {
                Picker("Delay", selection: $screenDelay) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Show the mouse pointer", isOn: $showCursor)
            }
            Section {
                LabeledContent("Screen Recording") {
                    HStack(spacing: 8) {
                        if CGPreflightScreenCaptureAccess() {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Not allowed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Button("Open Privacy Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - History

private struct HistorySettings: View {
    @ObservedObject var history: HistoryStore
    @AppStorage(Prefs.Key.historyLimit) private var limit = 50
    @State private var usage: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Keep the last") {
                    HStack(spacing: 6) {
                        TextField("", value: $limit, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .labelsHidden()
                        Stepper("", value: $limit, in: Prefs.historyLimitRange, step: 5)
                            .labelsHidden()
                        Text("captures")
                    }
                }
                .onChange(of: limit) { _, new in
                    let clamped = min(max(new, Prefs.historyLimitRange.lowerBound), Prefs.historyLimitRange.upperBound)
                    if clamped != new { limit = clamped }
                }
                LabeledContent("Saved now") {
                    Text("\(history.items.count) captures · \(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))")
                }
            } footer: {
                Text("Between 5 and 1,000. When you go over the limit, the oldest captures are deleted at your next screenshot. Captures and their edits stay on this Mac only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.folder]) }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(history.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear(perform: refresh)
        .onChange(of: history.items.count) { _, _ in refresh() }
        .alert("Clear capture history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                history.clear(keeping: nil)
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every saved capture and its edits. This can't be undone.")
        }
    }

    private func refresh() { usage = history.diskUsage() }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty || b == v ? v : "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("PrimeSnap").font(.title2.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Frame, annotate and redact screenshots.\nEverything stays on your Mac: no account, no network.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
