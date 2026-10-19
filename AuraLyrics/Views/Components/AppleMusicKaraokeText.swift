import SwiftUI

/// Apple Music 逐字卡拉OK流光歌詞組件
/// 支援雙層文字動態漸層羽化遮罩 (Glow Sweep Mask) 與毫秒級平滑流體渲染
public struct AppleMusicKaraokeText: View {
    let text: String
    let syllables: [LyricSyllable]?
    let isCurrent: Bool
    let lineProgress: Double // 0.0 ~ 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        text: String,
        syllables: [LyricSyllable]? = nil,
        isCurrent: Bool,
        lineProgress: Double = 0.0
    ) {
        self.text = text
        self.syllables = syllables
        self.isCurrent = isCurrent
        self.lineProgress = lineProgress
    }

    public var body: some View {
        if !isCurrent {
            // 非當前行：靜態次級文字，省電且保持背景層次深度
            Text(text)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        } else if reduceMotion {
            // 無障礙模式：高亮純白，停用流光動態
            Text(text)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.pink.opacity(0.35), radius: 8)
        } else {
            // 當前行：Apple Music 逐字流光動態渲染
            karaokeActiveView
        }
    }

    // MARK: - 雙層動態羽化流光遮罩 (Apple Music Karaoke Glow Sweep)
    private var karaokeActiveView: some View {
        ZStack(alignment: .leading) {
            // 底層文字：未唱到的暗色底襯 (Apple HIG 半透明次級白)
            Text(text)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(Color.white.opacity(0.32))
                .multilineTextAlignment(.leading)

            // 頂層文字：唱到的高亮純白發光文字，透過動態線性漸層遮罩自左向右擦亮
            Text(text)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(.white)
                .shadow(color: Color.pink.opacity(0.42), radius: 8, x: 0, y: 0)
                .multilineTextAlignment(.leading)
                .mask {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let currentX = width * max(0.0, min(lineProgress, 1.0))
                        let feather: CGFloat = 18 // 邊界柔和羽化寬度

                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: max(0, currentX - feather))

                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: feather * 2)

                            Spacer(minLength: 0)
                        }
                        .frame(width: width, alignment: .leading)
                    }
                }
        }
    }
}
