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
                if isCurrent {
                    Text(text)
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .shadow(color: Color.white.opacity(0.45), radius: 5, x: 0, y: 0)
                        .shadow(color: Color.pink.opacity(0.55), radius: 14, x: 0, y: 0)
                } else {
                    InactivePlainLyricView(
                        text: text,
                        blurRadius: blurRadius
                    )
                    .equatable()
                }
            } else if let validSyllables = syllables, !validSyllables.isEmpty {
                // 逐字音節時間軸：
                // 當前行與非當前行全面採用完全相同的 32pt SyllableFlowLayout！
                // 若長歌詞需要折行，在尚未唱到時就已經預先折好，唱到時文字幾何位置 0 偏移，原地發光
                if !isCurrent {
                    // 非當前行：採用 Equatable 隔離視圖，避免 body 重複評估與重繪
                    // 當模糊半徑未改變時，SwiftUI 複用既有圖層渲染節點，穩跑 120fps！
                    InactiveSyllableLyricView(
                        text: text,
                        syllables: validSyllables,
                        blurRadius: blurRadius
                    )
                    .equatable()
                } else {
                    let grouped = buildSyllableCharGroups(from: validSyllables)
                    let continuousFocus = calculateContinuousFocus(currentPlayMs: currentPlaybackTimeMs, lineChars: grouped.allChars)

                    SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 10) {
                        ForEach(grouped.syllableGroups) { group in
                            SyllablePieceView(
                                syllable: group.syllable,
                                chars: group.chars,
                                continuousFocus: continuousFocus,
                                currentPlayMs: currentPlaybackTimeMs
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 單次走訪構建整行字元時間軸與音節分組映射 (O(N) 取代 O(S*C) 重複 filter)
    private func buildSyllableCharGroups(from syllables: [LyricSyllable]) -> (allChars: [LineCharInfo], syllableGroups: [SyllableCharGroup]) {
        var allChars: [LineCharInfo] = []
        var groups: [SyllableCharGroup] = []
        groups.reserveCapacity(syllables.count)
        var globalIdx = 0

        for syl in syllables {
            let rawChars = Array(syl.text)
            guard !rawChars.isEmpty else {
                groups.append(SyllableCharGroup(syllable: syl, chars: []))
                continue
            }
            let count = rawChars.count
            let duration = max(10, syl.durationMs)
            let step = max(5, duration / count)
            var sylChars: [LineCharInfo] = []
            sylChars.reserveCapacity(count)

            for (i, char) in rawChars.enumerated() {
                let charStart = syl.timeMs + i * step
                let info = LineCharInfo(
                    id: globalIdx,
                    text: String(char),
                    syllableId: syl.id,
                    startMs: charStart,
                    durationMs: step
                )
                sylChars.append(info)
                allChars.append(info)
                globalIdx += 1
            }
            groups.append(SyllableCharGroup(syllable: syl, chars: sylChars))
        }
        return (allChars, groups)
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

// MARK: - 全行字元時空模型與音節預分組
private struct LineCharInfo: Identifiable {
    let id: Int // 全域字元索引 0, 1, 2...
    let text: String
    let syllableId: UUID
    let startMs: Int
    let durationMs: Int
    var endMs: Int { startMs + max(5, durationMs) }
}

private struct SyllableCharGroup: Identifiable {
    let syllable: LyricSyllable
    let chars: [LineCharInfo]
    var id: UUID { syllable.id }
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
                        color: (g > 0.04) ? Color.white.opacity(0.65 * g) : .clear,
                        radius: (g > 0.04) ? 5 * g : 0,
                        x: 0,
                        y: 0
                    )
                    // 第二層：向螢幕前方浮現的立體粉紅光暈（Depth Pop Glow，僅在唱到焦點時綻放，唱完後乾淨歸零避免光斑疊加）
                    .shadow(
                        color: (g > 0.04) ? Color.pink.opacity(0.60 + 0.35 * g) : .clear,
                        radius: (g > 0.04) ? 14 + 8 * g : 0,
                        x: 0,
                        y: 0
                    )
                    // 第三層：空氣感大範圍環境散射暈光（Ambient Bloom）
                    .shadow(
                        color: (g > 0.04) ? Color.pink.opacity(0.35 * g) : .clear,
                        radius: (g > 0.04) ? 26 * g : 0,
                        x: 0,
                        y: 0
                    )
                    .opacity(min(1.0, max(0.0, p)))
            }
            .offset(y: liftY)
            .transaction { $0.animation = nil }
        }
    }
}

// MARK: - 音節流式自動換行排版 (Apple Music 智慧兩行平衡折行演算法)
/// 解決多行歌詞換行與不同字寬對齊問題；
/// 採用兩行平衡拆分演算法（Balanced 2-Line Partitioning），整句歌詞優先在兩行內最優均勻分折，
/// 徹底杜絕因行尾貪婪溢出而產生孤零零單字的第 3 行，
/// 同時強制鎖死每行所屬音節，杜絕播放亮起時的任何跳行現象！
public struct SyllableFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 0
    public var verticalSpacing: CGFloat = 10

    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 10) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    /// 根據已量測的子視圖尺寸與可用寬度，計算最優的行劃分（避免重複呼叫 sizeThatFits）
    private func computeLineBreaks(sizes: [CGSize], maxWidth: CGFloat) -> [[Int]] {
        let count = sizes.count
        guard count > 0 else { return [] }

        // 1. 檢查整句是否能在 1 行內完全放下
        var line1Width: CGFloat = 0
        for i in 0..<count {
            line1Width += sizes[i].width + (i > 0 ? horizontalSpacing : 0)
        }
        if line1Width <= maxWidth {
            return [Array(0..<count)]
        }

        // 2. 智慧兩行平衡劃分（Balanced 2-Line Split）：
        // 在所有可能的分割點中，尋找讓兩行都能放下且長度最平衡的最佳分割點
        var bestSplit: Int? = nil
        var minDiff: CGFloat = .infinity

        var prefixWidths = [CGFloat](repeating: 0, count: count + 1)
        for i in 0..<count {
            prefixWidths[i + 1] = prefixWidths[i] + sizes[i].width + (i > 0 ? horizontalSpacing : 0)
        }

        let totalW = prefixWidths[count]

        for split in 1..<count {
            let w1 = prefixWidths[split]
            let w2 = totalW - prefixWidths[split]

            // 給予 8pt 的安全容差（允許極輕微自然延伸至 20pt 的左右 padding 內，優先維持兩行）
            if w1 <= maxWidth + 8.0 && w2 <= maxWidth + 8.0 {
                let diff = abs(w1 - w2)
                if diff < minDiff {
                    minDiff = diff
                    bestSplit = split
                }
            }
        }

        if let split = bestSplit {
            // 成功在兩行內均衡收斂，徹底杜絕第三行！
            return [Array(0..<split), Array(split..<count)]
        }

        // 3. 安全回退：若極長句子兩行確實無法容納，進行貪婪折行
        var lines: [[Int]] = []
        var currentLine: [Int] = []
        var currentW: CGFloat = 0

        for i in 0..<count {
            let w = sizes[i].width
            if currentW + w > maxWidth + 4.0 && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = [i]
                currentW = w
            } else {
                currentLine.append(i)
                currentW += w + horizontalSpacing
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lineIndices = computeLineBreaks(sizes: sizes, maxWidth: maxWidth)
        guard !lineIndices.isEmpty else { return .zero }

        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for (lineIdx, indices) in lineIndices.enumerated() {
            var lineWidth: CGFloat = 0
            var lineHeight: CGFloat = 0
            for (idxInLine, i) in indices.enumerated() {
                lineWidth += sizes[i].width + (idxInLine > 0 ? horizontalSpacing : 0)
                lineHeight = max(lineHeight, sizes[i].height)
            }
            maxLineWidth = max(maxLineWidth, lineWidth)
            totalHeight += lineHeight + (lineIdx > 0 ? verticalSpacing : 0)
        }

        return CGSize(width: min(maxLineWidth, maxWidth), height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let maxWidth = bounds.width
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lineIndices = computeLineBreaks(sizes: sizes, maxWidth: maxWidth)
        guard !lineIndices.isEmpty else { return }

        var currentY = bounds.minY

        for (_, indices) in lineIndices.enumerated() {
            var currentX = bounds.minX
            var lineHeight: CGFloat = 0

            for (_, i) in indices.enumerated() {
                let size = sizes[i]
                subviews[i].place(
                    at: CGPoint(x: currentX, y: currentY),
                    proposal: ProposedViewSize(size)
                )
                currentX += size.width + horizontalSpacing
                lineHeight = max(lineHeight, size.height)
            }

            currentY += lineHeight + verticalSpacing
        }
    }
}

// MARK: - 非當前播放行 Equatable 快取視圖 (避免重複重繪並維持文字向量邊緣與無障礙文字清晰度)
private struct InactiveSyllableLyricView: View, Equatable {
    let text: String
    let syllables: [LyricSyllable]
    let blurRadius: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text &&
        lhs.syllables == rhs.syllables &&
        lhs.blurRadius == rhs.blurRadius
    }

    var body: some View {
        let content = SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 10) {
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

        if blurRadius > 0 {
            content
                .blur(radius: blurRadius)
        } else {
            content
        }
    }
}

// MARK: - 非當前播放行普通歌詞 Equatable 快取視圖
private struct InactivePlainLyricView: View, Equatable {
    let text: String
    let blurRadius: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text &&
        lhs.blurRadius == rhs.blurRadius
    }

    var body: some View {
        let content = Text(text)
            .font(.system(size: 32, weight: .bold, design: .default))
            .foregroundColor(Color.white.opacity(0.35))
            .multilineTextAlignment(.leading)

        if blurRadius > 0 {
            content
                .blur(radius: blurRadius)
        } else {
            content
        }
    }
}

