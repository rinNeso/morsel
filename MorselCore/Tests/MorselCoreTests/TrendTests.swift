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

@Suite("Progress readouts")
struct ProgressReadouts {
    /// A steady loss with one absurd reading in the middle, to show what each
    /// approach does with a single bad morning.
    private func noisyLoss() -> [WeightPoint] {
        let base = dayNumber("2026-03-01")!
        return (0..<30).map { day in
            var kg = 90.0 - (0.5 / 7) * Double(day)
            if day == 29 { kg += 1.5 } // a heavy dinner the night before
            return WeightPoint(date: dayString(base + day), kg: kg)
        }
    }

    @Test("a single bad morning barely moves the trend delta")
    func trendDeltaResistsNoise() throws {
        let points = noisyLoss()
        let weekly = try #require(trendChange(points, overDays: 7))

        // Raw endpoints would read this as a *gain*, because the last morning
        // was 1.5 kg up. The trend still sees the fortnight of losing.
        let rawWeekly = points.last!.kg - points[points.count - 8].kg
        #expect(rawWeekly > 0, "raw endpoints invent a gain from one heavy day")
        #expect(weekly < 0, "the trend still reports the loss that actually happened")
    }

    @Test("a real gain still reports as a gain")
    func realGainStillShows() throws {
        let base = dayNumber("2026-03-01")!
        let gaining = (0..<30).map { day in
            WeightPoint(date: dayString(base + day), kg: 90.0 + (0.4 / 7) * Double(day))
        }
        let change = try #require(trendChange(gaining, overDays: 14))
        #expect(change > 0, "smoothing does not hide a direction that is real")
    }

    @Test("a window longer than the data returns nothing rather than a truncated answer")
    func windowBeyondData() {
        let base = dayNumber("2026-03-01")!
        let short = (0..<5).map { WeightPoint(date: dayString(base + $0), kg: 90.0) }
        #expect(trendChange(short, overDays: 90) == nil)
    }

    @Test("all-time change spans the whole series")
    func allTime() throws {
        let change = try #require(trendChangeAllTime(noisyLoss()))
        #expect(change < 0)
    }

    @Test("milestones are evenly spaced and know which are behind you")
    func milestoneSpacing() {
        let all = milestones(startKg: 90, goalKg: 80, count: 5, currentKg: 85.5)
        #expect(all.count == 5)
        #expect(all.map(\.targetKg) == [88, 86, 84, 82, 80])
        #expect(all.filter(\.reached).count == 2, "88 and 86 are behind; 84 is not")
    }

    @Test("milestones work when the goal is above the start")
    func milestonesGainingDirection() {
        let all = milestones(startKg: 60, goalKg: 70, count: 4, currentKg: 65.5)
        #expect(all.map(\.targetKg) == [62.5, 65, 67.5, 70])
        #expect(all.filter(\.reached).count == 2)
    }

    @Test("degenerate milestone requests produce nothing rather than nonsense")
    func milestoneEdges() {
        #expect(milestones(startKg: 90, goalKg: 90, count: 5, currentKg: 90).isEmpty)
        #expect(milestones(startKg: 90, goalKg: 80, count: 0, currentKg: 85).isEmpty)
    }

    @Test("forecasting projects the trend forward at the measured rate")
    func forecast() throws {
        let base = dayNumber("2026-03-01")!
        // Exactly -0.7 kg/week, so the arithmetic is checkable by hand.
        let clean = (0..<30).map { day in
            WeightPoint(date: dayString(base + day), kg: 90.0 - 0.1 * Double(day))
        }
        let today = try #require(ewmaTrend(clean).last?.trend)
        let week = try #require(forecastWeight(clean, daysAhead: 7))
        #expect(abs((today - week) - 0.7) < 0.01, "seven days at 0.1/day is 0.7")
    }

    @Test("no forecast without enough data to establish a rate")
    func forecastNeedsData() {
        #expect(forecastWeight([], daysAhead: 7) == nil)
    }
}
