import MorselCore
import SwiftUI

struct TimerScreen: View {
    @Environment(MealTimerModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    /// Read from settings rather than `Color.accentColor`, which resolves the
    /// environment's accent — not the value `.tint()` sets. Relying on it meant
    /// the chosen colour could silently fail to reach these views.
    private var accent: Color { settings.accent }

    private let restPresets = [15, 20, 30, 45, 60]

    var body: some View {
        Group {
            switch model.state.phase {
            case .idle: idle
            case .ended: ended
            case .ready, .resting, .paused: active
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
        .onChange(of: scenePhase) { _, phase in
            // An arbitrary amount of time may have passed with no timer
            // running; recompute from the wall clock.
            if phase == .active { model.refresh() }
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 16) {
            Text("Morsel")
                .font(.largeTitle.bold())
                .foregroundStyle(Palette.text)
            Text("Put your food down after every bite, then tap.")
                .font(.subheadline)
                .foregroundStyle(Palette.dim)

            Text("REST BETWEEN BITES")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(Palette.dim)
                .padding(.top, 24)

            HStack(spacing: 8) {
                ForEach(restPresets, id: \.self) { seconds in
                    let selected = seconds == model.restSeconds
                    Button {
                        model.restSeconds = seconds
                    } label: {
                        Text("\(seconds)s")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(selected ? .white : Palette.dim)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(selected ? accent : .clear, in: .capsule)
                            .overlay(
                                Capsule().strokeBorder(selected ? accent : Palette.track, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Start meal") {
                model.send(.start(restMs: model.restSeconds * 1000))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 12)
        }
        .padding(24)
    }

    // MARK: Active

    private var active: some View {
        VStack {
            // Meal duration only needs to tick once a second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = Millis(context.date.timeIntervalSince1970 * 1000)
                HStack(alignment: .top) {
                    Text("\(model.state.bites.count) bites")
                        .monospacedDigit()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(mmss(model.state.activeDuration(now: now)))
                            .monospacedDigit()
                        Text("meal duration")
                            .font(.system(size: 10))
                            .kerning(0.4)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer()

            // The ring redraws every frame, so the sweep is genuinely
            // continuous rather than stepped — no tweening needed, which is
            // exactly what the React Native version had to fake by hand.
            TimelineView(.animation) { context in
                let now = Millis(context.date.timeIntervalSince1970 * 1000)
                ring(now: now)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(model.state.phase == .paused ? "Resume" : "Pause") {
                    model.send(model.state.phase == .paused ? .resume : .pause)
                }
                Button("End meal") { model.send(.end) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Palette.dim)
            .padding(24)
        }
    }

    /// The ring is the tap target: a large, unmissable surface you can hit
    /// without looking away from the table.
    private func ring(now: Millis) -> some View {
        let phase = model.state.phase
        let isResting = phase == .resting
            || (phase == .paused && model.state.phaseBeforePause == .resting)
        let color: Color = phase == .paused
            ? Palette.paused
            : (isResting ? settings.resolvedRestingColor : accent)

        return ZStack {
            Circle().stroke(Palette.track, lineWidth: 18)
            Circle()
                .trim(from: 0, to: model.state.restProgress(now: now))
                .stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))

            switch phase {
            case .paused:
                Text("Paused")
                    .font(.title.bold())
                    .foregroundStyle(Palette.paused)
            case .ready:
                VStack(spacing: 4) {
                    Text("Take a bite")
                        .font(.title.bold())
                        .foregroundStyle(accent)
                    Text("then tap when it's down")
                        .font(.subheadline)
                        .foregroundStyle(Palette.dim)
                }
            default:
                VStack(spacing: 4) {
                    Text("\(Int((Double(model.state.remainingRest(now: now)) / 1000).rounded(.up)))")
                        .font(.system(size: 76, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                    Text("food down")
                        .font(.subheadline)
                        .foregroundStyle(Palette.dim)
                }
            }
        }
        .frame(width: 280, height: 280)
        .contentShape(.rect)
        .onTapGesture {
            if phase == .ready || phase == .resting { model.confirmBite() }
        }
        .accessibilityLabel(phase == .ready ? "Confirm bite taken" : "Confirm bite early")
    }

    // MARK: Ended

    private var ended: some View {
        let summary = model.state.summary(now: MealTimerModel.nowMillis())

        return ScrollView {
            VStack(spacing: 16) {
                Text("Meal complete")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Palette.text)

                VStack(spacing: 12) {
                    row("Bites", "\(summary.biteCount)")
                    row("Duration", mmss(summary.durationMs))
                    if summary.pausedMs > 0 {
                        row("Paused", mmss(summary.pausedMs))
                    }
                    if let meanBite = summary.meanBiteMs {
                        row("Avg time per bite", String(format: "%.1fs", meanBite / 1000))
                    }
                    if summary.earlyBites > 0 {
                        row("Early bites", "\(summary.earlyBites)")
                    }
                    if let drift = summary.paceDrift {
                        row("Pace through meal", paceDescription(drift))
                    }
                }
                .padding(20)
                .background(Palette.card, in: .rect(cornerRadius: 16))

                Text("Fullness rating and saving come next.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.dim)

                Button("Done") { model.send(.reset) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
            .padding(24)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(Palette.dim)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(Palette.text)
        }
        .font(.subheadline)
    }

    private func paceDescription(_ drift: Double) -> String {
        if drift < 0.8 { return "sped up \(Int(((1 - drift) * 100).rounded()))%" }
        if drift > 1.2 { return "slowed \(Int(((drift - 1) * 100).rounded()))%" }
        return "steady"
    }
}
