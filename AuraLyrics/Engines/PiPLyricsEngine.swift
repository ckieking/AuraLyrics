import Foundation
import UIKit
import AVKit
import SwiftUI
import Combine

// MARK: - PiP 懸浮視窗專用 ViewModel
public final class PiPLyricsViewModel: ObservableObject {
    public static let shared = PiPLyricsViewModel()

    @Published public var primaryLine: String = "AuraLyrics 靈動歌詞"
    @Published public var secondaryLine: String? = "等待播放音樂中..."
    @Published public var progress: Double = 0.0
    @Published public var theme: PiPVisualTheme = .dynamicIsland
}

// MARK: - PiP 懸浮歌詞原生畫面（Apple HIG 深色膠囊設計，非影片格式）
public struct PiPLyricsView: View {
    @ObservedObject var vm = PiPLyricsViewModel.shared

    public var body: some View {
        ZStack {
            // 背景底層：深黑高對比圓角膠囊 (呼應動態島)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

            VStack(spacing: 4) {
                // 頂部進度條
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.pink)
                            .frame(width: geo.size.width * max(0.02, min(vm.progress, 1.0)), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer(minLength: 0)

                // 主歌詞行 (高對比加粗)
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.pink)

                    Text(vm.primaryLine)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }
                .padding(.horizontal, 14)

                // 次要行（雙語翻譯或下一句預覽）
                if let secondary = vm.secondaryLine, !secondary.isEmpty && vm.theme != .minimalLine {
                    HStack {
                        Text(secondary)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - PiP 懸浮歌詞引擎（採用 AVPictureInPictureVideoCallViewController，無黑屏、無影片控制條）
@MainActor
public final class PiPLyricsEngine: NSObject, ObservableObject {
    public static let shared = PiPLyricsEngine()

    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var isPiPPossible: Bool = false
    @Published public var currentTheme: PiPVisualTheme = .dynamicIsland {
        didSet {
            PiPLyricsViewModel.shared.theme = currentTheme
        }
    }

    /// 來源 View：嵌入主畫面作為 PiP 展開錨點
    public let sourceView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 90))
        view.backgroundColor = .clear
        return view
    }()

    private var pipVideoCallVC: AVPictureInPictureVideoCallViewController?
    private var pipController: AVPictureInPictureController?

    private override init() {
        super.init()
        setupPiP()
    }

    // MARK: - 初始化 Picture in Picture 控制器 (VideoCall 模式，純 UIView 渲染)
    public func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPPossible = false
            return
        }

        // 1. 建立 VideoCallViewController 並設定理想大小
        let videoCallVC = AVPictureInPictureVideoCallViewController()
        videoCallVC.preferredContentSize = CGSize(width: 360, height: 90)

        // 2. 將 SwiftUI View 嵌入 videoCallVC
        let hostingController = UIHostingController(rootView: PiPLyricsView())
        hostingController.view.backgroundColor = .black
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        videoCallVC.addChild(hostingController)
        videoCallVC.view.addSubview(hostingController.view)
        hostingController.didMove(toParent: videoCallVC)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: videoCallVC.view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: videoCallVC.view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: videoCallVC.view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: videoCallVC.view.bottomAnchor)
        ])

        self.pipVideoCallVC = videoCallVC

        // 3. 綁定 activeVideoCallSourceView
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: videoCallVC
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        self.pipController = controller
        self.isPiPPossible = true
    }

    // MARK: - 開啟 / 關閉 PiP
    public func togglePiP() {
        guard let controller = pipController else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            syncCurrentLyricsToViewModel()
            controller.startPictureInPicture()
        }
    }

    public func startPiP() {
        guard let controller = pipController, !controller.isPictureInPictureActive else { return }
        syncCurrentLyricsToViewModel()
        controller.startPictureInPicture()
    }

    public func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    // MARK: - 更新歌詞狀態至 ViewModel
    public func updateLyrics(line: String, secondaryLine: String?, progress: Double) {
        PiPLyricsViewModel.shared.primaryLine = line
        PiPLyricsViewModel.shared.secondaryLine = secondaryLine
        PiPLyricsViewModel.shared.progress = progress
    }

    private func syncCurrentLyricsToViewModel() {
        let monitor = AppleMusicMonitor.shared
        if let index = monitor.currentLineIndex, monitor.currentLyrics.lines.indices.contains(index) {
            let current = monitor.currentLyrics.lines[index]
            var sec: String? = nil
            if let trans = current.translation, !trans.isEmpty {
                sec = trans
            } else if index + 1 < monitor.currentLyrics.lines.count {
                sec = monitor.currentLyrics.lines[index + 1].text
            }
            updateLyrics(line: current.text, secondaryLine: sec, progress: monitor.playbackProgress)
        } else if monitor.currentTrack.title != "尚未播放音樂" {
            updateLyrics(line: monitor.currentTrack.title, secondaryLine: monitor.currentTrack.artist, progress: monitor.playbackProgress)
        } else {
            updateLyrics(line: "AuraLyrics 靈動歌詞", secondaryLine: "請在 Apple Music 開始播放音樂", progress: 0.0)
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PiPLyricsEngine: AVPictureInPictureControllerDelegate {
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
        }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }

    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isPiPActive = false
            print("[PiPLyricsEngine] 啟動失敗: \(error.localizedDescription)")
        }
    }
}
