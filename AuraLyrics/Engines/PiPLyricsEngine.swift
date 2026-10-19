import Foundation
import UIKit
import AVKit
import SwiftUI
import Combine

// MARK: - PiP 懸浮視窗專用 ViewModel
@MainActor
public final class PiPLyricsViewModel: ObservableObject {
    public static let shared = PiPLyricsViewModel()

    @Published public var primaryLine: String = "AuraLyrics 靈動歌詞"
    @Published public var secondaryLine: String? = nil
    @Published public var progress: Double = 0.0
    @Published public var theme: PiPVisualTheme = .dynamicIsland

    private init() {}
}

// MARK: - PiP 懸浮歌詞原生畫面（Apple HIG 極致深黑動態島膠囊設計，純原文歌詞）
public struct PiPLyricsView: View {
    @ObservedObject var vm: PiPLyricsViewModel

    public init(viewModel: PiPLyricsViewModel = .shared) {
        self.vm = viewModel
    }

    public var body: some View {
        ZStack {
            // 背景底層：深黑高對比圓角膠囊 (呼應動態島同心幾何)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                )

            VStack(spacing: 0) {
                // 頂部進度條
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 2.5)
                        Capsule()
                            .fill(Color.pink)
                            .frame(width: geo.size.width * max(0.02, min(vm.progress, 1.0)), height: 2.5)
                    }
                }
                .frame(height: 2.5)
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer(minLength: 0)

                // 原文歌詞行 (居中大氣、高對比加粗，可適度折行)
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.pink)

                    Text(vm.primaryLine)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)

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
    /// 懸浮窗功能開關（預設為關閉，關閉時退到後台絕不自動跳出懸浮窗）
    @Published public var isPiPEnabled: Bool = false {
        didSet {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = isPiPEnabled
            if !isPiPEnabled && isPiPActive {
                pipController?.stopPictureInPicture()
            }
        }
    }
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
        // 預設為關閉：在使用者未主動開啟前，退到後台絕不自動彈出懸浮窗
        controller.canStartPictureInPictureAutomaticallyFromInline = false

        self.pipController = controller
        self.isPiPPossible = true
    }

    // MARK: - 開啟 / 關閉 PiP
    public func togglePiP() {
        guard let controller = pipController else { return }
        if controller.isPictureInPictureActive || isPiPEnabled {
            stopPiP()
        } else {
            startPiP()
        }
    }

    public func startPiP() {
        guard let controller = pipController else { return }
        isPiPEnabled = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        syncCurrentLyricsToViewModel()
        if !controller.isPictureInPictureActive {
            controller.startPictureInPicture()
        }
    }

    public func stopPiP() {
        isPiPEnabled = false
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
    }

    // MARK: - 更新歌詞狀態至 ViewModel
    public func updateLyrics(line: String, secondaryLine: String?, progress: Double) {
        let vm = PiPLyricsViewModel.shared
        if vm.primaryLine != line {
            vm.primaryLine = line
        }
        if vm.secondaryLine != secondaryLine {
            vm.secondaryLine = secondaryLine
        }
        if abs(vm.progress - progress) > 0.002 {
            vm.progress = progress
        }
    }

    private func syncCurrentLyricsToViewModel() {
        let monitor = AppleMusicMonitor.shared
        if let index = monitor.currentLineIndex, monitor.currentLyrics.lines.indices.contains(index) {
            let current = monitor.currentLyrics.lines[index]
            updateLyrics(line: current.text, secondaryLine: nil, progress: monitor.playbackProgress)
        } else if monitor.currentTrack.title != TrackInfo.placeholder.title {
            updateLyrics(line: "♪ \(monitor.currentTrack.title)", secondaryLine: nil, progress: monitor.playbackProgress)
        } else {
            updateLyrics(line: "AuraLyrics 靈動歌詞", secondaryLine: nil, progress: 0.0)
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
            self.isPiPEnabled = false
            pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
        }
    }

    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isPiPActive = false
            print("[PiPLyricsEngine] 啟動失敗: \(error.localizedDescription)")
        }
    }
}
