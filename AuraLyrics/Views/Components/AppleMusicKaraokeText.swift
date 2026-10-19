import SwiftUI

/// Apple Music 逐字卡拉OK流光與節奏律動歌詞組件
/// 支援音節流式自動換行 (SyllableFlowLayout)、全行統一字級（不縮放）、
/// 蘋果官方字體 (SF Pro, design: .default) 以及精細到每個字母的獨立波浪上浮律動 (Per-Character Wave Lift)
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
            // 非當前行：字體大小與當前行完全一致 (.title2, design: .default)，切換時不縮放跳動
            Text(text)
                .font(.system(.title2, design: .default).weight(.semibold))
                .foregroundColor(Color.white.opacity(0.32))
                .multilineTextAlignment(.leading)
        } else if reduceMotion || syllables == nil || syllables?.isEmpty == true {
            // 當前行但無逐字資料（或開啟減弱動態）：
            // Apple Music 官方 SF Pro 實心純白搭配粉光微暈，字體大小一致不縮放
            Text(text)
                .font(.system(.title2, design: .default).weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.pink.opacity(0.38), radius: 8, x: 0, y: 0)
        } else if let validSyllables = syllables, !validSyllables.isEmpty {
            // 當前行且具備逐字音節時間軸：以 SyllableFlowLayout 進行逐音節、逐字母獨立波浪渲染
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

// MARK: - 單音節獨立單元（內部支援精細到每個字母的波浪律動）
private struct SyllablePieceView: View {
    let syllable: LyricSyllable
    let currentPlayMs: Int

    private var startMs: Int { syllable.timeMs }
    private var durationMs: Int { max(10, syllable.durationMs) }
    private var endMs: Int { startMs + durationMs }

    /// 音節整體播放進度 0.0 ~ 1.0
    private var progress: Double {
        if currentPlayMs <= startMs { return 0.0 }
        if currentPlayMs >= endMs { return 1.0 }
        return Double(currentPlayMs - startMs) / Double(durationMs)
    }

    /// 是否正在發音
    private var isSinging: Bool {
        currentPlayMs >= startMs && currentPlayMs < endMs
    }

    private var characters: [Character] {
        Array(syllable.text)
    }

    var body: some View {
        // 純空白音節直接保留版面間隔
        if syllable.text.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(syllable.text)
                .font(.system(.title2, design: .default).weight(.bold))
                .hidden()
        } else {
            HStack(spacing: 0) {
                ForEach(Array(characters.enumerated()), id: \.offset) { idx, char in
                    let charStr = String(char)
                    let lift = charLiftY(at: idx, total: characters.count, progress: progress)
                    let (charProgress, isCharActive) = charProgressInfo(at: idx, total: characters.count, progress: progress)

                    ZStack(alignment: .leading) {
                        // 底層：未唱到的暗色底襯（Apple 官方字體 SF Pro，32% 次級白）
                        Text(charStr)
                            .font(.system(.title2, design: .default).weight(.bold))
                            .foregroundColor(Color.white.opacity(0.32))

                        // 頂層：唱到的高亮純白發光字母（僅在當前字母開始發音時才渲染）
                        if isCharActive {
                            Text(charStr)
                                .font(.system(.title2, design: .default).weight(.bold))
                                .foregroundColor(.white)
                                .shadow(
                                    color: isSinging ? Color.pink.opacity(0.48) : Color.pink.opacity(0.32),
                                    radius: isSinging ? 8 : 5,
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
                    .offset(y: lift)
                }
            }
        }
    }

    /// 計算單一字母的波浪微上浮高度 (Per-Character Wave Lift)
    private func charLiftY(at index: Int, total: Int, progress: Double) -> CGFloat {
        if progress <= 0 { return 0 }
        guard total > 0 else { return 0 }

        let step = 1.0 / Double(total)
        let charStart = Double(index) * step
        let charEnd = charStart + step

        if progress >= charEnd {
            // 唱過該字母：維持輕微微浮 -1.0pt
            return -1.0
        } else if progress >= charStart {
            // 正在唱該字母：依局部正弦波躍起 -1.8pt，呈現漣漪波浪律動
            let localRatio = (progress - charStart) / step
            return -1.0 - 1.8 * sin(localRatio * .pi)
        } else {
            // 尚未唱到該字母：原位不動
            return 0.0
        }
    }

    /// 計算單一字母內部的擦亮進度 (0.0 ~ 1.0) 與是否已啟動發音
    private func charProgressInfo(at index: Int, total: Int, progress: Double) -> (charProgress: Double, isActive: Bool) {
        guard total > 0 else { return (0.0, false) }
        let step = 1.0 / Double(total)
        let charStart = Double(index) * step
        let charEnd = charStart + step

        if progress <= charStart {
            return (0.0, false)
        } else if progress >= charEnd {
            return (1.0, true)
        } else {
            let localProgress = (progress - charStart) / step
            return (localProgress, true)
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
