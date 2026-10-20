import SwiftUI
import UIKit

@main
struct AuraLyricsApp: App {
    init() {
        // 1. 偵測環境（LiveContainer vs 獨立側載）
        RuntimeEnvironmentDetector.shared.detectEnvironment()

        // 2. 註冊 BGTaskScheduler 背景排程任務
        BackgroundKeepAliveManager.shared.registerBackgroundTasks()

        // 3. 清理過往異常終止殘留之孤兒即時動態
        LiveActivityLyricsEngine.shared.cleanUpOrphanedActivities()

        // 4. 註冊 App 終止監聽，於滑動關閉 App 時非阻塞式清理即時動態
        setupTerminationObserver()

        // 5. 啟動 Apple Music 播放器狀態監聽
        AppleMusicMonitor.shared.startMonitoring()

        // 6. 依據設定啟動智慧分流背景保活
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
                .tint(.pink) // 遵循 Apple HIG 單一強調色原則，呼應 Apple Music 品牌感
                .onAppear {
                    BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
                }
        }
    }
}
