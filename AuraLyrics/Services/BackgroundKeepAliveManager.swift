import Foundation
import AVFoundation
import CoreLocation
import BackgroundTasks
import UIKit
import Combine

/// 背景保活管理員
/// 依據當前啟用的功能提供智慧分流保活：
/// 1. 若「即時動態」啟用：為避免 iOS 系統守護行程 sessionkitd 判定本 App 正在播放媒體而封鎖 Live Activity 背景更新
///    (Process is playing background media and forbidden to update activity)，此模式下【絕對不播放】AVAudioPlayer，
///    改採低耗電 CLLocationManager (百米精度) + BGTaskScheduler / 滾動式 UIBackgroundTask，確保行程在背景維持活躍且具備合法更新權限。
/// 2. 若僅使用「PiP 懸浮窗」且「即時動態」未開啟：啟動低音量非零 PCM Dither 之音訊保活，確保 PiP 視訊通話通道不中斷。
@MainActor
public final class BackgroundKeepAliveManager: NSObject, ObservableObject {
    public static let shared = BackgroundKeepAliveManager()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    private var audioPlayer: AVAudioPlayer?
    private let locationManager = CLLocationManager()
    private var rollingBgTask: UIBackgroundTaskIdentifier = .invalid
    private var rollingTimer: Timer?

    private override init() {
        super.init()
        setupLocationManager()
        setupLifecycleObservers()
    }

