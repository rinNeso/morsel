import Foundation
import GRDB
import MorselCore

private struct LoggedMeal: Sendable {
    let startedAt: String
    let kcal: Int
}

extension MealStore {
    /// Logged calories totalled per day, oldest first — the order
    /// `rollingMean` and the chart both want.
    ///
    /// Grouped by *local* day, the same convention weigh-ins use: a 23:40
    /// dinner belongs to the day you ate it, not to whatever UTC had already
    /// rolled over to. The timezone is a parameter so a test can pin it.
    ///
    /// Meals with no calorie figure are skipped rather than counted as zero. A
    /// meal you timed but never costed is not a meal of nothing, and a day made
    /// only of those is an unlogged day — see `DayIntake`.
    public func dailyIntake(timeZone: TimeZone = .current) async throws -> [DayIntake] {
        // Mapped inside the read: GRDB's `Row` is not Sendable, so it cannot
        // cross back out of the closure under Swift 6.
        let rows: [LoggedMeal] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT started_at, kcal FROM meal WHERE kcal IS NOT NULL ORDER BY started_at ASC"
            ).compactMap { row in
                guard let startedAt: String = row["started_at"], let kcal: Int = row["kcal"] else {
                    return nil
                }
                return LoggedMeal(startedAt: startedAt, kcal: kcal)
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var totals: [String: (kcal: Int, meals: Int)] = [:]
        for row in rows {
            guard let ms = millis(fromISO: row.startedAt) else { continue }
            let kcal = row.kcal

            let parts = calendar.dateComponents(
                [.year, .month, .day],
                from: Date(timeIntervalSince1970: Double(ms) / 1000)
            )
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
                continue
            }

            let key = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
            let running = totals[key] ?? (kcal: 0, meals: 0)
            totals[key] = (kcal: running.kcal + kcal, meals: running.meals + 1)
        }

        return totals
            .map { DayIntake(date: $0.key, kcal: $0.value.kcal, meals: $0.value.meals) }
            .sorted { $0.date < $1.date }
    }
}
