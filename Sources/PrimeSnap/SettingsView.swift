import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(label)
                    .font(.system(.body, design: .rounded).weight(shortcut == nil || recording ? .regular : .medium))
                    .foregroundStyle(recording || shortcut == nil ? .secondary : .primary)
                    .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)

            Button {
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(shortcut != nil && !recording ? 1 : 0)
            .disabled(shortcut == nil || recording)
            .help("Disable shortcut")
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return "Type shortcut…" }
        return shortcut?.display ?? "None"
    }

    private func start() {
        guard !settings.isRecording else { return } // one recorder at a time
        recording = true
        settings.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                shortcut = nil
                stop()
            default:
                if let new = Shortcut(event: event) {
                    shortcut = new
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil // swallow the key while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            settings.isRecording = false
        }
    }
}

