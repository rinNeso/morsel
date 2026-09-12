import Foundation
import Testing
@testable import MorselCore

/// Same mulberry32 PRNG as the original TypeScript suite, reproduced bit-for-bit
/// so the generated series are identical. Unlike the TS version — which shared
/// one generator across every section, making each test depend on the ones
/// before it — each test here seeds its own, so results hold regardless of
/// execution order or parallelism.
private struct Mulberry32 {
    private var seed: UInt32

    init(seed: UInt32) { self.seed = seed }

    mutating func next() -> Double {
        seed = seed &+ 0x6D2B_79F5
        var t = (seed ^ (seed >> 15)) &* (1 | seed)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    mutating func gauss(sd: Double) -> Double {
        let u = max(next(), 1e-12)
        let v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) * sd
    }
}

private func series(days: Int, startKg: Double, kgPerWeek: Double, noiseSd: Double, seed: UInt32 = 42) -> [WeightPoint] {
    var rng = Mulberry32(seed: seed)
    let base = dayNumber("2026-01-01")!
    return (0..<days).map { i in
        WeightPoint(
            date: dayString(base + i),
            kg: startKg + (kgPerWeek / 7) * Double(i) + rng.gauss(sd: noiseSd)
        )
    }
}

@Suite("Noiseless linear loss, 60d @ -0.50 kg/wk")
struct NoiselessSlope {
    @Test("recovers the exact slope with no earned uncertainty")
    func exactSlope() throws {
        let r = try #require(rateOfChange(series(days: 60, startKg: 90, kgPerWeek: -0.5, noiseSd: 0), windowDays: 60))
        #expect(abs(r.kgPerWeek - -0.5) < 1e-9, "recovers exact slope")
        #expect(r.seKgPerWeek < 1e-9, "SE ~0 with no noise")
        #expect(!r.plateau, "not flagged plateau")
    }
}

@Suite("Realistic noise (sd 0.8 kg), 90d @ -0.50 kg/wk")
struct NoisySlope {
    @Test("estimate lands near truth with an interval that covers it")
    func noisyEstimate() throws {
        let r = try #require(rateOfChange(series(days: 90, startKg: 90, kgPerWeek: -0.5, noiseSd: 0.8), windowDays: 90))
        #expect(abs(r.kgPerWeek - -0.5) < 0.15, "estimate within 0.15 of truth")
        #expect(r.ci95.contains(-0.5), "CI covers the true value")
        #expect(!r.plateau, "not flagged plateau")
    }
}

@Suite("The short-window problem")
struct ShortWindow {
    @Test("a 14-day window is far less certain than 30 or 90")
    func ciNarrowsWithWindow() throws {
        let s = series(days: 90, startKg: 90, kgPerWeek: -0.5, noiseSd: 0.8)
        let r14 = try #require(rateOfChange(s, windowDays: 14))
        let r30 = try #require(rateOfChange(s, windowDays: 30))
        let r90 = try #require(rateOfChange(s, windowDays: 90))

        func width(_ r: Rate) -> Double { r.ci95.upperBound - r.ci95.lowerBound }
        #expect(width(r14) > width(r30) && width(r30) > width(r90), "CI narrows as window grows")
    }
}

@Suite("True plateau: flat weight, pure noise")
struct Plateau {
    @Test("a flat noisy series is flagged as a plateau")
    func flatIsPlateau() throws {
        let r = try #require(rateOfChange(series(days: 45, startKg: 90, kgPerWeek: 0, noiseSd: 0.8), windowDays: 45))
        #expect(r.plateau, "flagged as plateau")
    }
}

@Suite("EWMA gap correction")
struct GapCorrection {
    @Test("a 30-day gap then a 3 kg jump pulls the trend most of the way")
    func gapCorrection() {
        let points = [
            WeightPoint(date: "2026-01-01", kg: 90),
            WeightPoint(date: "2026-01-02", kg: 90),
            WeightPoint(date: "2026-01-03", kg: 90),
            WeightPoint(date: "2026-02-02", kg: 93),
        ]
        let last = ewmaTrend(points, halfLifeDays: 10).last!.trend
        // A naive one-step-per-row EWMA would barely move (alpha~0.067 -> ~90.2).
        #expect(last > 92.0, "30-day gap pulls trend most of the way to the new reading")
        #expect(last < 93.0, "but does not snap all the way to raw")
    }
}

@Suite("Projection cone")
struct ProjectionCone {
    @Test("90d @ -0.50 kg/wk toward an 80 kg goal yields an ordered cone")
    func coneIsOrdered() {
        let p = projectToGoal(series(days: 90, startKg: 90, kgPerWeek: -0.5, noiseSd: 0.8), goalKg: 80, windowDays: 90)
        #expect(p.date != nil, "produces a central date")
        #expect(p.earliest != nil && p.latest != nil, "produces a bracketing cone")
        #expect((p.earliest ?? "") <= (p.date ?? "") && (p.date ?? "") <= (p.latest ?? ""), "cone is ordered")
    }
}

@Suite("Degenerate inputs")
struct Degenerate {
    @Test("empty, too-short, and wrong-direction inputs decline to invent an answer")
    func degenerateInputs() {
        #expect(ewmaTrend([]).isEmpty, "empty series -> no trend")
        #expect(rateOfChange([]) == nil, "empty series -> no rate")
        #expect(rateOfChange(series(days: 2, startKg: 90, kgPerWeek: -0.5, noiseSd: 0)) == nil, "2 points -> no rate (n<3)")

        // Gaining, but the goal is below — no honest date exists.
        let p = projectToGoal(series(days: 30, startKg: 90, kgPerWeek: 0.5, noiseSd: 0.1), goalKg: 85, windowDays: 30)
        #expect(p.date == nil, "wrong-direction trend -> no date (\(p.reason ?? "no reason"))")
    }
}

@Suite("Calendar arithmetic")
struct CalendarMath {
    @Test("day numbers round-trip and handle leap years")
    func dayNumberRoundTrips() throws {
        #expect(dayNumber("1970-01-01") == 0, "epoch is day zero")
        let feb29 = try #require(dayNumber("2024-02-29"))
        #expect(dayString(feb29) == "2024-02-29", "leap day round-trips")
        let d1 = try #require(dayNumber("2026-01-01"))
        let d2 = try #require(dayNumber("2026-02-02"))
        #expect(d2 - d1 == 32, "January has 31 days")
        #expect(dayNumber("not-a-date") == nil, "garbage parses to nil")
    }
}
