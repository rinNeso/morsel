import MorselData
import SwiftUI
import UniformTypeIdentifiers

/// Wraps the store so the share sheet can pull JSON out of it lazily — the
/// export is only generated if the user actually shares, not on every render.
private struct ExportedData: Transferable {
    let store: MealStore

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { exported in
            try await exported.store.exportJSON()
        }
        .suggestedFileName { _ in
            "morsel-\(Date().formatted(.iso8601.year().month().day())).json"
        }
    }
}

struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.mealStore) private var store

    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: themeBinding) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    // SwiftUI's own picker — the whole hand-rolled colour wheel
                    // the React Native build needed reduces to this line.
                    ColorPicker("Accent colour", selection: accentBinding, supportsOpacity: false)
                    PresetSwatches(selected: settings.accent, role: "accent") {
                        settings.setAccent($0)
                    }
                } header: {
                    Text("Accent colour")
                } footer: {
                    Text("Your \"ready\" colour — permission to eat.")
                }

                Section {
                    Toggle("Match accent colour", isOn: matchAccentBinding)
                    if let resting = settings.restingColor {
                        ColorPicker("Resting colour", selection: restingBinding, supportsOpacity: false)
                        PresetSwatches(selected: resting, role: "resting") {
                            settings.setRestingColor($0)
                        }
                    }
                } header: {
                    Text("Resting colour")
                } footer: {
                    Text("The ring while you're waiting between bites. A separate colour makes \"resting\" and \"take a bite\" readable at a glance from across the table; the ring's fill and countdown already differ either way.")
                }

                Section {
                    if let store {
                        ShareLink(
                            item: ExportedData(store: store),
                            preview: SharePreview("Morsel data", image: Image(systemName: "square.and.arrow.up"))
                        ) {
                            BackupLabel("Export data", symbol: "tray.and.arrow.up")
                        }
                    }
                    Button {
                        importing = true
                    } label: {
                        BackupLabel("Import data", symbol: "tray.and.arrow.down")
                    }
                    .disabled(store == nil)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Every meal, bite and setting as a JSON file. There is no account and no sync, so this file is the only copy that survives deleting the app or changing phones — save it somewhere that outlives this device.\n\nImporting merges: meals already here are left alone, and importing the same file twice changes nothing.")
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .alert("Import", isPresented: showingImportResult) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private var showingImportResult: Binding<Bool> {
        Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard let store else { return }
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let url):
            Task {
                // Files handed over by the picker live outside our sandbox.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let outcome = try await store.importJSON(try Data(contentsOf: url))
                    importMessage = Self.describe(outcome)
                    // Settings may have arrived with the file.
                    await settings.load()
                } catch {
                    importMessage = error.localizedDescription
                }
            }
        }
    }

    private static func describe(_ result: ImportResult) -> String {
        var parts = ["Imported \(result.imported) meal\(result.imported == 1 ? "" : "s")."]
        if result.skipped > 0 {
            parts.append("\(result.skipped) already here, left alone.")
        }
        if result.settingsApplied > 0 {
            parts.append("Appearance settings restored.")
        }
        return parts.joined(separator: " ")
    }

    private var accentBinding: Binding<Color> {
        Binding(get: { settings.accent }, set: { settings.setAccent($0) })
    }

    private var themeBinding: Binding<ThemeMode> {
        Binding(get: { settings.themeMode }, set: { settings.setThemeMode($0) })
    }

    private var matchAccentBinding: Binding<Bool> {
        Binding(
            get: { settings.restingColor == nil },
            // Breaking the link seeds from the current accent, so the picker
            // opens on something sensible rather than an arbitrary colour.
            set: { settings.setRestingColor($0 ? nil : settings.accent) }
        )
    }

    private var restingBinding: Binding<Color> {
        Binding(get: { settings.resolvedRestingColor }, set: { settings.setRestingColor($0) })
    }
}

/// Export and import sit next to each other, so their icons have to line up.
///
/// They use the `tray` pair rather than `square.and.arrow.up/down`. The latter
/// looked mismatched on device: `square.and.arrow.up` is the iOS *share* glyph,
/// drawn to stand alone rather than as half of a set, and its arrow leaves the
/// square where the down variant's enters it. The tray pair is drawn as a
/// matched set, and reads better for a backup section anyway — out of storage
/// and into it, rather than sharing.
///
/// The fixed frame stays regardless: these rows are different containers, a
/// ShareLink and a Button, which do not lay their labels out identically.
private struct BackupLabel: View {
    private let title: String
    private let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
    }
}

/// Quick starting points. Both colour settings offer the same set — the picker
/// above each one is what makes any colour reachable.
private struct PresetSwatches: View {
    @Environment(\.theme) private var theme

    let selected: Color
    /// Only used for the accessibility label, so "accent" and "resting" read
    /// distinctly to VoiceOver.
    let role: String
    let onSelect: (Color) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Palette.accentPresets, id: \.hexString) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    Circle()
                        .fill(preset)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle().strokeBorder(
                                preset.hexString == selected.hexString ? theme.text : .clear,
                                lineWidth: 3
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(preset.hexString) as \(role) colour")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
