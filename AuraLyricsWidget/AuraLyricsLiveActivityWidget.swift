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
            // 鎖定畫面與 StandBy 橫向模式視圖 (自適應深淺色模式，固定視窗尺寸，符合 HIG 14pt 標準邊距)
            LockScreenLyricsView(context: context)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展開視圖 (Expanded Presentation)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        ArtworkOrIconView(artworkPath: context.state.artworkPath, size: 18)
                        Text(context.state.trackTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.artistName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .padding(.trailing, 8)
                        .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        // 主歌詞行 (向上頂掉上一句之過渡動效，固定高度 24pt)
                        Text(context.isStale ? "App 已暫停或關閉 · 點擊恢復同步" : context.state.currentLine)
                            .id(context.state.currentLine)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(context.isStale ? .white.opacity(0.6) : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height: 24, alignment: .leading)
                            .transition(.push(from: .bottom))
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: context.state.currentLine)

                        // 雙語翻譯或下一句預覽行 (向上推移過渡，固定高度 16pt，無副行時以空字串佔位保持高度恆定)
                        if !context.isStale, let secondary = context.state.secondaryLine, !secondary.isEmpty {
                            Text(secondary)
                                .id(secondary)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(height: 16, alignment: .leading)
                                .transition(.push(from: .bottom))
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: secondary)
                        } else {
                            Text(" ")
                                .font(.system(size: 13))
                                .frame(height: 16)
                                .opacity(0)
                        }
                    }
                    .frame(height: 44, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                // 緊湊 Leading 視圖 (依設定支援封面縮圖或簡潔音符)
                CompactLeadingView(
                    compactStyle: context.state.compactStyle,
                    artworkPath: context.state.artworkPath
                )
            } compactTrailing: {
                // 緊湊 Trailing 視圖 (向上推移動畫)
                CompactTrailingView(
                    currentLine: context.isStale ? "已暫停" : context.state.currentLine
                )
            } minimal: {
                // 極簡 Minimal 視圖
                ArtworkOrIconView(artworkPath: context.state.artworkPath, size: 14)
            }
        }
    }
}

// MARK: - 縮圖或圖示共用視圖
struct ArtworkOrIconView: View {
    let artworkPath: String?
    let size: CGFloat

    var body: some View {
        if let path = artworkPath,
           let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundColor(.pink)
        }
    }
}

// MARK: - 緊湊 Leading 視圖
struct CompactLeadingView: View {
    let compactStyle: String
    let artworkPath: String?

    var body: some View {
        if compactStyle == DynamicIslandCompactStyle.artworkAndText.rawValue {
            ArtworkOrIconView(artworkPath: artworkPath, size: 16)
                .padding(.leading, 4)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.pink)
                .padding(.leading, 4)
        }
    }
}

// MARK: - 緊湊 Trailing 視圖
struct CompactTrailingView: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let currentLine: String

    var body: some View {
        if isLimitedInWidth {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.pink)
                .padding(.trailing, 4)
        } else {
            Text(currentLine)
                .id(currentLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.trailing, 4)
                .transition(.push(from: .bottom))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentLine)
        }
    }
}

// MARK: - 鎖定畫面歌詞視圖 (支援深淺色自適應，絕對固定尺寸不隨歌詞跳動)
struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLight = (colorScheme == .light)
        let primaryText = isLight ? Color.black : Color.white
        let secondaryText = isLight ? Color(white: 0.45) : Color.white.opacity(0.68)
        let subtleText = isLight ? Color(white: 0.60) : Color.white.opacity(0.45)

        VStack(alignment: .leading, spacing: 6) {
            // 頂部歌曲資訊列 (固定高 18pt)
            HStack(spacing: 8) {
                ArtworkOrIconView(artworkPath: context.state.artworkPath, size: 18)

                Text("\(context.state.trackTitle) · \(context.state.artistName)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)

                Spacer()

                Text("AuraLyrics")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(subtleText)
            }
            .frame(height: 18)

            // 主歌詞行 (固定高 44pt，容納 2 行，空間鎖定不隨行數變化跳動)
            VStack(alignment: .leading, spacing: 0) {
                Text(context.isStale ? "App 已暫停或關閉 · 點擊開啟 AuraLyrics 恢復同步" : context.state.currentLine)
                    .id(context.state.currentLine)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(context.isStale ? subtleText : primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .transition(.push(from: .bottom))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: context.state.currentLine)
            }
            .frame(height: 44, alignment: .topLeading)

            // 次要行（雙語翻譯或下一句預覽，固定高 18pt，無副行時佔位保持卡片恆定高度）
            VStack(alignment: .leading, spacing: 0) {
                if !context.isStale, let secondary = context.state.secondaryLine, !secondary.isEmpty {
                    Text(secondary)
                        .id(secondary)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(Color.pink.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.push(from: .bottom))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: secondary)
                } else {
                    Text(" ")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .opacity(0)
                }
            }
            .frame(height: 18, alignment: .leading)
        }
        .padding(14) // HIG 標準 14pt 邊距
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110, alignment: .topLeading)
    }
}
