import Foundation
import ActivityKit
import Combine

/// Runtime environment detector and diagnostics.
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

        // 1. Inspect LiveContainer environment variables, bundle path, and classes.
        let hasLCHome = env["LC_HOME_PATH"] != nil
        let hasLCBundle = Bundle.main.bundlePath.contains("LiveContainer")
        let hasLCClass = NSClassFromString("LCSharedUtils") != nil

        self.isLiveContainer = hasLCHome || hasLCBundle || hasLCClass

        // 2. Check ActivityKit authorization and availability.
        if #available(iOS 16.2, *) {
            let authInfo = ActivityAuthorizationInfo()
            // In LiveContainer, guest apps cannot register widget extensions with chronod.
            self.areLiveActivitiesAvailable = authInfo.areActivitiesEnabled && !self.isLiveContainer
        } else {
            self.areLiveActivitiesAvailable = false
        }

        // 3. Compile environment description string.
        if isLiveContainer {
            self.environmentDescription = String(localized: "LiveContainer 虛擬容器環境（預設採用免 Extension 的子母畫面 PiP 懸浮膠囊）")
        } else {
            self.environmentDescription = String(localized: "獨立側載安裝環境（支援原生動態島 / 即時動態與子母畫面 PiP 雙引擎）")
        }
    }

    /// Returns recommended display engine mode based on runtime detection.
    public var recommendedEngine: DisplayEngineMode {
        if isLiveContainer {
            return .pipCapsule
        } else {
            return .both
        }
    }
}
