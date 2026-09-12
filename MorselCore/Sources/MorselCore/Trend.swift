import Foundation

/// Weight trend analysis — the Happy Scale core.
///
/// Two separate jobs, deliberately using two different methods:
///
///  1. The DISPLAY LINE uses an exponentially weighted moving average (the
///     Hacker's Diet trend). It is smooth, updates intuitively, and answers
///     "what do I actually weigh, ignoring water?".
///
///  2. The RATE OF CHANGE uses ordinary least squares on the RAW weights.
///     It is tempting to regress the EWMA series instead, since it looks
///     cleaner — but EWMA output is heavily autocorrelated by construction,
///     which collapses the apparent residuals and produces a standard error
///     that is far too small. You get a confident number that is not earned.
///     Regressing raw weights gives both an unbiased slope and an honest
///     uncertainty.
///
/// Caveat kept in view: consecutive daily weights are themselves somewhat
/// autocorrelated (water retention persists for days), so even the raw-OLS
/// standard error is mildly optimistic. It is close enough to be useful and
/// far better than the smoothed alternative.

public struct WeightPoint: Sendable, Equatable {
    /// Local day, `YYYY-MM-DD`. "Which day did I weigh in" is a calendar
    /// question, not an instant.
    public let date: String
    public let kg: Double

    public init(date: String, kg: Double) {
        self.date = date
        self.kg = kg
    }
}

public struct TrendPoint: Sendable, Equatable {
    public let date: String
    public let kg: Double
    public let trend: Double
}

// MARK: - Calendar arithmetic

