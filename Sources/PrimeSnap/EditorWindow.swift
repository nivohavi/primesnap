import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
enum WindowPresenter {
    /// macOS 14+ activation is cooperative: a background/accessory app can't just steal focus.
    /// Float above everything until the window actually becomes key, so it's visible even if macOS
    /// declines to activate us (the app you were in keeps focus after screencapture exits).
    static func bringToFront(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace) // open on the Space you're on
        window.level = .floating
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                window.level = .normal
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        window.orderFrontRegardless()
        window.makeKey()
        // The deprecated variant still forces activation on macOS 14+; without it macOS sometimes leaves
        // the previous app active, so ⌘C goes to that app instead of the editor.
        NSApp.activate(ignoringOtherApps: true)
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard window.isVisible, !window.isKeyWindow || !NSApp.isActive else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private final class EditorWindow: NSWindow {
    var onEscape: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        performClose(sender) // Esc with nothing selected closes
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window is hidden (it's kept around, so reopening is instant).
    var onHide: (() -> Void)?
    let workspace: Workspace
    private var keyMonitor: Any?
    private var positioned = false
    private var model: EditorModel? { workspace.editor }

    init(workspace: Workspace) {
        self.workspace = workspace
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 840),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "PrimeSnap"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PrimeSnapEditor")
        positioned = window.setFrameUsingName("PrimeSnapEditor")
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak workspace] in workspace?.editor?.handleEscape() ?? false }
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        workspace.window = window
        workspace.onHide = { [weak self] in self?.hide() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isShown: Bool { window?.isVisible ?? false }

    func present() {
        guard let window else { return }
        if !positioned {
            window.center()
            positioned = true
        }
        workspace.ensureSomethingOpen()
        WindowPresenter.bringToFront(window)
        // SwiftUI may auto-focus the first text field (watermark); start with no field focused so editor keys work.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    func hide() {
        workspace.persistCurrent()
        window?.orderOut(nil)
        onHide?()
    }

    /// Close button / ⌘W / Esc hide the window instead of destroying it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Editor shortcuts. Ignored while typing in a text field so ⌘C/⌘Z/digits behave normally there.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, let model else { return event }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if let textView = window?.firstResponder as? NSTextView {
            // A focused text field keeps its own keys, except ⌘C/⌘S with no text selected:
            // those still copy/save the image instead of silently doing nothing.
            guard flags == [.command], textView.selectedRange().length == 0, key == "c" || key == "s" else { return event }
            if model.isEditingText { return event }
            window?.makeFirstResponder(nil)
        }

        if flags == [.command] {
            switch key {
            case "c": model.copy()
            case "s": model.quickSave()
            case "z": model.undo()
            case "0": model.zoom = .fit
            case "1": model.zoom = .p100
            case "=", "+": model.zoom = model.zoom.zoomedIn
            case "-": model.zoom = model.zoom.zoomedOut
            case "\\": workspace.sidebarVisible.toggle()
            default: return event
            }
            return nil
        }
        if flags == [.command, .shift] {
            switch key {
            case "s": model.saveAs()
            case "z": model.redo()
            default: return event
            }
            return nil
        }
        guard flags.isEmpty || flags == [.shift] else { return event }

        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            return model.deleteSelected() ? nil : event
        case kVK_Return:
            return model.editSelectedText() ? nil : event
        default:
            if flags.isEmpty, let tool = Tool.forKey(key) {
                model.tool = tool
                return nil
            }
            return event
        }
    }
}
