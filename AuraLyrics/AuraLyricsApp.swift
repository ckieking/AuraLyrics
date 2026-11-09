import SwiftUI
import UIKit

@main
struct AuraLyricsApp: App {
    init() {
        // 1. Detect runtime environment (LiveContainer vs standalone sideload).
        RuntimeEnvironmentDetector.shared.detectEnvironment()

        // 2. Register BGTaskScheduler background tasks.
        BackgroundKeepAliveManager.shared.registerBackgroundTasks()

        // 3. Clean up orphaned Live Activities from previous termination.
        LiveActivityLyricsEngine.shared.cleanUpOrphanedActivities()

        // 4. Register termination observer to clean up Live Activities on exit.
        setupTerminationObserver()

        // 5. Start Apple Music playback state monitoring.
        AppleMusicMonitor.shared.startMonitoring()

        // 6. Start background keep-alive according to configured mode.
        BackgroundKeepAliveManager.shared.startKeepAlive()
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            LiveActivityLyricsEngine.shared.cleanUpAllActivitiesSync()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(.pink) // App accent tint color.
                .onAppear {
                    BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
                }
        }
    }
}
