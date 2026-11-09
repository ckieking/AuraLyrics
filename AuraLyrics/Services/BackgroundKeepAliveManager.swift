import Foundation
import AVFoundation
import CoreLocation
import BackgroundTasks
import UIKit
import Combine

/// Background execution and keep-alive manager.
/// Coordinates background execution strategies based on active display engines:
/// - When Live Activities are active, audio playback is stopped to allow Live Activity background updates; location updates and rolling background tasks maintain execution.
/// - When only Picture-in-Picture is active, inaudible PCM dither audio keeps the background execution pipeline active.
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

    // MARK: - Location Manager Setup
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
        locationManager.pausesLocationUpdatesAutomatically = false
        locationAuthorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Lifecycle Observers
    private func setupLifecycleObservers() {
        // Did enter background
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidEnterBackground()
            }
        }

        // Will enter foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillEnterForeground()
            }
        }

        // Audio session interruption notification
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

    // MARK: - BGTaskScheduler Registration
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.auralyrics.bg.lyrics", using: .main) { task in
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            Task { @MainActor in
                // Refresh keep-alive and schedule next background task cycle.
                BackgroundKeepAliveManager.shared.ensureRollingBackgroundTask()
                BackgroundKeepAliveManager.shared.scheduleNextBackgroundTask()
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// Schedules next background refresh task via BGTaskScheduler.
    public func scheduleNextBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: "com.auralyrics.bg.lyrics")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundKeepAliveManager] 背景任務排程提交: \(error.localizedDescription)")
        }
    }

    // MARK: - Start Keep Alive
    public func startKeepAlive() {
        refreshKeepAliveMode()
    }

    // MARK: - Keep Alive Routing
    public func refreshKeepAliveMode() {
        let isLiveActivityActive = LiveActivityLyricsEngine.shared.isEnabled || LiveActivityLyricsEngine.shared.isActivityActive
        let isPiPActive = PiPLyricsEngine.shared.isPiPEnabled || PiPLyricsEngine.shared.isPiPActive

        if isLiveActivityActive {
            // Live Activity mode: disable AVAudioPlayer and use location updates + background tasks.
            stopAudioPlayer()
            startLocationKeepAlive()
            ensureRollingBackgroundTask()
            isRunning = true
        } else if isPiPActive {
            // PiP mode: stop location updates and enable dither audio playback.
            stopLocationKeepAlive()
            endRollingBackgroundTask()
            startAudioPlayer()
            isRunning = true
        } else {
            // Inactive: release keep-alive resources.
            stopLocationKeepAlive()
            endRollingBackgroundTask()
            stopAudioPlayer()
            isRunning = false
        }
    }

    // MARK: - Location Keep-Alive
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

    // MARK: - Rolling Background Task Assertion
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

        // Periodically renew background task assertion.
        rollingTimer?.invalidate()
        rollingTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                self.ensureRollingBackgroundTask()
            }
        }

        // Schedule next task execution cycle via BGTaskScheduler.
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

    // MARK: - Lifecycle Handlers
    private func handleDidEnterBackground() {
        refreshKeepAliveMode()
    }

    private func handleWillEnterForeground() {
        // Re-evaluate keep-alive mode upon returning to foreground.
        refreshKeepAliveMode()
    }

    // MARK: - Audio Keep-Alive
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
                audioPlayer?.volume = 0.01 // Non-zero minimal volume.
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

    /// Generates 16-bit 44.1kHz mono PCM WAV data containing alternating +/-1 LSB dither samples.
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

        // Alternating +/-1 LSB dither
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
        // Process location updates to maintain execution state.
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Suppress transient location lookup errors.
    }
}
