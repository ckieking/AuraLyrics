import SwiftUI

/// Syllable-level synchronized karaoke text component with multi-layered glow and vertical micro-lift.
public struct AppleMusicKaraokeText: View {
    let text: String
    let syllables: [LyricSyllable]?
    let isCurrent: Bool
    let currentPlaybackTimeMs: Int
    let blurRadius: CGFloat
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        text: String,
        syllables: [LyricSyllable]? = nil,
        isCurrent: Bool,
        currentPlaybackTimeMs: Int = 0,
        blurRadius: CGFloat = 0,
        opacity: Double = 0.35
    ) {
        self.text = text
        self.syllables = syllables
        self.isCurrent = isCurrent
        self.currentPlaybackTimeMs = currentPlaybackTimeMs
        self.blurRadius = blurRadius
        self.opacity = opacity
    }

    public var body: some View {
        Group {
            if syllables == nil || syllables?.isEmpty == true || reduceMotion {
                // Line-level synchronized lyrics fallback (or when reduce motion is enabled).
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
                        opacity: opacity
                    )
                    .equatable()
                }
            } else if let validSyllables = syllables, !validSyllables.isEmpty {
                // Syllable-level synchronized lyrics rendering.
                if !isCurrent {
                    InactiveSyllableLyricView(
                        text: text,
                        syllables: validSyllables,
                        opacity: opacity
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

    // MARK: - Character Timeline and Syllable Grouping Mapping
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

    // MARK: - Continuous Playback Focus Calculation
    private func calculateContinuousFocus(currentPlayMs: Int, lineChars: [LineCharInfo]) -> Double {
        guard let first = lineChars.first else { return 0.0 }
        guard let last = lineChars.last else { return 0.0 }

        // Playback before line start: hold focus before first character.
        if currentPlayMs <= first.startMs {
            let diff = Double(first.startMs - currentPlayMs) / 600.0
            return max(-3.0, Double(first.id) - diff)
        }

        // Playback after line end: hold focus past last character.
        if currentPlayMs >= last.endMs {
            let diff = Double(currentPlayMs - last.endMs) / 600.0
            return min(Double(last.id) + 3.0, Double(last.id) + 1.0 + diff)
        }

        // Active playback: interpolate focus between character bounds.
        for i in 0..<lineChars.count {
            let cur = lineChars[i]
            if currentPlayMs >= cur.startMs && currentPlayMs <= cur.endMs {
                let ratio = Double(currentPlayMs - cur.startMs) / Double(max(1, cur.durationMs))
                return Double(cur.id) + min(max(ratio, 0.0), 1.0)
            }

            // Linearly interpolate across inter-character pause gap.
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

// MARK: - Character and Syllable Group Models
private struct LineCharInfo: Identifiable {
    let id: Int // Global character index.
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

// MARK: - Syllable Piece View
private struct SyllablePieceView: View {
    let syllable: LyricSyllable
    let chars: [LineCharInfo]
    let continuousFocus: Double
    let currentPlayMs: Int

    var body: some View {
        if syllable.text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Whitespace preserved for native layout spacing.
            Text(syllable.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .hidden()
        } else {
            // Base hidden text establishes matching sizeThatFits dimensions with syllable layout.
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

// MARK: - Character Piece Dynamic Rendering View
private struct CharacterPieceView: View {
    let char: LineCharInfo
    let continuousFocus: Double
    let currentPlayMs: Int

    /// Character reveal progress (0.0 to 1.0).
    private var charProgress: Double {
        if currentPlayMs <= char.startMs { return 0.0 }
        if currentPlayMs >= char.endMs { return 1.0 }
        return Double(currentPlayMs - char.startMs) / Double(max(5, char.durationMs))
    }

    /// Gaussian proximity influence factor (0.0 to 1.0).
    private var gaussianWeight: Double {
        let dist = abs(Double(char.id) - continuousFocus)
        return exp(-(dist * dist) / (2.0 * 2.0 * 2.0))
    }

    var body: some View {
        let isSpace = char.text.trimmingCharacters(in: .whitespaces).isEmpty

        if isSpace {
            // Whitespace preserved without drawing shadows or vertical offset.
            Text(char.text)
                .font(.system(size: 32, weight: .bold, design: .default))
                .hidden()
        } else {
            let g = gaussianWeight
            let p = charProgress

            // Micro vertical lift calculation.
            let liftY: CGFloat = {
                if currentPlayMs < char.startMs {
                    // Pre-singing state: subtle lift responsive to proximity.
                    return -1.0 * g
                } else if currentPlayMs >= char.endMs {
                    // Post-singing state: resting lift (-0.8pt).
                    return -0.8
                } else {
                    // Active voicing: dynamic peak lift (-1.4pt).
                    let localWave = sin(p * .pi)
                    return -0.8 - 0.6 * localWave
                }
            }()

            ZStack(alignment: .leading) {
                // Base layer: inactive lyric text with ambient shadow.
                Text(char.text)
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(Color.white.opacity(0.35))
                    .shadow(
                        color: (g > 0.04) ? Color.pink.opacity(0.40 * g) : Color.clear,
                        radius: (g > 0.04) ? 10 * g : 0,
                        x: 0,
                        y: 0
                    )

                // Highlight layer: illuminated lyric text with multi-layered glow.
                Text(char.text)
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(.white)
                    // Core text highlight.
                    .shadow(
                        color: (g > 0.04) ? Color.white.opacity(0.65 * g) : .clear,
                        radius: (g > 0.04) ? 5 * g : 0,
                        x: 0,
                        y: 0
                    )
                    // Foreground pop glow.
                    .shadow(
                        color: (g > 0.04) ? Color.pink.opacity(0.60 + 0.35 * g) : .clear,
                        radius: (g > 0.04) ? 14 + 8 * g : 0,
                        x: 0,
                        y: 0
                    )
                    // Ambient bloom spread.
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

// MARK: - Syllable Flow Layout
/// Flow layout with balanced two-line partition logic.
public struct SyllableFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 0
    public var verticalSpacing: CGFloat = 10

    public init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 10) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    /// Computes line breaks balancing syllable widths across rows.
    private func computeLineBreaks(sizes: [CGSize], maxWidth: CGFloat) -> [[Int]] {
        let count = sizes.count
        guard count > 0 else { return [] }

        // 1. Single-line check.
        var line1Width: CGFloat = 0
        for i in 0..<count {
            line1Width += sizes[i].width + (i > 0 ? horizontalSpacing : 0)
        }
        if line1Width <= maxWidth {
            return [Array(0..<count)]
        }

        // 2. Balanced two-line partition calculation.
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

            // Evaluate balanced partition within safety tolerance.
            if w1 <= maxWidth + 8.0 && w2 <= maxWidth + 8.0 {
                let diff = abs(w1 - w2)
                if diff < minDiff {
                    minDiff = diff
                    bestSplit = split
                }
            }
        }

        if let split = bestSplit {
            // Balanced two-line split found.
            return [Array(0..<split), Array(split..<count)]
        }

        // 3. Fallback greedy line breaking for long text.
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

// MARK: - Inactive Syllable Lyrics Cached View
private struct InactiveSyllableLyricView: View, Equatable {
    let text: String
    let syllables: [LyricSyllable]
    let opacity: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text &&
        lhs.syllables == rhs.syllables &&
        lhs.opacity == rhs.opacity
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
                        .foregroundColor(Color.white.opacity(opacity))
                }
            }
        }
    }
}

// MARK: - Inactive Plain Lyrics Cached View
private struct InactivePlainLyricView: View, Equatable {
    let text: String
    let opacity: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text &&
        lhs.opacity == rhs.opacity
    }

    var body: some View {
        Text(text)
            .font(.system(size: 32, weight: .bold, design: .default))
            .foregroundColor(Color.white.opacity(opacity))
            .multilineTextAlignment(.leading)
    }
}

