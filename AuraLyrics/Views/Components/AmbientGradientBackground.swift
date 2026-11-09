import SwiftUI

/// Dynamic mesh gradient background rendered using palette colors extracted from album artwork.
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
                // MARK: - Base Layer: Dark background tone
                palette.backgroundDark
                    .frame(width: size.width, height: size.height)

                if !reduceTransparency {
                    // MARK: - Second Layer: Blurred artwork diffuse texture
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .blur(radius: 64)
                            .opacity(0.32)
                    }

                    // MARK: - Third Layer: 3x3 MeshGradient
                    meshGradientView
                        .frame(width: size.width, height: size.height)
                        .clipped()

                    // MARK: - Fourth Layer: Top and bottom vignette mask
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
                    // Accessibility reduce transparency mode: fallback linear gradient.
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

    // MARK: - 3x3 MeshGradient
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
        .blur(radius: 20) // Soften mesh transitions.
        .opacity(0.92)
    }
}
