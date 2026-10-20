import Foundation
import ActivityKit
import Combine

/// 運行環境診斷與判定器
@MainActor
public final class RuntimeEnvironmentDetector: ObservableObject {
    public static let shared = RuntimeEnvironmentDetector()

    @Published public private(set) var isLiveContainer: Bool = false
    @Published public private(set) var areLiveActivitiesAvailable: Bool = false
    @Published public private(set) var environmentDescription: String = String(localized: "檢測中...")

    private init() {
        detectEnvironment()
    }

    public func detectEnvironment() {
        let env = ProcessInfo.processInfo.environment

        // 1. 檢驗 LiveContainer 特徵變數與 Class
        let hasLCHome = env["LC_HOME_PATH"] != nil
        let hasLCBundle = Bundle.main.bundlePath.contains("LiveContainer")
        let hasLCClass = NSClassFromString("LCSharedUtils") != nil

        self.isLiveContainer = hasLCHome || hasLCBundle || hasLCClass

        // 2. 檢驗 ActivityKit 授權與系統可用性
        if #available(iOS 16.2, *) {
            let authInfo = ActivityAuthorizationInfo()
            // 如果在 LiveContainer 內部，即使 areActivitiesEnabled 為 true，也因為 Guest App 未向 chronod 註冊而無法啟動獨立 Widget
            self.areLiveActivitiesAvailable = authInfo.areActivitiesEnabled && !self.isLiveContainer
        } else {
            self.areLiveActivitiesAvailable = false
        }

        // 3. 彙整環境描述
        if isLiveContainer {
            self.environmentDescription = String(localized: "LiveContainer 虛擬容器環境（預設採用免 Extension 的子母畫面 PiP 懸浮膠囊）")
        } else {
            self.environmentDescription = String(localized: "獨立側載安裝環境（支援原生動態島 / 即時動態與子母畫面 PiP 雙引擎）")
        }
    }

    /// 根據當前環境取得推薦的顯示引擎
    public var recommendedEngine: DisplayEngineMode {
        if isLiveContainer {
            return .pipCapsule
        } else {
            return .both
        }
    }
}
