import SwiftUI

@main
struct AuraLyricsApp: App {
    init() {
        // 1. 偵測環境（LiveContainer vs 獨立側載）
        RuntimeEnvironmentDetector.shared.detectEnvironment()

        // 2. 啟動 Apple Music 播放器狀態監聽
        AppleMusicMonitor.shared.startMonitoring()

        // 3. 啟動無聲混音背景保活
        BackgroundKeepAliveManager.shared.startKeepAlive()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(.pink) // 遵循 Apple HIG 單一強調色原則，呼應 Apple Music 品牌感
        }
    }
}
