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
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.pink)
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
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        // 進度條
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.15))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(Color.pink)
                                    .frame(width: geo.size.width * max(0.02, min(context.state.progress, 1.0)), height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                // 緊湊 Leading
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.pink)
                    .padding(.leading, 4)
            } compactTrailing: {
                // 緊湊 Trailing
                CompactTrailingView(currentLine: context.state.currentLine)
            } minimal: {
                // 極簡 Minimal
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.pink)
            }
        }
    }
}

// 緊湊 Trailing 視圖 (具備 minimumScaleFactor 防止窄寬度文字溢出)
struct CompactTrailingView: View {
    let currentLine: String

    var body: some View {
        Text(currentLine)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.trailing, 4)
    }
}

// 鎖定畫面歌詞視圖 (嚴格遵守 HIG 14pt 標準邊距與同心幾何)
struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.pink)
                    Text("\(context.state.trackTitle) · \(context.state.artistName)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
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
                    .foregroundColor(.pink.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(14) // HIG 標準 14pt 邊距
    }
}
