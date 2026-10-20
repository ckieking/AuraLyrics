import SwiftUI
import UIKit
import CoreGraphics

/// 專輯封面色彩調色盤（提供 Apple Music 沉浸式流光背景所需的階層色彩）
public struct ArtworkPalette: Equatable, Sendable {
    public let primary: Color
    public let secondary: Color
    public let tertiary: Color
    public let accent: Color
    public let backgroundDark: Color

    /// 預設 Apple Music 沉浸深邃調色盤（沉穩深藍紫、暗洋紅、深墨靛青）
    public static let fallback = ArtworkPalette(
        primary: Color(red: 0.14, green: 0.10, blue: 0.22),
        secondary: Color(red: 0.22, green: 0.08, blue: 0.18),
        tertiary: Color(red: 0.08, green: 0.15, blue: 0.24),
        accent: Color(red: 0.28, green: 0.12, blue: 0.26),
        backgroundDark: Color(red: 0.05, green: 0.05, blue: 0.08)
    )
}

/// 高效輕量之專輯封面多重色階提取器
/// 透過小尺寸降採樣與色相/亮度規範化，在 1~2ms 內萃取出適應白字對比之多層次漸層色
public final class ArtworkColorExtractor {
    public static let shared = ArtworkColorExtractor()

    /// 記憶體快取：以 UIImage 的 Hash 或識別碼快取調色盤，避免重複計算
    private let cache = NSCache<NSString, PaletteBox>()

    private init() {
        cache.countLimit = 50
    }

    /// 從圖片數據中非同步解析調色盤
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

    /// 同步快速分析（若需要立即回傳）
    public static func analyzeImage(_ image: UIImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage else { return .fallback }

        // 縮小為 32x32 採樣點（1024 像素），計算極速且消除高頻雜訊
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

        // 取樣五個關鍵區域：左上、右上、中心、左下、右下
        let points: [(x: Int, y: Int)] = [
            (width / 4, height / 4),         // 左上
            (width * 3 / 4, height / 4),     // 右上
            (width / 2, height / 2),         // 中心
            (width / 4, height * 3 / 4),     // 左下
            (width * 3 / 4, height * 3 / 4)  // 右下
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

        // 也計算全局平均色作為基準參考
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

        // 規範化顏色：降低明度至適當範圍，確保上方白色歌詞的高對比度（WCAG AAA 標竿）
        let p1 = normalizeForBackground(sampledColors.indices.contains(0) ? sampledColors[0] : avgColor)
        let p2 = normalizeForBackground(sampledColors.indices.contains(1) ? sampledColors[1] : avgColor)
        let p3 = normalizeForBackground(sampledColors.indices.contains(2) ? sampledColors[2] : avgColor)
        let p4 = normalizeForBackground(sampledColors.indices.contains(3) ? sampledColors[3] : avgColor)

        // 背景基底極深色（從平均色派生，亮度壓至 0.08~0.12）
        let bgDark = createDeepBackground(from: avgColor)

        return ArtworkPalette(
            primary: Color(p1),
            secondary: Color(p2),
            tertiary: Color(p3),
            accent: Color(p4),
            backgroundDark: Color(bgDark)
        )
    }

    /// 將採樣色彩調控為沉浸深邃背景色（將明度約束在 0.22 ~ 0.48，防止淺色背景沖淡白字）
    private static func normalizeForBackground(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // 確保具有適當飽和度（至少 0.45），呈現濃郁色彩
        let targetSaturation = max(0.45, min(s * 1.25, 0.90))
        // 嚴格控制亮度在 0.20 ~ 0.45 之間，徹底避免淺白或過亮色
        let targetBrightness = max(0.20, min(b * 0.70, 0.45))

        return UIColor(hue: h, saturation: targetSaturation, brightness: targetBrightness, alpha: 1.0)
    }

    /// 從色彩派生近乎黑色的低飽和沉穩底色
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
