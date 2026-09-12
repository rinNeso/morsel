import SwiftUI

@main
struct MorselApp: App {
    @State private var timer = MealTimerModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(timer)
                // One app-wide accent, so making it user-customisable later is
                // a single value to swap rather than a colour threaded by hand.
                .tint(Palette.defaultAccent)
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
