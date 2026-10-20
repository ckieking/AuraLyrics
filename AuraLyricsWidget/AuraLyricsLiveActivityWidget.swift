import ActivityKit
import WidgetKit
import SwiftUI

@main
struct AuraLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        AuraLyricsLiveActivityWidget()
    }
}

public struct AuraLyricsLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            // 鎖定畫面與 StandBy 橫向模式視圖 (遵循 HIG 14pt 標準邊距)
            LockScreenLyricsView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展開視圖 (Expanded Presentation)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ArtworkThumbnailView(path: context.state.artworkPath, size: 28, cornerRadius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.trackTitle)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(context.state.artistName)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        if !context.state.isPlaying {
                            Text("暫停")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 主歌詞高亮行
                        Text(context.state.currentLine)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        // 雙語翻譯或下一句
                        if let secondary = context.state.secondaryLine, !secondary.isEmpty {
                            Text(secondary)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        // 原生 60fps 平滑進度條
                        LyricsProgressBar(context: context)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                // 緊湊 Leading：依據使用者偏好動態呈現封面縮圖 / 音符 / 波形
                Group {
                    if context.state.compactStyle == DynamicIslandCompactStyle.artworkAndText.rawValue {
                        ArtworkThumbnailView(path: context.state.artworkPath, size: 19, cornerRadius: 5)
                            .padding(.leading, 2)
                    } else if context.state.compactStyle == DynamicIslandCompactStyle.minimalWaveform.rawValue {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.pink)
                            .padding(.leading, 4)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.pink)
                            .padding(.leading, 4)
                    }
                }
            } compactTrailing: {
                // 緊湊 Trailing：依據使用者偏好呈現歌詞文字或極簡波形
                Group {
                    if context.state.compactStyle == DynamicIslandCompactStyle.minimalWaveform.rawValue {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.pink)
                            .padding(.trailing, 4)
                    } else {
                        CompactTrailingView(currentLine: context.state.currentLine)
                    }
                }
            } minimal: {
                // 極簡 Minimal (多 App 同時使用動態島時)
                if context.state.compactStyle == DynamicIslandCompactStyle.artworkAndText.rawValue {
                    ArtworkThumbnailView(path: context.state.artworkPath, size: 16, cornerRadius: 4)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.pink)
                }
            }
        }
    }
}

// MARK: - 專輯封面微縮圖視圖（自帶快取檔案讀取與 SF Symbol 優雅回退）
struct ArtworkThumbnailView: View {
    let path: String?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if let path = path,
           let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.pink.opacity(0.18))
                Image(systemName: "music.note")
                    .font(.system(size: max(8, size * 0.52), weight: .bold))
                    .foregroundColor(.pink)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - 原生 60fps 平滑進度條（零 IPC 傳輸負荷）
struct LyricsProgressBar: View {
    let context: ActivityViewContext<LyricsActivityAttributes>

    var body: some View {
        if context.state.progressEngine == LiveActivityProgressEngine.smoothTimer.rawValue && context.state.isPlaying {
            ProgressView(
                timerInterval: context.state.playbackStart...context.state.playbackEnd,
                countsDown: false
            )
            .progressViewStyle(.linear)
            .tint(.pink)
            .scaleEffect(x: 1, y: 0.7, anchor: .center)
            .frame(height: 3)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 3)
                    Capsule()
                        .fill(Color.pink)
                        .frame(
                            width: geo.size.width * max(0.02, min(context.state.progress, 1.0)),
                            height: 3
                        )
                }
            }
            .frame(height: 3)
        }
    }
}

// MARK: - 緊湊 Trailing 視圖 (依據 Apple HIG 支援 isDynamicIslandLimitedInWidth 橫向窄寬度適配)
struct CompactTrailingView: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let currentLine: String

    var body: some View {
        if isLimitedInWidth {
            // 橫向或有限寬度：收斂為 28pt 內精巧波形圖示，防止文字被硬性截斷
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.pink)
                .padding(.trailing, 4)
        } else {
            Text(currentLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.trailing, 4)
        }
    }
}

// MARK: - 鎖定畫面歌詞視圖 (嚴格遵守 HIG 14pt 標準邊距與同心幾何)
struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ArtworkThumbnailView(path: context.state.artworkPath, size: 24, cornerRadius: 6)
                HStack(spacing: 4) {
                    Text("\(context.state.trackTitle) · \(context.state.artistName)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(1)
                }
                Spacer()
                Text("AuraLyrics")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }

            Text(context.state.currentLine)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if let secondary = context.state.secondaryLine, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.pink.opacity(0.92))
                    .lineLimit(1)
            }

            LyricsProgressBar(context: context)
                .padding(.top, 2)
        }
        .padding(14) // HIG 標準 14pt 邊距
    }
}
