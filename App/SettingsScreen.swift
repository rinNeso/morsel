import SwiftUI

/// Placeholder. The accent colour picker lands here next — as SwiftUI's own
/// `ColorPicker`, which replaces the ~80 lines of hand-rolled SVG colour wheel
/// the React Native build needed.
struct SettingsScreen: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    LabeledContent("Accent colour", value: "Coming next")
                    LabeledContent("Theme", value: "System")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
