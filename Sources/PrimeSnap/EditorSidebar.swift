import AppKit
import SwiftUI

struct EditorSidebar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PresetMenu(model: model)
                Divider()
                ValueSlider(title: "Padding", value: $model.style.padding, range: 0...200)
                insetSection
                HStack(alignment: .top, spacing: 16) {
                    ValueSlider(title: "Rounded", value: $model.style.cornerRadius, range: 0...48)
                    ValueSlider(title: "Shadow", value: $model.style.shadow, range: 0...1, percent: true)
                }
                BackgroundGrid(model: model)
                RatioGrid(model: model)
                Divider()
                redactionSection
                watermarkSection
            }
            .padding(16)
            .padding(.top, 26)
        }
        .scrollIndicators(.never)
    }

    private var insetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionTitle("Inset")
                ValueBadge(text: "\(Int(model.style.inset))")
                Text(model.style.insetColor == nil ? "(background color detected)" : "(custom color)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Slider(value: $model.style.inset, in: 0...120)
                Toggle("Balance", isOn: $model.style.balance)
                    .toggleStyle(.checkbox)
                    .help("Trim uneven margins so the content sits centered in the inset")
                ColorPicker("", selection: insetColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Inset color — right-click to reset to detected")
                    .contextMenu { Button("Use Detected Color") { model.style.insetColor = nil } }
            }
        }
    }

    private var insetColor: Binding<Color> {
        Binding(
            get: { Color(cgColor: (model.style.insetColor ?? model.analysis?.edgeColor ?? .white).cgColor) },
            set: { model.style.insetColor = RGBA(nsColor: NSColor($0)) }
        )
    }

    private var redactionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Redact sensitive data", isOn: $model.style.autoRedact)
            if model.scanFailed && model.style.autoRedact {
                Label("Scan failed — check for secrets before sharing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text(redactStatus).font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $model.style.redactStyle) {
                ForEach(RedactStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Text("Press 3 and drag to hide an area").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearManual() }
                    .controlSize(.small)
                    .disabled(model.manual.isEmpty)
            }
        }
    }

    private var redactStatus: String {
        if model.detecting { return "Scanning for emails, keys, tokens…" }
        var parts: [String] = []
        if model.style.autoRedact { parts.append(model.autoCount == 0 ? "Nothing sensitive found" : "\(model.autoCount) hidden automatically") }
        if !model.manual.isEmpty { parts.append("\(model.manual.count) manual") }
        return parts.isEmpty ? "Auto-redaction off" : parts.joined(separator: " · ")
    }

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show watermark text", isOn: $model.style.watermarkEnabled)
            TextField("Your watermark text", text: $model.style.watermarkText)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.style.watermarkEnabled)
        }
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
    }
}

private struct ValueBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var percent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionTitle(title)
                ValueBadge(text: percent ? "\(Int(value * 100))%" : "\(Int(value))")
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct PresetMenu: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var store = PresetStore.shared
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Default") { model.applyPreset(nil) }
                if !store.presets.isEmpty { Divider() }
                ForEach(store.presets) { preset in
                    Button(preset.name) { model.applyPreset(preset) }
                }
                Divider()
                Button("Save Current Style as Preset…") {
                    name = ""
                    naming = true
                }
            } label: {
                Text(title)
            }
            Button {
                if let id = model.presetID {
                    store.delete(id)
                    model.presetID = nil
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.presetID == nil)
            .help("Delete this preset")
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { model.presetID = store.add(name: name, style: model.style).id }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var title: String {
        guard let preset = store.preset(model.presetID) else { return "Style: Default" }
        return "Style: \(preset.name)" + (preset.style == model.style ? "" : " •")
    }
}

private struct BackgroundGrid: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Background")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                cell("Desktop", .desktop) { imageThumb(.desktop, fallback: "desktopcomputer") }
                ForEach(GradientPreset.all.indices, id: \.self) { i in
                    cell(GradientPreset.all[i].name, .gradient(i)) { GradientSwatch(preset: GradientPreset.all[i]) }
                }
                cell("None", .none) { Checkerboard() }
                customCell
            }
        }
    }

    private var customCell: some View {
        let current: Background? = { if case .image = model.style.background { return model.style.background } else { return nil } }()
        return BackgroundCell(name: "Image…", selected: current != nil) {
            if let current { imageThumb(current, fallback: "photo") } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
                }
            }
        }
        .onTapGesture { pickImage() }
    }

    private func cell<C: View>(_ name: String, _ bg: Background, @ViewBuilder content: () -> C) -> some View {
        BackgroundCell(name: name, selected: model.style.background == bg, content: content)
            .onTapGesture { model.style.background = bg }
    }

    @ViewBuilder
    private func imageThumb(_ bg: Background, fallback: String) -> some View {
        if let img = BackgroundImages.image(for: bg) {
            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.primary.opacity(0.08)
                Image(systemName: fallback).foregroundStyle(.secondary)
            }
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image"
        if panel.runModal() == .OK, let url = panel.url {
            model.style.background = .image(url.path)
        }
    }
}

private struct BackgroundCell<Content: View>: View {
    let name: String
    let selected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 3) {
            content
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                )
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct GradientSwatch: View {
    let preset: GradientPreset
    var body: some View {
        let colors = preset.colors.map { Color(cgColor: $0.cgColor) }
        if colors.count == 1 {
            colors[0]
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(ceil(size.height / s)) {
                for col in 0..<Int(ceil(size.width / s)) where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)), with: .color(Color(white: 0.82)))
                }
            }
        }
    }
}

private struct RatioGrid: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Ratio")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(AspectPreset.allCases) { preset in
                    Button(preset.rawValue) { model.style.aspect = preset }
                        .buttonStyle(ChipStyle(selected: model.style.aspect == preset))
                }
            }
        }
    }
}

private struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.07)))
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
    }
}
