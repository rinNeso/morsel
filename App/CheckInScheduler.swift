import Foundation
import MorselData
import UserNotifications

/// Schedules the post-meal check-in and routes the reply back to its meal.
///
/// Timing is not arbitrary. GLP-1 peaks 30–60 minutes after a meal and CCK
/// around 45, both staying elevated for roughly three hours, so ~45 minutes is
/// near the peak of satiety signalling — the most informative single moment to
/// ask. Earlier catches it still rising; much later measures hunger returning,
/// which is a different question.
@MainActor
@Observable
final class CheckInScheduler: NSObject {
    /// Set when a notification is tapped: the meal whose check-in is owed.
    var pendingMealID: Int64?

    private let centre = UNUserNotificationCenter.current()
    // nonisolated: the delegate callbacks are, and these are constants.
    nonisolated private static let category = "meal-check-in"
    nonisolated private static let mealKey = "mealID"

    override init() {
        super.init()
        centre.delegate = self
    }

    /// Asked for at the first meal's end rather than at launch, so the prompt
    /// arrives with some context for what it is for.
    func requestAccessIfNeeded() async -> Bool {
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func scheduleCheckIn(mealID: Int64, afterMinutes: Int) async {
        guard await requestAccessIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "How full are you now?"
        // Asks, never nags. No "don't forget", no streak, nothing implying the
        // answer could be wrong.
        content.body = "A quick read, \(afterMinutes) minutes after your meal."
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.mealKey: mealID]

        let request = UNNotificationRequest(
            identifier: Self.identifier(for: mealID),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(afterMinutes * 60),
                repeats: false
            )
        )
        try? await centre.add(request)
    }

    /// Cancel when a meal is deleted, or its check-in already answered — a
    /// notification for a meal that no longer exists is worse than none.
    func cancelCheckIn(mealID: Int64) {
        centre.removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: mealID)])
    }

    nonisolated private static func identifier(for mealID: Int64) -> String {
        "check-in-\(mealID)"
    }
}

extension CheckInScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let mealID = info[Self.mealKey] as? Int64 ?? (info[Self.mealKey] as? NSNumber)?.int64Value
        else { return }
        await MainActor.run { pendingMealID = mealID }
    }

    /// Showing it while the app is open matters: the whole point is catching
    /// you forty-five minutes later, and you may well be holding the phone.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
