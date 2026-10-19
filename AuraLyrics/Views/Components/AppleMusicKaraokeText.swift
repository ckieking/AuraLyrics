import SwiftUI

/// Apple Music 逐字卡拉OK流光與空間立體懸浮光暈組件 (Spatial Depth Float & Bloom Glow)
/// 移除文字放大縮放，全面升級為 32pt 蘋果官方大字 (SF Pro)；
/// 實作 Apple Music 標誌性物理動態：極細微上浮結合多層空間光暈，營造向螢幕方向懸浮浮出的高級立體景深感
public struct AppleMusicKaraokeText: View {
    let text: String
    let syllables: [LyricSyllable]?
    let isCurrent: Bool
    let currentPlaybackTimeMs: Int
    let blurRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        text: String,
        syllables: [LyricSyllable]? = nil,
        isCurrent: Bool,
        currentPlaybackTimeMs: Int = 0,
        blurRadius: CGFloat = 0
    ) {
        self.text = text
        self.syllables = syllables
        self.isCurrent = isCurrent
        self.currentPlaybackTimeMs = currentPlaybackTimeMs
        self.blurRadius = blurRadius
    }

    public var body: some View {
        Group {
            if syllables == nil || syllables?.isEmpty == true || reduceMotion {
                // 普通行級時間軸（或減弱動態）：
                // 無論是否唱到，字級與字重嚴格統一為 SF Pro 32pt Bold，折行點完全一致，絕不因播放而突發性換行
                // 非當前行零陰影開銷，僅當前行綻放立體粉光
                Text(text)
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(isCurrent ? .white : Color.white.opacity(0.35))
                    .multilineTextAlignment(.leading)
                    .shadow(color: isCurrent ? Color.white.opacity(0.45) : .clear, radius: isCurrent ? 5 : 0, x: 0, y: 0)
                    .shadow(color: isCurrent ? Color.pink.opacity(0.55) : .clear, radius: isCurrent ? 14 : 0, x: 0, y: 0)
                    .blur(radius: isCurrent ? 0 : blurRadius)
            } else if let validSyllables = syllables, !validSyllables.isEmpty {
                // 逐字音節時間軸：
                // 當前行與非當前行全面採用完全相同的 32pt SyllableFlowLayout！
                // 若長歌詞需要折行，在尚未唱到時就已經預先折好，唱到時文字幾何位置 0 偏移，原地發光
                if !isCurrent {
                    // 非當前行：採用 Equatable 隔離視圖，並透過 drawingGroup() 預合成為單一 Metal 紋理快取
                    // 當模糊半徑未改變時（如距離 >= 3 行的所有歌詞），SwiftUI 100% 複用 GPU 紋理，穩跑 120fps！
                    InactiveSyllableLyricView(
                        text: text,
                        syllables: validSyllables,
                        blurRadius: blurRadius
                    )
                } else {
                    let continuousFocus = calculateContinuousFocus(
                        currentPlayMs: currentPlaybackTimeMs,
                        syllables: validSyllables
                    )

                    SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 10) {
                        ForEach(Array(validSyllables.enumerated()), id: \.element.id) { idx, syl in
                            ActiveSyllablePieceView(
                                syllable: syl,
                                sylIndex: idx,
                                continuousFocus: continuousFocus,
                                currentPlayMs: currentPlaybackTimeMs
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 計算全行 100% 連續平滑的音節能量焦點 (Continuous Focus Tracker)
    private func calculateContinuousFocus(currentPlayMs: Int, syllables: [LyricSyllable]) -> Double {
        guard let first = syllables.first else { return 0.0 }
        guard let last = syllables.last else { return 0.0 }

        let firstStart = first.timeMs
        let lastEnd = last.timeMs + max(5, last.durationMs)

        // 若尚未開始唱本行：焦點平滑停在行首外側
        if currentPlayMs <= firstStart {
            let diff = Double(firstStart - currentPlayMs) / 600.0
            return max(-3.0, 0.0 - diff)
        }

        // 若已唱完本行：焦點平滑移向行尾外側
        if currentPlayMs >= lastEnd {
            let diff = Double(currentPlayMs - lastEnd) / 600.0
            return min(Double(syllables.count) + 2.0, Double(syllables.count - 1) + 1.0 + diff)
        }

        // 處於唱段中：尋找當前所在的精確時空區間，並進行平滑插值
        for i in 0..<syllables.count {
            let cur = syllables[i]
            let curEnd = cur.timeMs + max(5, cur.durationMs)
            if currentPlayMs >= cur.timeMs && currentPlayMs <= curEnd {
                let ratio = Double(currentPlayMs - cur.timeMs) / Double(max(1, cur.durationMs))
                return Double(i) + min(max(ratio, 0.0), 1.0)
            }

            // 若落在當前音節與下一個音節之間的停頓空隙，進行線性插值過渡
            if i + 1 < syllables.count {
                let next = syllables[i + 1]
                if currentPlayMs > curEnd && currentPlayMs < next.timeMs {
                    let gapDuration = Double(next.timeMs - curEnd)
                    let gapProgress = Double(currentPlayMs - curEnd) / max(1.0, gapDuration)
                    return Double(i) + 1.0 + gapProgress * (Double(i + 1) - Double(i) - 1.0)
                }
            }
        }
        return 0.0
    }
}

// MARK: - 當前播放行單音節渲染組件 (固定佈局尺寸 + 空間立體浮現 + 多層光暈)
private struct ActiveSyllablePieceView: View {
    let syllable: LyricSyllable
    let sylIndex: Int
    let continuousFocus: Double
    let currentPlayMs: Int

    /// 單音節擦亮進度 0.0 ~ 1.0
    private var sylProgress: Double {
        if currentPlayMs <= syllable.timeMs { return 0.0 }
        let endMs = syllable.timeMs + max(5, syllable.durationMs)
        if currentPlayMs >= endMs { return 1.0 }
        return Double(currentPlayMs - syllable.timeMs) / Double(max(5, syllable.durationMs))
    }

    /// 高斯連鎖影響力 (0.0 ~ 1.0)
    private var gaussianWeight: Double {
        let dist = abs(Double(sylIndex) - continuousFocus)
        return exp(-(dist * dist) / (2.0 * 2.0 * 2.0))
    }

    var body: some View {
        let isWhitespace = syllable.text.trimmingCharacters(in: .whitespaces).isEmpty
        let g = gaussianWeight
        let p = sylProgress

        // 極細微 Y 軸微上浮 (Micro-Lift)
        let liftY: CGFloat = {
            if currentPlayMs < syllable.timeMs {
                return -1.0 * g
            } else if currentPlayMs >= (syllable.timeMs + max(5, syllable.durationMs)) {
                return -0.8
            } else {
                let localWave = sin(p * .pi)
                return -0.8 - 0.6 * localWave
            }
        }()

        if isWhitespace {
            // 純空白保留原生字元寬度間隔
            Text(syllable.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .hidden()
        } else {
            // 關鍵排版鎖定：
            // Base View 嚴格採用與 InactiveSyllableLyricView 100% 相同的純文字，
            // 確保 sizeThatFits 尺寸完全鎖死恆等，折行點原地鎖定！
            // 所有光暈、陰影、微浮均在 .overlay 內呈現，絕不影響外部 Layout 的 sizeThatFits，
            // 徹底根除播放時歌詞因陰影或字距微調擴展而從兩行爆成三行的排版瑕疵！
            Text(syllable.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .foregroundColor(Color.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        // 1. 底層鄰近連鎖粉紅微光（Bloom 連鎖）
                        if g > 0.04 {
                            Text(syllable.text)
                                .font(.system(size: 32, weight: .bold, design: .default))
                                .foregroundColor(Color.white.opacity(0.35))
                                .shadow(
                                    color: Color.pink.opacity(0.40 * g),
                                    radius: 10 * g,
                                    x: 0,
                                    y: 0
                                )
                        }

                        // 2. 頂層高亮純白發光文字（Core Highlight + Depth Pop Glow + Ambient Bloom）
                        if p > 0 {
                            Text(syllable.text)
                                .font(.system(size: 32, weight: .bold, design: .default))
                                .foregroundColor(.white)
                                // 第一層：緊貼文字的純白立體高光（Core Highlight）
                                .shadow(
                                    color: Color.white.opacity(0.65 * g),
                                    radius: 5 * g,
                                    x: 0,
                                    y: 0
                                )
                                // 第二層：向螢幕前方浮現的立體粉紅光暈（Depth Pop Glow）
                                .shadow(
                                    color: Color.pink.opacity(0.60 + 0.35 * g),
                                    radius: 14 + 8 * g,
                                    x: 0,
                                    y: 0
                                )
                                // 第三層：空氣感大範圍環境散射暈光（Ambient Bloom）
                                .shadow(
                                    color: Color.pink.opacity(0.35 * g),
                                    radius: 26 * g,
                                    x: 0,
                                    y: 0
                                )
                                .opacity(min(1.0, max(0.0, p)))
                        }
                    }
                    .offset(y: liftY)
                }
        }
    }
}

// MARK: - 音節流式自動換行排版 (SwiftUI Layout Protocol)
/// 解決多行歌詞換行與不同字寬對齊問題，確保唱完第一行才依序點亮第二行
public struct SyllableFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 0
    public var verticalSpacing: CGFloat = 10

    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 10) {
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

// MARK: - 非當前播放行 Equatable 快取視圖 (預合成 Metal 紋理並執行階梯景深模糊)
private struct InactiveSyllableLyricView: View, Equatable {
    let text: String
    let syllables: [LyricSyllable]
    let blurRadius: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text &&
        lhs.syllables.count == rhs.syllables.count &&
        lhs.blurRadius == rhs.blurRadius
    }

    var body: some View {
        SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 10) {
            ForEach(syllables) { syl in
                if syl.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(syl.text)
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .hidden()
                } else {
                    Text(syl.text)
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .foregroundColor(Color.white.opacity(0.35))
                }
            }
        }
        .drawingGroup()
        .blur(radius: blurRadius)
    }
}
