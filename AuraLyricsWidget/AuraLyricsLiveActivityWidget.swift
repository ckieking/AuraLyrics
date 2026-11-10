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
            // Lock screen and StandBy mode presentation.
            LockScreenLyricsView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Dynamic Island expanded presentation.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        ArtworkOrIconView(
                            artworkPath: context.state.artworkPath,
                            artworkData: context.state.artworkData,
                            size: 18
                        )
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
                        .foregroundColor(Color(white: 0.7))
                        .lineLimit(1)
                        .padding(.trailing, 8)
                        .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Primary current lyric line with vertical push transition.
                        Text(context.isStale ? String(localized: "App 已暫停或關閉 · 點擊恢復同步") : context.state.currentLine)
                            .id(context.state.currentLine)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(context.isStale ? Color(white: 0.6) : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .transition(.push(from: .bottom))
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: context.state.currentLine)

                        // Secondary lyric line (translation or next line preview).
                        if !context.isStale, let secondary = context.state.secondaryLine, !secondary.isEmpty {
                            Text(secondary)
                                .id(secondary)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(Color.pink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .transition(.push(from: .bottom))
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                // Compact leading presentation.
                CompactLeadingView(
                    compactStyle: context.state.compactStyle,
                    artworkPath: context.state.artworkPath,
                    artworkData: context.state.artworkData
                )
            } compactTrailing: {
                // Compact trailing presentation with push animation.
                CompactTrailingView(
                    currentLine: context.isStale ? String(localized: "已暫停") : context.state.currentLine
                )
            } minimal: {
                // Minimal presentation.
                ArtworkOrIconView(
                    artworkPath: context.state.artworkPath,
                    artworkData: context.state.artworkData,
                    size: 14
                )
            }
            .keylineTint(Color.pink.opacity(0.5))
        }
    }
}

// MARK: - Artwork Or Icon View
struct ArtworkOrIconView: View {
    let artworkPath: String?
    let artworkData: Data?
    let size: CGFloat

    init(artworkPath: String? = nil, artworkData: Data? = nil, size: CGFloat) {
        self.artworkPath = artworkPath
        self.artworkData = artworkData
        self.size = size
    }

    var body: some View {
        if let path = artworkPath,
           let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else if let data = artworkData,
                  let uiImage = UIImage(data: data) {
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

// MARK: - Compact Leading View
struct CompactLeadingView: View {
    let compactStyle: String
    let artworkPath: String?
    let artworkData: Data?

    init(compactStyle: String, artworkPath: String? = nil, artworkData: Data? = nil) {
        self.compactStyle = compactStyle
        self.artworkPath = artworkPath
        self.artworkData = artworkData
    }

    var body: some View {
        if compactStyle == DynamicIslandCompactStyle.artworkAndText.rawValue {
            ArtworkOrIconView(artworkPath: artworkPath, artworkData: artworkData, size: 16)
                .padding(.leading, 4)
        } else if compactStyle == DynamicIslandCompactStyle.iconAndText.rawValue {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.pink)
                .padding(.leading, 4)
        }
    }
}

// MARK: - Compact Trailing View
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

// MARK: - Lock Screen Lyrics View
struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLight = context.state.isLightMode || (colorScheme == .light)
        let primaryText = isLight ? Color.black : Color.white
        let secondaryText = isLight ? Color(white: 0.35) : Color.white.opacity(0.68)
        let subtleText = isLight ? Color(white: 0.50) : Color.white.opacity(0.45)
        let backgroundTint: Color? = isLight ? Color.white : nil

        VStack(alignment: .leading, spacing: 6) {
            // Top track header.
            HStack(spacing: 8) {
                ArtworkOrIconView(
                    artworkPath: context.state.artworkPath,
                    artworkData: context.state.artworkData,
                    size: 18
                )

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

            // Lyric text rows.
            VStack(alignment: .leading, spacing: 4) {
                Text(context.isStale ? String(localized: "App 已暫停或關閉 · 點擊開啟 AuraLyrics 恢復同步") : context.state.currentLine)
                    .id(context.state.currentLine)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(context.isStale ? subtleText : primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .transition(.push(from: .bottom))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: context.state.currentLine)

                if !context.isStale, let secondary = context.state.secondaryLine, !secondary.isEmpty {
                    Text(secondary)
                        .id(secondary)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(Color.pink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.push(from: .bottom))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
        .background(isLight ? Color.white : Color.clear)
        .activityBackgroundTint(backgroundTint)
        .activitySystemActionForegroundColor(isLight ? Color.black : Color.white)
    }
}
