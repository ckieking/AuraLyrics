import SwiftUI

/// Apple Music 逐字卡拉OK流光與節奏律動歌詞組件
/// 支援獨立音節流式自動換行 (SyllableFlowLayout)、真實字寬動態羽化遮罩、
/// 音節微上浮 (Lift) 與長音呼吸光暈 (Sustained Note Glow)
public struct AppleMusicKaraokeText: View {
    let text: String
    let syllables: [LyricSyllable]?
    let isCurrent: Bool
    let currentPlaybackTimeMs: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        text: String,
        syllables: [LyricSyllable]? = nil,
        isCurrent: Bool,
        currentPlaybackTimeMs: Int = 0
    ) {
        self.text = text
        self.syllables = syllables
        self.isCurrent = isCurrent
        self.currentPlaybackTimeMs = currentPlaybackTimeMs
    }

    public var body: some View {
        if !isCurrent {
            // 非當前行：靜態次級文字，極致省電且保持背景層次深度
            Text(text)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        } else if reduceMotion || syllables == nil || syllables?.isEmpty == true {
            // 當前行但無逐字資料（或開啟減弱動態）：
            // Apple Music 經典整行高亮純白搭配粉光微暈，誠實呈現、絕不假裝勻速掃過避免掉拍
            Text(text)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.pink.opacity(0.38), radius: 8, x: 0, y: 0)
        } else if let validSyllables = syllables, !validSyllables.isEmpty {
            // 當前行且具備逐字音節時間軸：以 SyllableFlowLayout 進行音節獨立渲染
            SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 6) {
                ForEach(validSyllables) { syl in
                    SyllablePieceView(
                        syllable: syl,
                        currentPlayMs: currentPlaybackTimeMs
                    )
                }
            }
        }
    }
}

// MARK: - 單音節獨立流光與律動渲染單元
private struct SyllablePieceView: View {
    let syllable: LyricSyllable
    let currentPlayMs: Int

    private var startMs: Int { syllable.timeMs }
    private var durationMs: Int { max(10, syllable.durationMs) }
    private var endMs: Int { startMs + durationMs }

    /// 音節播放進度 0.0 ~ 1.0
    private var progress: Double {
        if currentPlayMs <= startMs { return 0.0 }
        if currentPlayMs >= endMs { return 1.0 }
        return Double(currentPlayMs - startMs) / Double(durationMs)
    }

    /// 是否正在發音
    private var isSinging: Bool {
        currentPlayMs >= startMs && currentPlayMs < endMs
    }

    /// 是否為拉長音（>= 600ms）
    private var isLongNote: Bool {
        syllable.durationMs >= 600
    }

    var body: some View {
        // 純空白音節直接保留版面間隙
        if syllable.text.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(syllable.text)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .hidden()
        } else {
            // 律動物理回饋：發音時微幅上浮 (Syllable Lift)，唱完後維持輕微浮起
            let liftY: CGFloat = {
                if progress <= 0 { return 0 }
                if isSinging {
                    return -1.0 - 1.4 * sin(progress * .pi)
                }
                return -1.0
            }()

            // 長音呼吸微放大 (Sustained Note Scale)
            let scale: CGFloat = {
                if isSinging && isLongNote {
                    return 1.0 + 0.05 * sin(progress * .pi)
                }
                return 1.0
            }()

            ZStack(alignment: .leading) {
                // 底層：未唱到的暗色底襯（Apple HIG 32% 半透明次級白）
                Text(syllable.text)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundColor(Color.white.opacity(0.32))

                // 頂層：唱到的高亮純白發光文字（僅在 progress > 0 時渲染，徹底根除單字開頭提前亮起問題）
                if progress > 0 {
                    Text(syllable.text)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundColor(.white)
                        .shadow(
                            color: (isSinging && isLongNote) ? Color.pink.opacity(0.65) : Color.pink.opacity(0.38),
                            radius: (isSinging && isLongNote) ? 10 : 8,
                            x: 0,
                            y: 0
                        )
                        .mask {
                            if progress >= 1.0 {
                                // 唱完：全字純白實心填滿
                                Color.white
                            } else {
                                // 正在唱：自左向右動態線性漸層羽化推進
                                GeometryReader { geo in
                                    let width = geo.size.width
                                    let currentX = width * progress
                                    let feather: CGFloat = 4

                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(Color.white)
                                            .frame(width: max(0, currentX - feather / 2))

                                        LinearGradient(
                                            colors: [Color.white, Color.clear],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                        .frame(width: feather)

                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: width, alignment: .leading)
                                }
                            }
                        }
                }
            }
            .offset(y: liftY)
            .scaleEffect(scale)
        }
    }
}

// MARK: - 音節流式自動換行排版 (SwiftUI Layout Protocol)
/// 解決多行歌詞換行與不同字寬對齊問題，確保唱完第一行才依序點亮第二行
public struct SyllableFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 0
    public var verticalSpacing: CGFloat = 6

    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 6) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: currentY + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
