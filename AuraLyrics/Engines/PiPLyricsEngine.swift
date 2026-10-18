import Foundation
import UIKit
import AVKit
import SwiftUI
import CoreMedia
import CoreVideo
import Combine

// MARK: - 乘載 AVSampleBufferDisplayLayer 的容器視圖
public final class SampleBufferContainerView: UIView {
    public override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }

    public var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - PiP 懸浮歌詞引擎（LiveContainer 與跨 App 懸浮歌詞核心）
@MainActor
public final class PiPLyricsEngine: NSObject, ObservableObject {
    public static let shared = PiPLyricsEngine()

    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var isPiPPossible: Bool = false
    @Published public var currentTheme: PiPVisualTheme = .dynamicIsland

    public let containerView = SampleBufferContainerView(frame: CGRect(x: 0, y: 0, width: 360, height: 96))
    private var pipController: AVPictureInPictureController?
    private var lastRenderedLine: String = ""
    private var lastRenderedSecondary: String? = nil

    private override init() {
        super.init()
        setupPiP()
    }

    // MARK: - 初始化 Picture in Picture 控制器
    public func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPPossible = false
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: containerView.sampleBufferDisplayLayer,
            playbackDelegate: self
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true

        self.pipController = controller
        self.isPiPPossible = true
    }

    // MARK: - 開啟 / 關閉 PiP
    public func togglePiP() {
        guard let controller = pipController else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            // 先渲染當前畫面以防黑畫面
            renderCurrentFrame(
                line: AppleMusicMonitor.shared.currentLyrics.lines.indices.contains(AppleMusicMonitor.shared.currentLineIndex ?? -1)
                    ? AppleMusicMonitor.shared.currentLyrics.lines[AppleMusicMonitor.shared.currentLineIndex!].text
                    : "AuraLyrics 靈動歌詞",
                secondary: "等待歌詞同步中...",
                progress: AppleMusicMonitor.shared.playbackProgress
            )
            controller.startPictureInPicture()
        }
    }

    public func startPiP() {
        guard let controller = pipController, !controller.isPictureInPictureActive else { return }
        renderCurrentFrame(
            line: "AuraLyrics 靈動歌詞",
            secondary: "正在連接音樂播放器...",
            progress: 0.0
        )
        controller.startPictureInPicture()
    }

    public func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    // MARK: - 歌詞更新時推播新幀
    public func updateLyrics(line: String, secondaryLine: String?, progress: Double) {
        guard isPiPActive || pipController != nil else { return }

        // 若內容與上一幀相同則略過，大幅節省繪製資源
        if line == lastRenderedLine && secondaryLine == lastRenderedSecondary {
            return
        }

        lastRenderedLine = line
        lastRenderedSecondary = secondaryLine

        renderCurrentFrame(line: line, secondary: secondaryLine, progress: progress)
    }

    // MARK: - 將 SwiftUI 歌詞 View 渲染為 CMSampleBuffer
    private func renderCurrentFrame(line: String, secondary: String?, progress: Double) {
        let canvasSize = CGSize(width: 480, height: 130)
        let canvasView = PiPLyricsCanvasView(
            theme: currentTheme,
            primaryLine: line,
            secondaryLine: secondary,
            progress: progress
        )

        let renderer = ImageRenderer(content: canvasView)
        renderer.scale = 2.0 // Retina 銳利度

        guard let uiImage = renderer.uiImage, let cgImage = uiImage.cgImage else { return }

        if let sampleBuffer = createSampleBuffer(from: cgImage, size: canvasSize) {
            containerView.sampleBufferDisplayLayer.enqueue(sampleBuffer)
        }
    }

    // MARK: - CGImage 轉 CMSampleBuffer
    private func createSampleBuffer(from cgImage: CGImage, size: CGSize) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let unwrappedPixelBuffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(unwrappedPixelBuffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(unwrappedPixelBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(unwrappedPixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        context?.clear(CGRect(origin: .zero, size: size))
        context?.draw(cgImage, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, [])

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var videoInfo: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: unwrappedPixelBuffer,
            formatDescriptionOut: &videoInfo
        )

        guard let vInfo = videoInfo else { return nil }

        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: unwrappedPixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: vInfo,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PiPLyricsEngine: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isPiPActive = false
        print("[PiPLyricsEngine] 啟動失敗: \(error.localizedDescription)")
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
extension PiPLyricsEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // 使用者點擊 PiP 暫停/播放時同調
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = AppleMusicMonitor.shared.currentTrack.duration
        let current = AppleMusicMonitor.shared.currentPlaybackTimeSec
        return CMTimeRange(
            start: CMTime(seconds: current, preferredTimescale: 600),
            duration: CMTime(seconds: max(duration, 1), preferredTimescale: 600)
        )
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !AppleMusicMonitor.shared.isPlaying
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        completion()
    }
}

// MARK: - PiP 懸浮視窗專用渲染畫布（遵循 Apple HIG 深色膠囊設計）
public struct PiPLyricsCanvasView: View {
    public let theme: PiPVisualTheme
    public let primaryLine: String
    public let secondaryLine: String?
    public let progress: Double

    public var body: some View {
        ZStack {
            // 背景底層：深色高對比圓角膠囊
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

            VStack(spacing: 6) {
                // 頂部極細進度條（呼應動態島）
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: geo.size.width * max(0.02, min(progress, 1.0)), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer(minLength: 0)

                // 主歌詞行（高對比加粗 SF Pro）
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.accentColor)

                    Text(primaryLine)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }
                .padding(.horizontal, 18)

                // 次要行（雙語翻譯或下一句預覽）
                if let secondary = secondaryLine, !secondary.isEmpty && theme != .minimalLine {
                    HStack {
                        Text(secondary)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(width: 480, height: 130)
    }
}
