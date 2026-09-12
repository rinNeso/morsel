import MorselData
import SwiftUI

@main
struct MorselApp: App {
    @State private var timer: MealTimerModel
    @State private var settings: AppSettings
    private let store: MealStore?

    init() {
        // A store that fails to open shouldn't take the timer down with it —
        // the timer is the product, persistence is instrumentation.
        let store = try? MealStore(path: MealStore.defaultURL().path(percentEncoded: false))
        self.store = store
        _timer = State(initialValue: MealTimerModel(store: store))
        _settings = State(initialValue: AppSettings(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(timer)
                .environment(settings)
                .environment(\.mealStore, store)
                // One app-wide accent, so every control picks it up without a
                // colour being threaded through by hand.
                .tint(settings.accent)
                .preferredColorScheme(settings.themeMode.colorScheme)
                .task { await settings.load() }
        }
    }
}

struct RootView: View {
    var body: some View {
        // Liquid Glass, the floating capsule shape, and minimize-on-scroll all
        // come from the system here — no reimplementation.
        TabView {
            Tab("Timer", systemImage: "timer") {
                TimerScreen()
            }
            Tab("History", systemImage: "list.bullet") {
                HistoryScreen()
            }
            Tab("Settings", systemImage: "paintpalette") {
                SettingsScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

private struct MealStoreKey: EnvironmentKey {
    static let defaultValue: MealStore? = nil
}

extension EnvironmentValues {
    var mealStore: MealStore? {
        get { self[MealStoreKey.self] }
        set { self[MealStoreKey.self] = newValue }
    }
}
