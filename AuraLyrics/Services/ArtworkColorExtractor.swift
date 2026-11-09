import SwiftUI
import UIKit
import CoreGraphics

/// Color palette extracted from album artwork for ambient gradient backgrounds.
public struct ArtworkPalette: Equatable, Sendable {
    public let primary: Color
    public let secondary: Color
    public let tertiary: Color
    public let accent: Color
    public let backgroundDark: Color

    /// Default dark color palette.
    public static let fallback = ArtworkPalette(
        primary: Color(red: 0.14, green: 0.10, blue: 0.22),
        secondary: Color(red: 0.22, green: 0.08, blue: 0.18),
        tertiary: Color(red: 0.08, green: 0.15, blue: 0.24),
        accent: Color(red: 0.28, green: 0.12, blue: 0.26),
        backgroundDark: Color(red: 0.05, green: 0.05, blue: 0.08)
    )
}

/// Extracts multi-tiered color palettes from artwork via downsampling and HSB normalization.
public final class ArtworkColorExtractor {
    public static let shared = ArtworkColorExtractor()

    /// In-memory cache for extracted palettes keyed by identifier.
    private let cache = NSCache<NSString, PaletteBox>()

    private init() {
        cache.countLimit = 50
    }

    /// Asynchronously extracts a color palette from the given image.
    public func extractPalette(from image: UIImage?, cacheKey: String? = nil) async -> ArtworkPalette {
        guard let image = image else { return .fallback }

        if let key = cacheKey as NSString?, let cached = cache.object(forKey: key) {
            return cached.palette
        }

        let palette = await Task.detached(priority: .userInitiated) {
            return Self.analyzeImage(image)
        }.value

        if let key = cacheKey as NSString? {
            cache.setObject(PaletteBox(palette: palette), forKey: key)
        }

        return palette
    }

    /// Analyzes image pixels synchronously to extract dominant colors.
    public static func analyzeImage(_ image: UIImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage else { return .fallback }

        // Downsample to 32x32 pixels to reduce computational cost and filter high-frequency noise.
        let targetSize = 32
        let width = targetSize
        let height = targetSize
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var rawData = [UInt8](repeating: 0, count: totalBytes)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .fallback
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample five key coordinates: top-left, top-right, center, bottom-left, bottom-right.
        let points: [(x: Int, y: Int)] = [
            (width / 4, height / 4),         // Top-left
            (width * 3 / 4, height / 4),     // Top-right
            (width / 2, height / 2),         // Center
            (width / 4, height * 3 / 4),     // Bottom-left
            (width * 3 / 4, height * 3 / 4)  // Bottom-right
        ]

        var sampledColors: [UIColor] = []
        for p in points {
            let offset = (p.y * width + p.x) * bytesPerPixel
            if offset + 3 < totalBytes {
                let r = CGFloat(rawData[offset]) / 255.0
                let g = CGFloat(rawData[offset + 1]) / 255.0
                let b = CGFloat(rawData[offset + 2]) / 255.0
                sampledColors.append(UIColor(red: r, green: g, blue: b, alpha: 1.0))
            }
        }

        // Compute global average color as a baseline reference.
        var sumR: CGFloat = 0, sumG: CGFloat = 0, sumB: CGFloat = 0
        let totalPixels = width * height
        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            sumR += CGFloat(rawData[offset])
            sumG += CGFloat(rawData[offset + 1])
            sumB += CGFloat(rawData[offset + 2])
        }
        let avgColor = UIColor(
            red: (sumR / CGFloat(totalPixels)) / 255.0,
            green: (sumG / CGFloat(totalPixels)) / 255.0,
            blue: (sumB / CGFloat(totalPixels)) / 255.0,
            alpha: 1.0
        )

        // Normalize colors to constrain brightness for text legibility.
        let p1 = normalizeForBackground(sampledColors.indices.contains(0) ? sampledColors[0] : avgColor)
        let p2 = normalizeForBackground(sampledColors.indices.contains(1) ? sampledColors[1] : avgColor)
        let p3 = normalizeForBackground(sampledColors.indices.contains(2) ? sampledColors[2] : avgColor)
        let p4 = normalizeForBackground(sampledColors.indices.contains(3) ? sampledColors[3] : avgColor)

        // Derive deep dark background color from average color.
        let bgDark = createDeepBackground(from: avgColor)

        return ArtworkPalette(
            primary: Color(p1),
            secondary: Color(p2),
            tertiary: Color(p3),
            accent: Color(p4),
            backgroundDark: Color(bgDark)
        )
    }

    /// Adjusts sample color saturation and brightness for background contrast.
    private static func normalizeForBackground(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Ensure sufficient saturation.
        let targetSaturation = max(0.45, min(s * 1.25, 0.90))
        // Constrain brightness to a dark range (0.20 - 0.45).
        let targetBrightness = max(0.20, min(b * 0.70, 0.45))

        return UIColor(hue: h, saturation: targetSaturation, brightness: targetBrightness, alpha: 1.0)
    }

    /// Derives a near-black, low-saturation tone from a given color.
    private static func createDeepBackground(from color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let deepSaturation = min(s * 0.5, 0.35)
        let deepBrightness = max(0.04, min(b * 0.15, 0.08))

        return UIColor(hue: h, saturation: deepSaturation, brightness: deepBrightness, alpha: 1.0)
    }
}

private final class PaletteBox {
    let palette: ArtworkPalette
    init(palette: ArtworkPalette) {
        self.palette = palette
    }
}
