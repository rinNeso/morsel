import Testing
@testable import MorselCore

private func day(_ date: String, _ kcal: Int, meals: Int = 3) -> DayIntake {
    DayIntake(date: date, kcal: kcal, meals: meals)
}

@Suite("A missing day is not a zero")
struct MissingIsNotZero {
    @Test("an unlogged day is left out of the mean rather than counted as nothing")
    func unloggedDaysAreAbsent() {
        // Monday and Wednesday logged, Tuesday not. Tuesday still had eating in
        // it; the app just never heard about it.
        let days = [day("2026-09-14", 2000), day("2026-09-16", 2200)]

        let average = trailingAverage(days, endingOn: "2026-09-16", windowDays: 7)
        #expect(average?.kcal == 2100, "mean of the two logged days, not (2000+0+2200)/3")
        #expect(average?.daysLogged == 2, "reports that only two days backed the figure")
        #expect(average?.isComplete == false, "two of seven is not a full window")
    }

    @Test("a logged zero is a real observation and does count")
    func loggedZeroCounts() {
        let days = [day("2026-09-15", 0, meals: 1), day("2026-09-16", 2000)]
        let average = trailingAverage(days, endingOn: "2026-09-16", windowDays: 7)
        #expect(average?.kcal == 1000, "a day logged as zero pulls the mean down; an absent day cannot")
        #expect(average?.daysLogged == 2)
    }

    @Test("no logged days in the window is absent, not zero")
    func emptyWindowIsNil() {
        #expect(trailingAverage([], endingOn: "2026-09-16") == nil)
        #expect(
            trailingAverage([day("2026-01-01", 2000)], endingOn: "2026-09-16") == nil,
            "a log from January says nothing about this week"
        )
    }
}

@Suite("Trailing window")
struct TrailingWindow {
    @Test("the window is inclusive of both ends and exactly windowDays long")
    func windowBoundaries() {
        // A seven-day window ending on the 16th covers the 10th through 16th.
        let days = [
            day("2026-09-09", 9999), // one day too early
            day("2026-09-10", 1000), // first day inside
            day("2026-09-16", 2000), // last day inside
        ]
        let average = trailingAverage(days, endingOn: "2026-09-16", windowDays: 7)
        #expect(average?.daysLogged == 2, "the 9th is outside a seven-day window ending the 16th")
        #expect(average?.kcal == 1500)
    }

    @Test("future days beyond the end date are not counted")
    func ignoresLaterDays() {
        let days = [day("2026-09-16", 2000), day("2026-09-17", 4000)]
        #expect(trailingAverage(days, endingOn: "2026-09-16")?.kcal == 2000)
    }

    @Test("a full window reports itself complete")
    func completeWindow() {
        let days = (10...16).map { day("2026-09-\($0)", 2000) }
        let average = trailingAverage(days, endingOn: "2026-09-16", windowDays: 7)
        #expect(average?.isComplete == true)
        #expect(average?.daysLogged == 7)
    }

    @Test("crossing a month boundary counts calendar days, not string order")
    func crossesMonths() {
        let days = [day("2026-08-31", 1000), day("2026-09-01", 3000)]
        let average = trailingAverage(days, endingOn: "2026-09-01", windowDays: 2)
        #expect(average?.daysLogged == 2, "31 Aug is the day before 1 Sep")
        #expect(average?.kcal == 2000)
    }
}

@Suite("Rolling mean for the chart")
struct RollingMean {
    @Test("every logged day carries the mean as it stood that day")
    func meanPerDay() {
        let days = [day("2026-09-14", 1000), day("2026-09-15", 2000), day("2026-09-16", 3000)]
        let series = rollingMean(days, windowDays: 7)

        #expect(series.count == 3, "one point per logged day")
        #expect(series[0].mean == 1000, "first day averages only itself")
        #expect(series[1].mean == 1500)
        #expect(series[2].mean == 2000)
        #expect(series.map(\.kcal) == [1000, 2000, 3000], "the raw day survives alongside the mean")
    }

    @Test("the window slides, so old days fall out")
    func windowSlides() {
        let days = [day("2026-09-14", 1000), day("2026-09-15", 2000), day("2026-09-16", 3000)]
        let series = rollingMean(days, windowDays: 2)
        #expect(series[2].mean == 2500, "a two-day window on the 16th sees only the 15th and 16th")
    }

    @Test("an empty log charts nothing rather than a line at zero")
    func emptyChartsNothing() {
        #expect(rollingMean([]).isEmpty)
    }
}
