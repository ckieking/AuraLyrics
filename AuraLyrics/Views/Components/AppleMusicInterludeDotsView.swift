import SwiftUI

/// Three-dot Apple Music style rhythm indicator displayed during long intros and interludes.
public struct AppleMusicInterludeDotsView: View {
    let startMs: Int
    let endMs: Int
    let currentPlaybackTimeMs: Int
    let isIntro: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(startMs: Int, endMs: Int, currentPlaybackTimeMs: Int, isIntro: Bool = false) {
        self.startMs = startMs
        self.endMs = endMs
        self.currentPlaybackTimeMs = currentPlaybackTimeMs
        self.isIntro = isIntro
    }

    private var overallProgress: Double {
        let span = max(1, endMs - startMs)
        let elapsed = currentPlaybackTimeMs - startMs
        return min(1.0, max(0.0, Double(elapsed) / Double(span)))
    }

    private var preCueFactor: Double {
        let remainingMs = endMs - currentPlaybackTimeMs
        guard remainingMs >= 0 && remainingMs <= 1200 else { return 0.0 }
        let normalized = 1.0 - (Double(remainingMs) / 1200.0)
        return sin(normalized * .pi)
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                dotView(for: index)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isIntro ? String(localized: "前奏拍點指示器") : String(localized: "間奏拍點指示器"))
        .accessibilityHint(isIntro ? String(localized: "點擊跳回前奏起點") : String(localized: "點擊跳回此段間奏起點"))
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func dotView(for index: Int) -> some View {
        let segmentStart = Double(index) / 3.0
        let dotFill = min(1.0, max(0.0, (overallProgress - segmentStart) * 3.0))
        let dotOpacity = 0.26 + 0.74 * dotFill

        if reduceMotion {
            Circle()
                .fill(Color.white.opacity(dotOpacity))
                .frame(width: 12, height: 12)
        } else {
            let phase = (Double(currentPlaybackTimeMs) / 450.0) - (Double(index) * 0.65)
            let wave = sin(phase)
            let cue = preCueFactor
            let scale = (0.94 + 0.12 * dotFill + 0.04 * wave) * (1.0 + 0.14 * cue)
            let offsetY = CGFloat(-1.8 * wave)
            let glowWeight = min(1.0, max(0.0, dotFill * 0.75 + cue * 0.65))

            Circle()
                .fill(Color.white.opacity(dotOpacity))
                .frame(width: 12, height: 12)
                .scaleEffect(scale)
                .offset(y: offsetY)
                .shadow(
                    color: glowWeight > 0.05 ? Color.white.opacity(0.60 * glowWeight) : .clear,
                    radius: glowWeight > 0.05 ? 4 * glowWeight : 0,
                    x: 0,
                    y: 0
                )
                .shadow(
                    color: glowWeight > 0.05 ? Color.pink.opacity(0.65 * glowWeight) : .clear,
                    radius: glowWeight > 0.05 ? 10 + 6 * glowWeight : 0,
                    x: 0,
                    y: 0
                )
        }
    }
}
