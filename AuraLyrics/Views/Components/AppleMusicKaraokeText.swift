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
                    let lineChars = buildLineChars(from: validSyllables)
                    let continuousFocus = calculateContinuousFocus(currentPlayMs: currentPlaybackTimeMs, lineChars: lineChars)

                    SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 10) {
                        ForEach(validSyllables) { syl in
                            let charsInSyllable = lineChars.filter { $0.syllableId == syl.id }
                            SyllablePieceView(
                                syllable: syl,
                                chars: charsInSyllable,
                                continuousFocus: continuousFocus,
                                currentPlayMs: currentPlaybackTimeMs
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 構建整行字元時間軸映射
    private func buildLineChars(from syllables: [LyricSyllable]) -> [LineCharInfo] {
        var result: [LineCharInfo] = []
        var globalIdx = 0

        for syl in syllables {
            let chars = Array(syl.text)
            guard !chars.isEmpty else { continue }
            let count = chars.count
            let duration = max(10, syl.durationMs)
            let step = max(5, duration / count)

            for (i, char) in chars.enumerated() {
                let charStart = syl.timeMs + i * step
                result.append(LineCharInfo(
                    id: globalIdx,
                    text: String(char),
                    syllableId: syl.id,
                    startMs: charStart,
                    durationMs: step
                ))
                globalIdx += 1
            }
        }
        return result
    }

    // MARK: - 計算全行 100% 連續平滑的能量焦點 (Continuous Focus Tracker)
    private func calculateContinuousFocus(currentPlayMs: Int, lineChars: [LineCharInfo]) -> Double {
        guard let first = lineChars.first else { return 0.0 }
        guard let last = lineChars.last else { return 0.0 }

        // 若尚未開始唱本行：焦點平滑停在行首外側
        if currentPlayMs <= first.startMs {
            let diff = Double(first.startMs - currentPlayMs) / 600.0
            return max(-3.0, Double(first.id) - diff)
        }

        // 若已唱完本行：焦點平滑移向行尾外側
        if currentPlayMs >= last.endMs {
            let diff = Double(currentPlayMs - last.endMs) / 600.0
            return min(Double(last.id) + 3.0, Double(last.id) + 1.0 + diff)
        }

        // 處於唱段中：尋找當前所在的精確時空區間，並進行平滑插值
        for i in 0..<lineChars.count {
            let cur = lineChars[i]
            if currentPlayMs >= cur.startMs && currentPlayMs <= cur.endMs {
                let ratio = Double(currentPlayMs - cur.startMs) / Double(max(1, cur.durationMs))
                return Double(cur.id) + min(max(ratio, 0.0), 1.0)
            }

            // 若落在當前字與下一個字之間的停頓空隙，進行線性插值過渡
            if i + 1 < lineChars.count {
                let next = lineChars[i + 1]
                if currentPlayMs > cur.endMs && currentPlayMs < next.startMs {
                    let gapDuration = Double(next.startMs - cur.endMs)
                    let gapProgress = Double(currentPlayMs - cur.endMs) / max(1.0, gapDuration)
                    return Double(cur.id) + 1.0 + gapProgress * (Double(next.id) - Double(cur.id) - 1.0)
                }
            }
        }
        return Double(first.id)
    }
}

// MARK: - 全行字元時空模型
private struct LineCharInfo: Identifiable {
    let id: Int // 全域字元索引 0, 1, 2...
    let text: String
    let syllableId: UUID
    let startMs: Int
    let durationMs: Int
    var endMs: Int { startMs + max(5, durationMs) }
}

// MARK: - 單音節渲染區塊 (鎖定佈局尺寸 + 逐字元掃描動態)
private struct SyllablePieceView: View {
    let syllable: LyricSyllable
    let chars: [LineCharInfo]
    let continuousFocus: Double
    let currentPlayMs: Int

    var body: some View {
        if syllable.text.trimmingCharacters(in: .whitespaces).isEmpty {
            // 純空白保留原生字元寬度間隔
            Text(syllable.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .hidden()
        } else {
            // 關鍵排版鎖定：
            // 底層採用與 InactiveSyllableLyricView 100% 相同的純文字作為 Layout 骨架基準，
            // 傳遞給 SyllableFlowLayout 的 sizeThatFits 尺寸與非當前行精確到 0.000000pt 恆等！
            // 內部逐字元掃描與微物理動態全封裝在 .overlay 內，
            // 既完整保留英文單字內部的逐字母平滑擦亮與立體波浪，又絕對不改變外部行寬判定，永不跳行！
            Text(syllable.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .hidden()
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(chars) { char in
                            CharacterPieceView(
                                char: char,
                                continuousFocus: continuousFocus,
                                currentPlayMs: currentPlayMs
                            )
                        }
                    }
                }
        }
    }
}

// MARK: - 單字母連鎖動態渲染單元 (空間立體浮現 + 多層立體光暈 + 逐字擦亮)
private struct CharacterPieceView: View {
    let char: LineCharInfo
    let continuousFocus: Double
    let currentPlayMs: Int

    /// 單字元擦亮進度 0.0 ~ 1.0
    private var charProgress: Double {
        if currentPlayMs <= char.startMs { return 0.0 }
        if currentPlayMs >= char.endMs { return 1.0 }
        return Double(currentPlayMs - char.startMs) / Double(max(5, char.durationMs))
    }

    /// 高斯連鎖影響力 (0.0 ~ 1.0)
    private var gaussianWeight: Double {
        let dist = abs(Double(char.id) - continuousFocus)
        return exp(-(dist * dist) / (2.0 * 2.0 * 2.0))
    }

    var body: some View {
        let isSpace = char.text.trimmingCharacters(in: .whitespaces).isEmpty

        if isSpace {
            // 空格僅保留寬度，不繪製任何陰影與上浮
            Text(char.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .hidden()
        } else {
            let g = gaussianWeight
            let p = charProgress

            // 極細微 Y 軸微上浮 (Micro-Lift)
            let liftY: CGFloat = {
                if currentPlayMs < char.startMs {
                    // 尚未唱到：隨周圍波及產生極其細微的預熱響應
                    return -1.0 * g
                } else if currentPlayMs >= char.endMs {
                    // 唱完後：平穩維持 -0.8pt 微浮
                    return -0.8
                } else {
                    // 正在發音：柔和微揚 -1.4pt
                    let localWave = sin(p * .pi)
                    return -0.8 - 0.6 * localWave
                }
            }()

            ZStack(alignment: .leading) {
                // 底層：未唱到的暗色底襯（Apple 官方 SF Pro 32pt 大字，35% 次級白）
                // 緊鄰字元泛起被環境散射照亮的柔和微光
                Text(char.text)
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(Color.white.opacity(0.35))
                    .shadow(
                        color: (g > 0.04) ? Color.pink.opacity(0.40 * g) : Color.clear,
                        radius: (g > 0.04) ? 10 * g : 0,
                        x: 0,
                        y: 0
                    )

                // 頂層：唱到的高亮純白發光文字
                // 向螢幕方向浮出的多層空間光暈：白核心 + 明亮立體粉紅光暈 + 外部空氣擴散層
                // 隨字元進度 p (0.0 ~ 1.0) 平滑淡入擦亮，純向量文字渲染，徹底杜絕白色色塊
                Text(char.text)
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
            .offset(y: liftY)
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
