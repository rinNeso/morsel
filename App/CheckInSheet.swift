import MorselData
import SwiftUI

/// Answers the post-meal check-in for one meal.
///
/// Same 1–10 scale and the same anchored endpoints as the end-of-meal rating,
/// deliberately: the two numbers are only comparable if they were asked the
/// same way.
struct CheckInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mealStore) private var store
    @Environment(\.theme) private var theme

    let mealID: Int64

    @State private var rating: Int?
    @State private var elapsed: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("How full are you now?")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.text)

                if let elapsed {
                    Text("\(elapsed) minutes after your meal")
                        .font(.subheadline)
                        .foregroundStyle(theme.dim)
                }

                HStack(spacing: 6) {
                    ForEach(1...10, id: \.self) { value in
                        let chosen = rating == value
                        Button {
                            choose(value)
                        } label: {
                            Text("\(value)")
                                .font(.footnote.weight(chosen ? .bold : .regular))
                                .foregroundStyle(chosen ? .white : theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(chosen ? theme.accent : theme.card, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Fullness \(value) out of 10")
                    }
                }

                HStack {
                    Text("Still hungry")
                    Spacer()
                    Text("Uncomfortably full")
                }
                .font(.caption2)
                .foregroundStyle(theme.dim)

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Skipping is a first-class answer. An unanswered check-in is
                // honest; a guessed one is noise in the column it exists for.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
        .task {
            elapsed = try? await store?.checkInDelayMinutes(mealID: mealID)
        }
    }

    private func choose(_ value: Int) {
        rating = value
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
            // The delay is recorded alongside the rating by the store, so a
            // reply hours late is distinguishable from a prompt one.
            try? await store?.setLaterFullness(value, mealID: mealID)
            try? await Task.sleep(for: .milliseconds(250))
            dismiss()
        }
    }
}
