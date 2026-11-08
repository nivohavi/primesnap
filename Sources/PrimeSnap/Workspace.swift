import AppKit
import Combine
import SwiftUI

/// The single editor window's state: which capture is open, plus the history sidebar.
@MainActor
final class Workspace: ObservableObject {
    let history = HistoryStore.shared
    @Published private(set) var editor: EditorModel?
    @Published private(set) var currentID: UUID?
    @Published var sidebarVisible: Bool = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }

    weak var window: NSWindow?
    /// Hide the window (Esc, close button, double-click copy & close).
    var onHide: (() -> Void)?

    private var saveCancellable: AnyCancellable?
    private var loadToken = UUID()

    /// A new capture: goes to the top of the sidebar and opens right away.
    func open(_ loaded: LoadedImage, title: String) {
        persistCurrent()
        let item = history.add(loaded, title: title)
        show(EditorModel(image: loaded.image, scale: loaded.scale), id: item.id)
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        persistCurrent()
        let token = UUID()
        loadToken = token
        Task {
            guard let loaded = await history.loadImage(id), loadToken == token else {
                if loadToken == token { NSSound.beep() }
                return
            }
            show(EditorModel(image: loaded.image, scale: loaded.scale, edits: history.loadEdits(id)), id: id)
        }
    }

    /// Showing the window with nothing open (e.g. from the Dock): open the latest capture.
    func ensureSomethingOpen() {
        if editor == nil, let first = history.items.first { select(first.id) }
    }

    func delete(_ id: UUID) {
        if id == currentID {
            let next = history.items.first { $0.id != id }
            editor = nil
            currentID = nil
            saveCancellable = nil
            if let next { select(next.id) }
        }
        history.delete(id)
    }

    func clearHistory() {
        history.clear(keeping: currentID)
    }

    func persistCurrent() {
        guard let editor, let id = currentID else { return }
        history.saveEdits(id, editor.edits)
    }

    private func show(_ model: EditorModel, id: UUID) {
        loadToken = UUID() // a newer show wins over any select still loading
        model.window = window
        model.onClose = { [weak self] in self?.onHide?() }
        model.onCopied = { [weak self] in self?.history.markCopied(id) }
        let changes = Publishers.Merge4(
            model.$annotations.map { _ in () },
            model.$manual.map { _ in () },
            model.$style.map { _ in () },
            model.$presetID.map { _ in () }
        )
        saveCancellable = changes
            .dropFirst(4) // the initial values
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self, weak model] in
                guard let model else { return }
                self?.history.saveEdits(id, model.edits)
            }
        currentID = id
        editor = model
    }
}

// MARK: - Window content

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            if workspace.sidebarVisible {
                HistorySidebar(workspace: workspace, history: workspace.history)
                    .frame(width: 224)
                Divider()
            }
            if let editor = workspace.editor {
                EditorView(
                    model: editor,
                    leadingInset: workspace.sidebarVisible ? 12 : 80,
                    onToggleSidebar: { workspace.sidebarVisible.toggle() }
                )
                .id(ObjectIdentifier(editor))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No capture open").font(.headline)
                    Text("Take a screenshot with your shortcut, or pick one on the left.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: workspace.sidebarVisible ? 1100 : 920, minHeight: 580)
    }
}

// MARK: - History sidebar

private struct HistorySidebar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false
    @AppStorage(Prefs.Key.historyLimit) private var limit = 50

    private struct Group: Identifiable {
        let id: String
        let items: [HistoryItem]
    }

    private var groups: [Group] {
        let cal = Calendar.current
        var today: [HistoryItem] = [], yesterday: [HistoryItem] = [], earlier: [HistoryItem] = []
        for item in history.items {
            if cal.isDateInToday(item.date) { today.append(item) }
            else if cal.isDateInYesterday(item.date) { yesterday.append(item) }
            else { earlier.append(item) }
        }
        return [Group(id: "Today", items: today), Group(id: "Yesterday", items: yesterday), Group(id: "Earlier", items: earlier)]
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("\(history.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Captures kept")
            }
            .padding(.horizontal, 12)
            .frame(height: 40) // traffic lights live here

            Text("Recent captures")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Text(group.id.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(group.items) { item in
                            HistoryRow(
                                item: item,
                                thumbnail: history.thumbnail(item.id),
                                selected: item.id == workspace.currentID
                            )
                            .onTapGesture { workspace.select(item.id) }
                            .contextMenu {
                                Button("Delete") { workspace.delete(item.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }

            Divider()
            HStack {
                Menu {
                    ForEach([10, 25, 50, 100, 200, 500], id: \.self) { n in
                        Button {
                            limit = n
                        } label: {
                            if n == Prefs.historyLimit { Label("\(n) captures", systemImage: "checkmark") } else { Text("\(n) captures") }
                        }
                    }
                    Divider()
                    Button("Custom…") { NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil) }
                } label: {
                    Text("Keep last \(Prefs.historyLimit)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("How many captures to keep. Older ones are deleted at your next screenshot.")
                Spacer()
                Button("Clear History") { confirmClear = true }
                    .buttonStyle(.link)
                    .disabled(history.items.count <= 1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .alert("Clear capture history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { workspace.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every saved capture except the one that's open.")
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let thumbnail: NSImage?
    let selected: Bool

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let number = item.number {
                    Text("#\(number)")
                        .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(3)
                }
            }
            .frame(width: 64, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(Self.time.string(from: item.date)) · \(item.dimensions)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if item.copied {
                    Text("Copied")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
