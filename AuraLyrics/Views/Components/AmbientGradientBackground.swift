import SwiftUI

/// Apple Music 經典沉浸式動態多重徑向流光背景 (Ambient Radial Orbs Background)
/// 依據歌曲/專輯封面即時提取之主色與多個輔色，建構不受深淺主題干擾的深邃高對比流光舞台
public struct AmbientGradientBackground: View {
    let palette: ArtworkPalette
    let artworkImage: UIImage?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var animateOrbs: Bool = false

    public init(palette: ArtworkPalette, artworkImage: UIImage?) {
        self.palette = palette
        self.artworkImage = artworkImage
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                // MARK: - 最底層：極深色基底，保證任何時候絕對不透白
                palette.backgroundDark
                    .frame(width: size.width, height: size.height)

                if !reduceTransparency {
                    // MARK: - 第二層：微弱封面漫射紋理（增加原創封面的視覺關聯度，嚴格約束在容器尺寸內避免撐大外層佈局）
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .blur(radius: 64)
                            .opacity(0.32)
                    }

                    // MARK: - 第三層：Apple Music 經典多重動態徑向極光光球 (零離屏模糊、天然衰減零接縫)
                    radialOrbsView(size: size)
                        .frame(width: size.width, height: size.height)
                        .clipped()

                    // MARK: - 第四層：頂底暗角與微噪遮罩（確保狀態列與底部完全符合 WCAG AAA 白字對比度）
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.45), location: 0.0),
                            .init(color: Color.black.opacity(0.08), location: 0.28),
                            .init(color: Color.black.opacity(0.12), location: 0.72),
                            .init(color: Color.black.opacity(0.55), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: size.width, height: size.height)
                } else {
                    // 減少透明度無障礙模式：使用高對比度雙色線性漸層
                    LinearGradient(
                        colors: [palette.primary, palette.backgroundDark],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: palette)
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 8.0).repeatForever(autoreverses: true)) {
                    animateOrbs = true
                }
            }
        }
    }

    // MARK: - 多重動態徑向極光光斑（數學平滑衰減，0 離屏模糊，0 幾何摺痕）
    @ViewBuilder
    private func radialOrbsView(size: CGSize) -> some View {
        let maxDim = max(max(size.width, size.height), 100)

        ZStack {
            // 光球 1：左上主色光斑（以 offset / scale 平滑物理呼吸）
            RadialGradient(
                colors: [palette.primary.opacity(0.85), palette.primary.opacity(0.0)],
                center: .topLeading,
                startRadius: 20,
                endRadius: max(20, maxDim * 0.75)
            )
            .offset(x: animateOrbs ? maxDim * 0.12 : -maxDim * 0.05, y: animateOrbs ? maxDim * 0.08 : -maxDim * 0.04)
            .scaleEffect(animateOrbs ? 1.08 : 0.95)

            // 光球 2：右上/右側輔色光斑（橫向飄移呼吸）
            RadialGradient(
                colors: [palette.secondary.opacity(0.75), palette.secondary.opacity(0.0)],
                center: .topTrailing,
                startRadius: 30,
                endRadius: max(30, maxDim * 0.70)
            )
            .offset(x: animateOrbs ? -maxDim * 0.08 : maxDim * 0.06, y: animateOrbs ? maxDim * 0.10 : 0)
            .scaleEffect(animateOrbs ? 0.96 : 1.06)

            // 光球 3：左下第三色（縱向對角擺動）
            RadialGradient(
                colors: [palette.tertiary.opacity(0.65), palette.tertiary.opacity(0.0)],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: max(20, maxDim * 0.65)
            )
            .offset(x: animateOrbs ? maxDim * 0.06 : 0, y: animateOrbs ? -maxDim * 0.10 : maxDim * 0.05)
            .scaleEffect(animateOrbs ? 1.05 : 0.94)

            // 光球 4：右下強調亮點（增添舞台深度）
            RadialGradient(
                colors: [palette.accent.opacity(0.55), palette.accent.opacity(0.0)],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: max(10, maxDim * 0.60)
            )
            .offset(x: animateOrbs ? -maxDim * 0.05 : maxDim * 0.04, y: animateOrbs ? -maxDim * 0.06 : 0)
            .scaleEffect(animateOrbs ? 0.92 : 1.08)
        }
    }
}