/// Days since the Unix epoch for a `YYYY-MM-DD` local day, by pure integer
/// arithmetic (Howard Hinnant's civil-date algorithm). Deliberately avoids
/// `DateFormatter`: no locale, no time zone, no DST can shift a day count,
/// and it stays identical on Linux.
func dayNumber(_ date: String) -> Int? {
    let parts = date.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
          (1...12).contains(m), (1...31).contains(d)
    else { return nil }

    let yAdj = y - (m <= 2 ? 1 : 0)
    let era = (yAdj >= 0 ? yAdj : yAdj - 399) / 400
    let yoe = yAdj - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// Inverse of `dayNumber`.
func dayString(_ n: Int) -> String {
    let z = n + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp + (mp < 10 ? 3 : -9)
    let year = y + (m <= 2 ? 1 : 0)
    return String(format: "%04d-%02d-%02d", year, m, d)
}

// MARK: - EWMA

/// EWMA with gap correction.
///
/// A naive EWMA treats each row as one time step, so a three-week gap between
/// weigh-ins gets the same pull as a single day and the trend lurches. Scaling
/// alpha by the true elapsed days fixes that: `alphaEff = 1 - (1-alpha)^days`.
///
/// - Parameter halfLifeDays: how long until a reading loses half its influence.
public func ewmaTrend(_ points: [WeightPoint], halfLifeDays: Double = 10) -> [TrendPoint] {
    guard !points.isEmpty else { return [] }
    let sorted = points.sorted { $0.date < $1.date }
    let alpha = 1 - pow(2, -1 / halfLifeDays)

    var out: [TrendPoint] = []
    out.reserveCapacity(sorted.count)
    var trend = sorted[0].kg
    var prevDay = dayNumber(sorted[0].date) ?? 0

    for p in sorted {
        let day = dayNumber(p.date) ?? prevDay
        let gap = max(1, day - prevDay)
        let alphaEff = 1 - pow(1 - alpha, Double(gap))
        trend += alphaEff * (p.kg - trend)
        out.append(TrendPoint(date: p.date, kg: p.kg, trend: trend))
        prevDay = day
    }
    return out
}

// MARK: - Rate of change

public struct Rate: Sendable, Equatable {
    public let kgPerWeek: Double
    /// Standard error of the estimate, same units.
    public let seKgPerWeek: Double
    /// 95% confidence interval.
    public let ci95: ClosedRange<Double>
    public let n: Int

    /// True when the interval straddles zero — that IS the definition of a plateau.
    public var plateau: Bool { ci95.contains(0) }
}

/// Rate of change over a trailing window, by OLS on raw weights.
/// Returns nil when there is not enough data to say anything (n < 3).
public func rateOfChange(_ points: [WeightPoint], windowDays: Int = 30) -> Rate? {
    let sorted = points.sorted { $0.date < $1.date }
    guard let last = sorted.last, let lastDay = dayNumber(last.date) else { return nil }

    let win = sorted.filter { p in
        guard let day = dayNumber(p.date) else { return false }
        return lastDay - day < windowDays
    }
    let n = win.count
    guard n >= 3 else { return nil }

    let xs = win.compactMap { dayNumber($0.date) }.map(Double.init)
    let ys = win.map(\.kg)
    let xbar = xs.reduce(0, +) / Double(n)
    let ybar = ys.reduce(0, +) / Double(n)

    var sxx = 0.0
    var sxy = 0.0
    for i in 0..<n {
        sxx += (xs[i] - xbar) * (xs[i] - xbar)
        sxy += (xs[i] - xbar) * (ys[i] - ybar)
    }
    // Every weigh-in on the same day: slope is undefined, not zero.
    guard sxx != 0 else { return nil }

    let slope = sxy / sxx // kg per day
    let intercept = ybar - slope * xbar

    var sse = 0.0
    for i in 0..<n {
        let residual = ys[i] - (intercept + slope * xs[i])
        sse += residual * residual
    }
    let sigma = (sse / Double(n - 2)).squareRoot()
    let seSlope = sigma / sxx.squareRoot()

    let kgPerWeek = slope * 7
    let seKgPerWeek = seSlope * 7
    return Rate(
        kgPerWeek: kgPerWeek,
        seKgPerWeek: seKgPerWeek,
        ci95: (kgPerWeek - 1.96 * seKgPerWeek)...(kgPerWeek + 1.96 * seKgPerWeek),
        n: n
    )
}

// MARK: - Goal projection

public struct Projection: Sendable, Equatable {
    /// Central estimate. Nil when the trend is flat or moving away from the goal.
    public let date: String?
    /// Range implied by the 95% CI on the rate. Nil ends are "possibly never".
    public let earliest: String?
    public let latest: String?
    public let reason: String?
}

/// Project when the trend line reaches a goal weight.
///
/// Happy Scale shows a single date. A single date is a claim of precision that
/// two weeks of noisy bathroom-scale data cannot support, so this returns a cone
/// instead: the fast and slow ends implied by the confidence interval on the rate.
public func projectToGoal(
    _ points: [WeightPoint],
    goalKg: Double,
    windowDays: Int = 30,
    halfLifeDays: Double = 10
) -> Projection {
    let trend = ewmaTrend(points, halfLifeDays: halfLifeDays)
    guard let latest = trend.last,
          let lastDay = dayNumber(latest.date),
          let rate = rateOfChange(points, windowDays: windowDays)
    else {
        return Projection(date: nil, earliest: nil, latest: nil, reason: "not enough data")
    }

    let remaining = goalKg - latest.trend
    if abs(remaining) < 0.05 {
        return Projection(date: dayString(lastDay), earliest: nil, latest: nil, reason: "already there")
    }

    // days = remaining / (kgPerWeek / 7); only counts if the sign moves toward goal.
    func daysFor(_ kgPerWeek: Double) -> String? {
        let perDay = kgPerWeek / 7
        guard perDay != 0 else { return nil }
        let d = remaining / perDay
        guard d > 0, d.isFinite else { return nil }
        return dayString(Int((Double(lastDay) + d).rounded()))
    }

    let central = daysFor(rate.kgPerWeek)

    // A negative time-to-goal means the goal lies behind you along your current
    // direction of travel — you passed it and are still going. That deserves a
    // different message from "you are drifting the wrong way and never arrive".
    if central == nil, !rate.plateau {
        let perDay = rate.kgPerWeek / 7
        if perDay != 0, remaining / perDay < 0 {
            return Projection(
                date: nil, earliest: nil, latest: nil,
                reason: "goal already passed; trend is continuing beyond it"
            )
        }
    }

    let ends = [daysFor(rate.ci95.lowerBound), daysFor(rate.ci95.upperBound)]
        .compactMap { $0 }
        .sorted()

    return Projection(
        date: central,
        earliest: ends.first,
        latest: ends.count > 1 ? ends.last : nil,
        reason: central == nil ? "trend is not moving toward the goal" : nil
    )
}
