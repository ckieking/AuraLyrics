import SwiftUI

/// Apple Music 逐字卡拉OK流光與高斯流體聚焦連鎖光暈組件 (Gaussian Fluid Focus Wave & Lens Ripple)
/// 實作 Apple Music 標誌性物理動效：發音字連鎖帶動周圍相鄰字一起平滑放大，並伴隨粉白呼吸光暈擴散
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
            // 非當前行：字級與當前行完全一致 (.title2, SF Pro)，切換時不縮放跳動
            Text(text)
                .font(.system(.title2, design: .default).weight(.semibold))
                .foregroundColor(Color.white.opacity(0.32))
                .multilineTextAlignment(.leading)
        } else if reduceMotion || syllables == nil || syllables?.isEmpty == true {
            // 當前行但無逐字資料（或開啟減弱動態）：
            // Apple Music 官方 SF Pro 實心純白搭配粉光微暈，全行字體一致
            Text(text)
                .font(.system(.title2, design: .default).weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.pink.opacity(0.38), radius: 8, x: 0, y: 0)
        } else if let validSyllables = syllables, !validSyllables.isEmpty {
            // 當前行且具備逐字音節時間軸：計算全行字元時間軸與高斯流體發音焦點
            let lineChars = buildLineChars(from: validSyllables)
            let focusIndex = calculateFocusIndex(currentPlayMs: currentPlaybackTimeMs, lineChars: lineChars)

            SyllableFlowLayout(horizontalSpacing: 0, verticalSpacing: 8) {
                ForEach(validSyllables) { syl in
                    let charsInSyllable = lineChars.filter { $0.syllableId == syl.id }
                    SyllablePieceView(
                        syllable: syl,
                        chars: charsInSyllable,
                        focusIndex: focusIndex,
                        currentPlayMs: currentPlaybackTimeMs
                    )
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

    // MARK: - 計算全行當前發音能量焦點位置 (Focus Index)
    private func calculateFocusIndex(currentPlayMs: Int, lineChars: [LineCharInfo]) -> Double? {
        guard let first = lineChars.first, let last = lineChars.last else { return nil }
        if currentPlayMs < first.startMs || currentPlayMs > last.endMs {
            return nil
        }

        for char in lineChars {
            if currentPlayMs >= char.startMs && currentPlayMs <= char.endMs {
                let ratio = Double(currentPlayMs - char.startMs) / Double(max(1, char.durationMs))
                return Double(char.id) + min(max(ratio, 0.0), 1.0)
            }
        }
        return nil
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

// MARK: - 單音節渲染區塊（支援高斯連鎖放大與光暈漣漪）
private struct SyllablePieceView: View {
    let syllable: LyricSyllable
    let chars: [LineCharInfo]
    let focusIndex: Double?
    let currentPlayMs: Int

    var body: some View {
        if syllable.text.trimmingCharacters(in: .whitespaces).isEmpty {
            // 純空白保留原生字元寬度間隔
            Text(syllable.text)
                .font(.system(.title2, design: .default).weight(.bold))
                .hidden()
        } else {
            HStack(spacing: 0) {
                ForEach(chars) { char in
                    CharacterPieceView(
                        char: char,
                        focusIndex: focusIndex,
                        currentPlayMs: currentPlayMs
                    )
                }
            }
        }
    }
}

// MARK: - 單字母連鎖動態渲染單元 (Per-Character Ripple & Gaussian Bloom)
private struct CharacterPieceView: View {
    let char: LineCharInfo
    let focusIndex: Double?
    let currentPlayMs: Int

    /// 單字元進度 0.0 ~ 1.0
    private var charProgress: Double {
        if currentPlayMs <= char.startMs { return 0.0 }
        if currentPlayMs >= char.endMs { return 1.0 }
        return Double(currentPlayMs - char.startMs) / Double(max(5, char.durationMs))
    }

    /// 高斯連鎖影響力 (0.0 ~ 1.0，核心字元 = 1.0，相鄰 1~2 字元柔和衰減)
    private var gaussianWeight: Double {
        guard let focus = focusIndex else { return 0.0 }
        let dist = abs(Double(char.id) - focus)
        // sigma = 1.35 確保緊鄰 1 個字母被帶動放大約 6.7%，相鄰 2 個字母放大約 2.8%
        return exp(- (dist * dist) / (2.0 * 1.35 * 1.35))
    }

    var body: some View {
        let g = gaussianWeight
        // 1. 連鎖放大：核心發音字元放大 9%，相鄰字母被柔和連鎖帶動放大
        let scale = 1.0 + 0.09 * g

        // 2. 連鎖波浪上浮：核心躍起 -2.2pt，相鄰字元受波及微揚
        let liftY: CGFloat = {
            if currentPlayMs < char.startMs {
                return -1.6 * g
            } else if currentPlayMs >= char.endMs {
                return -1.0 - 1.2 * g
            } else {
                return -1.0 - 2.2 * sin(charProgress * .pi)
            }
        }()

        ZStack(alignment: .leading) {
            // 底層：未唱到的暗色底襯（Apple 官方字體 SF Pro，32% 次級白）
            // 緊鄰被帶動的字元會泛起被波及的粉色微光 (Bloom Aura)
            Text(char.text)
                .font(.system(.title2, design: .default).weight(.bold))
                .foregroundColor(Color.white.opacity(0.32))
                .shadow(
                    color: (g > 0.05) ? Color.pink.opacity(0.42 * g) : Color.clear,
                    radius: (g > 0.05) ? 8 * g : 0,
                    x: 0,
                    y: 0
                )

            // 頂層：唱到的高亮純白發光字母（僅在當前字母開始發音後才渲染）
            if charProgress > 0 {
                Text(char.text)
                    .font(.system(.title2, design: .default).weight(.bold))
                    .foregroundColor(.white)
                    // 雙重粉白動態光暈：焦點核心字元綻放明亮高光
                    .shadow(
                        color: Color.white.opacity(0.40 * g),
                        radius: 4 * g,
                        x: 0,
                        y: 0
                    )
                    .shadow(
                        color: Color.pink.opacity(0.35 + 0.45 * g),
                        radius: 6 + 10 * g,
                        x: 0,
                        y: 0
                    )
                    .mask {
                        if charProgress >= 1.0 {
                            Color.white
                        } else {
                            GeometryReader { geo in
                                let width = geo.size.width
                                let currentX = width * charProgress
                                let feather: CGFloat = 3

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

// MARK: - 音節流式自動換行排版 (SwiftUI Layout Protocol)
/// 解決多行歌詞換行與不同字寬對齊問題，確保唱完第一行才依序點亮第二行
public struct SyllableFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 0
    public var verticalSpacing: CGFloat = 8

    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 8) {
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
