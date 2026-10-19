import SwiftUI

/// Apple Music 逐字卡拉OK流光與連續高斯流體聚焦連鎖組件 (Continuous Gaussian Focus Wave & Lens Ripple)
/// 實作 Apple Music 原生連續動態：下一個字母在播放時從「已被相鄰帶動的大小」平滑無縫繼續放大至波峰，絕不突跳抽搐
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
            // 非當前行：字級與當前行完全一致 (26pt, SF Pro)，切換行時不縮放跳動
            Text(text)
                .font(.system(size: 26, weight: .semibold, design: .default))
                .foregroundColor(Color.white.opacity(0.32))
                .multilineTextAlignment(.leading)
        } else if reduceMotion || syllables == nil || syllables?.isEmpty == true {
            // 當前行但無逐字資料（或開啟減弱動態）：
            // Apple Music 官方 SF Pro 實心純白搭配粉光微暈，全行字體一致
            Text(text)
                .font(.system(size: 26, weight: .bold, design: .default))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.pink.opacity(0.38), radius: 8, x: 0, y: 0)
        } else if let validSyllables = syllables, !validSyllables.isEmpty {
            // 當前行且具備逐字音節時間軸：計算全行連續不斷流的發音焦點 (Continuous Monotonic Focus)
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
    /// 即使在字元交界或字間停頓空隙，焦點依然平滑插值連續滑動，絕不中斷為 nil，保證大小連續無縫
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

// MARK: - 單音節渲染區塊
private struct SyllablePieceView: View {
    let syllable: LyricSyllable
    let chars: [LineCharInfo]
    let continuousFocus: Double
    let currentPlayMs: Int

    var body: some View {
        if syllable.text.trimmingCharacters(in: .whitespaces).isEmpty {
            // 純空白保留原生字元寬度間隔
            Text(syllable.text)
                .font(.system(size: 26, weight: .bold, design: .default))
                .hidden()
        } else {
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

// MARK: - 單字母連鎖動態渲染單元 (無縫連續縮放 + 連鎖光暈)
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
    /// sigma = 2.0 擴大相鄰連鎖波及範圍，大幅放緩放大與縮小的坡度速率，舒展優雅
    private var gaussianWeight: Double {
        let dist = abs(Double(char.id) - continuousFocus)
        return exp(-(dist * dist) / (2.0 * 2.0 * 2.0))
    }

    var body: some View {
        let g = gaussianWeight

        // 1. 連鎖縮放：錨定在底部基線，放大縮小節奏放緩至悠揚呼吸
        let scale = 1.0 + 0.09 * g

        // 2. 連鎖波浪上浮：從預熱微揚平滑銜接至發音波峰
        let liftY: CGFloat = {
            if currentPlayMs < char.startMs {
                // 尚未唱到：受前字連鎖波及柔和預熱微揚
                return -1.6 * g
            } else if currentPlayMs >= char.endMs {
                // 唱完後：平穩維持 -1.0pt，疊加微弱連鎖波動
                return -1.0 - 1.0 * g
            } else {
                // 正在發音：依字元內部進度順滑躍至波峰
                let localWave = sin(charProgress * .pi)
                return -1.0 - (1.2 + 1.0 * g) * localWave
            }
        }()

        ZStack(alignment: .leading) {
            // 底層：未唱到的暗色底襯（Apple 官方 SF Pro 26pt，32% 次級白）
            // 緊鄰被帶動的字元泛起柔和環境微光 (Bloom Aura)
            Text(char.text)
                .font(.system(size: 26, weight: .bold, design: .default))
                .foregroundColor(Color.white.opacity(0.32))
                .shadow(
                    color: (g > 0.04) ? Color.pink.opacity(0.40 * g) : Color.clear,
                    radius: (g > 0.04) ? 8 * g : 0,
                    x: 0,
                    y: 0
                )

            // 頂層：唱到的高亮純白發光文字（始終保持在視圖中以遮罩推進，避免 if 條件硬切閃爍）
            Text(char.text)
                .font(.system(size: 26, weight: .bold, design: .default))
                .foregroundColor(.white)
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
                .opacity(charProgress > 0 ? 1.0 : 0.0)
                .mask {
                    if charProgress >= 1.0 {
                        Color.white
                    } else if charProgress <= 0.0 {
                        Color.clear
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
        .offset(y: liftY)
        .scaleEffect(scale, anchor: .bottom)
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
