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

// MARK: - PiP 懸浮歌詞原生畫面（支援深淺色自適應：上方大字當前歌詞 + 下方小字淺灰下一句歌詞）
public struct PiPLyricsView: View {
    @ObservedObject var vm: PiPLyricsViewModel
    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: PiPLyricsViewModel = .shared) {
        self.vm = viewModel
    }

    public var body: some View {
        let isLight = (colorScheme == .light)
        let backgroundColor = isLight ? Color.white : Color.black
        let primaryTextColor = isLight ? Color.black : Color.white
        let secondaryTextColor = isLight ? Color(white: 0.50) : Color.white.opacity(0.55)
        let strokeColor = isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.16)

        ZStack {
            // 背景底層：圓角膠囊 (自適應深淺色)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 0.8)
                )

            VStack(alignment: .leading, spacing: 4) {
                // 上方大字：播放中當前歌詞（固定字級不縮放、不省略，過長時自然換行至下一行）
                Text(vm.primaryLine)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(primaryTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 下方小字：下一句歌詞（淺灰，被上方折行大字自然往下推，不縮放）
                if let nextLine = vm.secondaryLine, !nextLine.isEmpty {
                    Text(nextLine)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
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
        hostingController.view.backgroundColor = .clear
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
            let nextLineText = (index + 1 < monitor.currentLyrics.lines.count) ? monitor.currentLyrics.lines[index + 1].text : nil
            updateLyrics(line: current.text, secondaryLine: nextLineText, progress: monitor.playbackProgress)
        } else if monitor.currentTrack.title != TrackInfo.placeholder.title {
            let firstLine = monitor.currentLyrics.lines.first?.text
            updateLyrics(line: monitor.currentTrack.title, secondaryLine: firstLine ?? (monitor.currentTrack.artist.isEmpty ? nil : monitor.currentTrack.artist), progress: monitor.playbackProgress)
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
