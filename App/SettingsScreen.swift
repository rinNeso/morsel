import SwiftUI

struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings

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
            }
            .navigationTitle("Settings")
        }
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

/// Quick starting points. Both colour settings offer the same set — the picker
/// above each one is what makes any colour reachable.
private struct PresetSwatches: View {
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
                                preset.hexString == selected.hexString ? Palette.text : .clear,
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
