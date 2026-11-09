import Foundation
import UIKit
import AVKit
import SwiftUI
import Combine

// MARK: - PiP Lyrics View Model
@MainActor
public final class PiPLyricsViewModel: ObservableObject {
    public static let shared = PiPLyricsViewModel()

    @Published public var primaryLine: String = String(localized: "AuraLyrics 即時歌詞")
    @Published public var secondaryLine: String? = nil
    @Published public var progress: Double = 0.0
    @Published public var theme: PiPVisualTheme = .dynamicIsland

    private init() {}
}

// MARK: - Picture-in-Picture Lyrics View
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
            // Background capsule layer.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 0.8)
                )

            VStack(alignment: .leading, spacing: 4) {
                // Primary current lyric line.
                Text(vm.primaryLine)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(primaryTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Secondary preview row (next line or translation).
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

// MARK: - Picture-in-Picture Lyrics Engine via AVPictureInPictureVideoCallViewController
@MainActor
public final class PiPLyricsEngine: NSObject, ObservableObject {
    public static let shared = PiPLyricsEngine()

    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var isPiPPossible: Bool = false
    /// Enables or disables Picture-in-Picture automatic presentation.
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

    /// Source view providing layout anchor for Picture-in-Picture presentation.
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

    // MARK: - Picture in Picture Setup
    public func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPPossible = false
            return
        }

        // 1. Configure VideoCallViewController with preferred aspect size.
        let videoCallVC = AVPictureInPictureVideoCallViewController()
        videoCallVC.preferredContentSize = CGSize(width: 360, height: 90)

        // 2. Embed SwiftUI lyrics view into videoCallVC.
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

        // 3. Attach active video call source view.
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: videoCallVC
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        // Disabled by default: prevent auto-presentation until user initiates.
        controller.canStartPictureInPictureAutomaticallyFromInline = false

        self.pipController = controller
        self.isPiPPossible = true
    }

    // MARK: - Toggle / Start / Stop PiP
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

    // MARK: - Update Lyrics State In ViewModel
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
        let showTranslation = UserDefaults.standard.object(forKey: "showBilingualLyrics") as? Bool ?? true

        if let index = monitor.currentLineIndex, monitor.currentLyrics.lines.indices.contains(index) {
            let current = monitor.currentLyrics.lines[index]
            let nextLineText = (index + 1 < monitor.currentLyrics.lines.count) ? monitor.currentLyrics.lines[index + 1].text : nil
            let secondary = (showTranslation && current.translation?.isEmpty == false) ? current.translation : nextLineText
            updateLyrics(line: current.text, secondaryLine: secondary, progress: monitor.playbackProgress)
        } else if monitor.currentTrack.title != TrackInfo.placeholder.title {
            let firstLine = monitor.currentLyrics.lines.first?.text
            updateLyrics(line: monitor.currentTrack.title, secondaryLine: firstLine ?? (monitor.currentTrack.artist.isEmpty ? nil : monitor.currentTrack.artist), progress: monitor.playbackProgress)
        } else {
            updateLyrics(line: String(localized: "AuraLyrics 即時歌詞"), secondaryLine: nil, progress: 0.0)
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
