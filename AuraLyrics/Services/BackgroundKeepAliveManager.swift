import Foundation
import AVFoundation
import Combine
import UIKit

/// 背景保活管理員
/// 透過在記憶體中生成極小體積的無聲 PCM 音訊，配合 `.playback` 與 `.mixWithOthers`，
/// 確保 App 在背景或鎖定畫面時持續運作，絕不中斷或干擾 Apple Music 音樂播放。
@MainActor
public final class BackgroundKeepAliveManager: ObservableObject {
    public static let shared = BackgroundKeepAliveManager()

    @Published public private(set) var isRunning: Bool = false
    private var audioPlayer: AVAudioPlayer?

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        // 音訊中斷通知（如來電結束後恢復）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let typeValue = typeValue,
                   let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                   type == .ended {
                    self.ensureRunning()
                }
            }
        }

        // 音訊路由變更通知（如藍牙耳機連接/中斷）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureRunning()
            }
        }

        // 進入背景通知（確保音訊通道處於活躍運作狀態）
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureRunning()
            }
        }
    }

    public func startKeepAlive() {
        ensureRunning()
    }

    public func ensureRunning() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if audioPlayer == nil {
                let silentData = generateSilentWavData(durationSeconds: 1.0)
                audioPlayer = try AVAudioPlayer(data: silentData)
                audioPlayer?.numberOfLoops = -1 // 無限循環
                audioPlayer?.volume = 0.0001 // 極微小音量維持 CoreAudio 運作，防止系統休眠
                audioPlayer?.prepareToPlay()
            }

            if audioPlayer?.isPlaying != true {
                let success = audioPlayer?.play() ?? false
                isRunning = success
            } else {
                isRunning = true
            }
        } catch {
            print("[BackgroundKeepAliveManager] 啟動背景保活失敗: \(error.localizedDescription)")
            isRunning = false
        }
    }

    public func stopKeepAlive() {
        audioPlayer?.stop()
        audioPlayer = nil
        isRunning = false
    }

    /// 在記憶體中動態生成標準 16-bit 44.1kHz 單聲道無聲 WAV 格式資料
    private func generateSilentWavData(durationSeconds: Double) -> Data {
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

        // 填充零（無聲音訊）
        let zeroBytes = [UInt8](repeating: 0, count: Int(dataSize))
        data.append(contentsOf: zeroBytes)

        return data
    }
}
