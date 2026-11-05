import SwiftUI

/// Apple Music 經典沉浸式動態多色網格漸層背景 (Ambient Mesh Gradient)
/// 依據歌曲/專輯封面即時提取之主色與多個輔色，建構不受深淺主題干擾的深邃高對比流光舞台
public struct AmbientGradientBackground: View {
    let palette: ArtworkPalette
    let artworkImage: UIImage?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var animateMesh: Bool = false

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

                    // MARK: - 第三層：Apple Music 原生 3x3 MeshGradient 多焦點流光網格
                    meshGradientView
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
                withAnimation(.easeInOut(duration: 7.0).repeatForever(autoreverses: true)) {
                    animateMesh = true
                }
            }
        }
    }

    // MARK: - iOS 18+ 原生 MeshGradient 3x3 網格
    private var meshGradientView: some View {
        let p1X: Float = animateMesh ? 0.42 : 0.58
        let p1Y: Float = animateMesh ? 0.45 : 0.55
        let p2X: Float = animateMesh ? 0.85 : 0.78
        let p2Y: Float = animateMesh ? 0.20 : 0.28

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
                SIMD2<Float>(0.0, 0.5), SIMD2<Float>(p1X, p1Y), SIMD2<Float>(p2X, p2Y),
                SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0)
            ],
            colors: [
                palette.backgroundDark, palette.secondary, palette.primary,
                palette.tertiary, palette.primary, palette.accent,
                palette.backgroundDark, palette.primary, palette.backgroundDark
            ]
        )
        .blur(radius: 20) // 輕微柔化網格交界處，創造如絲綢般平滑流光的奢華質感
        .opacity(0.92)
    }
}
