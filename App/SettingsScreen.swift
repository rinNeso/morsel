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

                    Picker("Weight in", selection: weightUnitBinding) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
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
                    ColourPreview()
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
                    Toggle("Check in after meals", isOn: checkInBinding)
                    if settings.checkInEnabled {
                        Picker("Ask after", selection: checkInMinutesBinding) {
                            ForEach([30, 45, 60, 90], id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                        }
                    }
                } header: {
                    Text("Satiety check-in")
                } footer: {
                    Text("A single notification asking how full you are once the meal has had time to land. Around 45 minutes is when the satiety hormones peak, which is the most informative moment to ask.")
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
        if result.weighInsImported > 0 {
            parts.append("\(result.weighInsImported) weigh-in\(result.weighInsImported == 1 ? "" : "s") restored.")
        }
        if result.settingsApplied > 0 {
            parts.append("Appearance settings restored.")
        }
        return parts.joined(separator: " ")
    }

    private var checkInBinding: Binding<Bool> {
        Binding(
            get: { settings.checkInEnabled },
            set: { settings.setCheckIn(enabled: $0, minutes: settings.checkInMinutes) }
        )
    }

    private var checkInMinutesBinding: Binding<Int> {
        Binding(
            get: { settings.checkInMinutes },
            set: { settings.setCheckIn(enabled: settings.checkInEnabled, minutes: $0) }
        )
    }

    private var accentBinding: Binding<Color> {
        Binding(get: { settings.accent }, set: { settings.setAccent($0) })
    }

    private var weightUnitBinding: Binding<WeightUnit> {
        Binding(get: { settings.weightUnit }, set: { settings.setWeightUnit($0) })
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

/// Both ring colours in the shape they are actually seen in, sitting between the
/// two pickers that set them. The question these settings really ask is whether
/// "take a bite" and "resting" read differently at a glance from across a table,
/// and two swatches in a list cannot answer it — the ring can.
///
/// Static rather than sweeping: the question is about colour, and motion in a
/// settings list pulls the eye to the motion instead. The stroke is heavier than
/// a true scale reduction of the real ring would give, because judging a colour
/// needs area to judge it on.
private struct ColourPreview: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 32) {
            ring(color: theme.accent, progress: 1, caption: "Take a bite") {
                Image(systemName: "fork.knife")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            ring(color: theme.resting, progress: 0.62, caption: "Resting") {
                Text("12")
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the take-a-bite and resting ring colours")
    }

    private func ring<Centre: View>(
        color: Color,
        progress: Double,
        caption: String,
        @ViewBuilder centre: () -> Centre
    ) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(theme.track, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                centre()
            }
            .frame(width: 78, height: 78)

            Text(caption)
                .font(.caption)
                .foregroundStyle(theme.dim)
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