    // MARK: - 初始化定位管理器 (專供即時動態背景保活)
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
        locationManager.pausesLocationUpdatesAutomatically = false
        locationAuthorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - 監聽生命週期與系統通知
    private func setupLifecycleObservers() {
        // App 進入背景
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidEnterBackground()
            }
        }

        // App 回到前景
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillEnterForeground()
            }
        }

        // 音訊中斷通知（PiP 音訊保活專用）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                if let typeValue = typeValue,
                   let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                   type == .ended {
                    self.refreshKeepAliveMode()
                }
            }
        }
    }

    // MARK: - 註冊 BGTaskScheduler
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.auralyrics.bg.lyrics", using: .main) { task in
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            Task { @MainActor in
                // 收到背景任務排程回呼時刷新保活並排定下一次排程
                BackgroundKeepAliveManager.shared.ensureRollingBackgroundTask()
                BackgroundKeepAliveManager.shared.scheduleNextBackgroundTask()
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// 使用標準公開 API 排程下一次背景更新任務
    public func scheduleNextBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: "com.auralyrics.bg.lyrics")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundKeepAliveManager] 背景任務排程提交: \(error.localizedDescription)")
        }
    }

    // MARK: - 啟動保活
    public func startKeepAlive() {
        refreshKeepAliveMode()
    }

    // MARK: - 智慧分流刷新邏輯
    public func refreshKeepAliveMode() {
        let isLiveActivityActive = LiveActivityLyricsEngine.shared.isEnabled || LiveActivityLyricsEngine.shared.isActivityActive
        let isPiPActive = PiPLyricsEngine.shared.isPiPEnabled || PiPLyricsEngine.shared.isPiPActive

        if isLiveActivityActive {
            // 即時動態模式：停用 AVAudioPlayer 以解除 sessionkitd 封鎖，改用 Location + BGTask
            stopAudioPlayer()
            startLocationKeepAlive()
            ensureRollingBackgroundTask()
            isRunning = true
        } else if isPiPActive {
            // 僅 PiP 模式：關閉定位，改用微幅 Dither 之音訊保活
            stopLocationKeepAlive()
            endRollingBackgroundTask()
            startAudioPlayer()
            isRunning = true
        } else {
            // 兩者皆未啟用：維持輕量待機，不佔用高耗電資源
            stopLocationKeepAlive()
            endRollingBackgroundTask()
            stopAudioPlayer()
            isRunning = false
        }
    }

    // MARK: - 定位保活 (Live Activity 專用)
    private func startLocationKeepAlive() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
    }

    private func stopLocationKeepAlive() {
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingLocation()
    }

    // MARK: - 滾動式 BackgroundTask 續期 (確保持有 sessionkitd 認可之 BackgroundTask 斷言)
    private func ensureRollingBackgroundTask() {
        if rollingBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(rollingBgTask)
            rollingBgTask = .invalid
        }

        rollingBgTask = UIApplication.shared.beginBackgroundTask(withName: "com.auralyrics.bg.lyrics.keepalive") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endRollingBackgroundTask()
            }
        }

        // 定期無縫換約，維持斷言長效
        rollingTimer?.invalidate()
        rollingTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                self.ensureRollingBackgroundTask()
            }
        }

        // 透過公開 BGTaskScheduler 請求下次背景執行週期
        scheduleNextBackgroundTask()
    }

    private func endRollingBackgroundTask() {
        rollingTimer?.invalidate()
        rollingTimer = nil
        if rollingBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(rollingBgTask)
            rollingBgTask = .invalid
        }
    }

    // MARK: - 進入背景與前景事件處理
    private func handleDidEnterBackground() {
        refreshKeepAliveMode()
    }

    private func handleWillEnterForeground() {
        // 回到前景時重整狀態
        refreshKeepAliveMode()
    }

    // MARK: - 音訊保活管理 (僅供純 PiP 模式，Live Activity 模式下嚴格停用)
    private func startAudioPlayer() {
        guard audioPlayer == nil || audioPlayer?.isPlaying == false else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if audioPlayer == nil {
                let ditherData = generateLowDitherWavData(durationSeconds: 1.0)
                audioPlayer = try AVAudioPlayer(data: ditherData)
                audioPlayer?.numberOfLoops = -1
                audioPlayer?.volume = 0.01 // 非零極小音量
                audioPlayer?.prepareToPlay()
            }

            audioPlayer?.play()
        } catch {
            print("[BackgroundKeepAliveManager] 音訊保活啟動失敗: \(error.localizedDescription)")
        }
    }

    private func stopAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func stopKeepAlive() {
        stopLocationKeepAlive()
        endRollingBackgroundTask()
        stopAudioPlayer()
        isRunning = false
    }

    /// 在記憶體中動態生成含 +-1 LSB 微幅 Dither 的 16-bit 44.1kHz WAV 音訊
    /// 絕不為全零 0x00，使 CoreAudio 硬體 DSP 判定為非無效串流，同時人耳與音響完全無法察覺
    private func generateLowDitherWavData(durationSeconds: Double) -> Data {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let totalSamples = Int(Double(sampleRate) * durationSeconds)
        let dataSize = Int32(totalSamples * Int(channels) * Int(bitsPerSample / 8))

        var data = Data()

        // RIFF Header
        data.append(contentsOf: "RIFF".utf8)
        var chunkSize = dataSize + 36
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        data.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: Int32 = 16
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: Int16 = 1 // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = channels
        data.append(Data(bytes: &numChannels, count: 2))
        var sRate = sampleRate
        data.append(Data(bytes: &sRate, count: 4))
        var byteRate: Int32 = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign: Int16 = channels * (bitsPerSample / 8)
        data.append(Data(bytes: &blockAlign, count: 2))
        var bPerSample = bitsPerSample
        data.append(Data(bytes: &bPerSample, count: 2))

        // data subchunk
        data.append(contentsOf: "data".utf8)
        var dSize = dataSize
        data.append(Data(bytes: &dSize, count: 4))

        // 交替 +-1 LSB 微幅 dither
        var samples = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            samples[i] = (i % 2 == 0) ? 1 : -1
        }
        samples.withUnsafeBufferPointer { buffer in
            data.append(Data(buffer: buffer))
        }

        return data
    }
}

// MARK: - CLLocationManagerDelegate
extension BackgroundKeepAliveManager: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                if LiveActivityLyricsEngine.shared.isEnabled {
                    self.startLocationKeepAlive()
                }
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 收到定位事件（即使無實質位移），向系統證明行程仍在活躍狀態
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略微小定位失敗，保持常駐
    }
}
