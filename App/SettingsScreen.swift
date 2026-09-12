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

                    HStack(spacing: 12) {
                        ForEach(Palette.accentPresets, id: \.hexString) { preset in
                            Button {
                                settings.setAccent(preset)
                            } label: {
                                Circle()
                                    .fill(preset)
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Circle().strokeBorder(
                                            preset.hexString == settings.accent.hexString
                                                ? Palette.text : .clear,
                                            lineWidth: 3
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use \(preset.hexString) as accent colour")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } header: {
                    Text("Accent colour")
                } footer: {
                    Text("Your \"ready\" colour — permission to eat. Resting and paused stay amber and grey.")
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
}
