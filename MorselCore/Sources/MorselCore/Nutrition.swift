/// Daily energy intake.
///
/// Deliberately not built on the weight machinery next door, despite the two
/// looking alike — a daily number with a history and a goal. Two differences
/// make copying `Trend.swift` wrong rather than convenient.
///
/// **A missing day is not a zero.** An absent weigh-in is a value that was
/// never observed, and the series simply skips it. An absent *meal log* is not
/// a day of eating nothing; it is a day that went unrecorded. Carrying
/// unlogged days through as 0 kcal would drag every average toward zero and
/// invent a deficit nobody ate. So only logged days exist in this series, and
/// every average says how many days it actually had to work with.
///
/// **The smoother is a trailing mean, not an EWMA.** The weight EWMA exists
/// because a bathroom scale is a noisy instrument reading a slow-moving true
/// value — water and gut contents move the number without moving the body.
/// Intake has no equivalent hidden value: the day-to-day variation *is* the
/// behaviour. A plain mean over trailing calendar days is what integrates to
/// energy balance, and it is the figure a reader can reason about without
/// first understanding what a half-life is.

/// One day that was logged. Days with no logged meal are absent, never zero.
public struct DayIntake: Sendable, Equatable {
    /// Local day, `YYYY-MM-DD`. "What did I eat today" is a calendar question,
    /// the same way a weigh-in is.
    public let date: String
    public let kcal: Int
    /// How many meals made up the total, so the UI can distinguish a light day
    /// from a half-logged one.
    public let meals: Int

    public init(date: String, kcal: Int, meals: Int) {
        self.date = date
        self.kcal = kcal
        self.meals = meals
    }
}

/// A trailing mean, reported with the evidence behind it.
public struct IntakeAverage: Sendable, Equatable {
    public let kcal: Double
    /// Days in the window that were actually logged. The honesty of the mean
    /// rests on this: four logged days out of seven is a different claim from
    /// seven out of seven, and the reader is entitled to know which they have.
    public let daysLogged: Int
    public let windowDays: Int

    public var isComplete: Bool { daysLogged >= windowDays }

    public init(kcal: Double, daysLogged: Int, windowDays: Int) {
        self.kcal = kcal
        self.daysLogged = daysLogged
        self.windowDays = windowDays
    }
}

/// Mean intake over the `windowDays` calendar days ending on `endDate`,
/// inclusive, averaged across the logged days within it.
///
/// Nil when nothing in the window was logged — a mean of no days is not zero,
/// it is absent, and the caller has to say so rather than print 0.
public func trailingAverage(
    _ days: [DayIntake],
    endingOn endDate: String,
    windowDays: Int = 7
) -> IntakeAverage? {
    guard windowDays > 0, let end = dayNumber(endDate) else { return nil }
    let start = end - windowDays + 1

    let inWindow = days.filter { day in
        guard let n = dayNumber(day.date) else { return false }
        return n >= start && n <= end
    }
    guard !inWindow.isEmpty else { return nil }

    let total = inWindow.reduce(0) { $0 + $1.kcal }
    return IntakeAverage(
        kcal: Double(total) / Double(inWindow.count),
        daysLogged: inWindow.count,
        windowDays: windowDays
    )
}

/// A logged day alongside the trailing mean as it stood that day — the pair the
/// chart draws, bars against a line.
public struct IntakeMean: Sendable, Equatable {
    public let date: String
    public let kcal: Int
    public let mean: Double

    public init(date: String, kcal: Int, mean: Double) {
        self.date = date
        self.kcal = kcal
        self.mean = mean
    }
}

/// The trailing mean recomputed at every logged day. Oldest first, which is the
/// order `dailyIntake` returns and the order a chart wants.
public func rollingMean(_ days: [DayIntake], windowDays: Int = 7) -> [IntakeMean] {
    days.compactMap { day in
        guard let average = trailingAverage(days, endingOn: day.date, windowDays: windowDays) else {
            return nil
        }
        return IntakeMean(date: day.date, kcal: day.kcal, mean: average.kcal)
    }
}
