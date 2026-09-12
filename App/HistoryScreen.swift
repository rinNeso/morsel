import SwiftUI

/// Placeholder until persistence lands (GRDB over docs/schema.sql). Scrollable
/// so the tab bar's minimize-on-scroll is exercisable in the meantime.
struct HistoryScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<20, id: \.self) { i in
                        HStack {
                            Text("Meal \(i + 1)")
                                .foregroundStyle(Palette.text)
                            Spacer()
                            Text("—")
                                .foregroundStyle(Palette.dim)
                        }
                        .padding(16)
                        .background(Palette.card, in: .rect(cornerRadius: 16))
                    }
                }
                .padding(16)
            }
            .background(Palette.bg)
            .navigationTitle("Meal history")
        }
    }
}
