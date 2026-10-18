import SwiftUI

/// Apple Liquid Glass 視覺系統：專為 iOS 27 原生體驗設計的高質感半透明物理材質
/// 提供次表面散射、動態高光反光邊緣與流體彈簧壓感
public struct LiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var tintColor: Color? = nil
    var active: Bool = false

    public func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Capsule(style: .continuous)
                        .fill(Color(.systemBackground))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                        )
                } else {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)

                        if let tint = tintColor, active {
                            Capsule(style: .continuous)
                                .fill(tint.opacity(0.12))
                        }

                        // 次表面多視角高光邊緣 (Specular Highlight Border)
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.45),
                                        Color.white.opacity(0.12),
                                        Color.white.opacity(0.04),
                                        Color.white.opacity(0.20)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    }
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}

public struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 20

    public func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.35),
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.02),
                                        Color.white.opacity(0.15)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
                }
            }
            .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)
    }
}

public struct LiquidGlassCircleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var isActive: Bool = false
    var activeTint: Color = .pink

    public func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Circle()
                        .fill(isActive ? activeTint : Color(.tertiarySystemFill))
                } else {
                    ZStack {
                        if isActive {
                            Circle()
                                .fill(activeTint)
                        } else {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .fill(Color.primary.opacity(0.04))
                                )
                        }

                        // 高光外圈
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isActive ? 0.40 : 0.35),
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.02),
                                        Color.white.opacity(isActive ? 0.25 : 0.16)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    }
                }
            }
            .shadow(color: (isActive ? activeTint : Color.black).opacity(0.16), radius: 8, x: 0, y: 4)
    }
}

/// 流體彈簧壓感按鈕樣式 (HIG Fluid Springs)
public struct LiquidSpringButtonStyle: ButtonStyle {
    var scaleAmount: CGFloat = 0.94

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

public extension View {
    func liquidGlassCapsule(tintColor: Color? = nil, active: Bool = false) -> some View {
        modifier(LiquidGlassCapsuleModifier(tintColor: tintColor, active: active))
    }

    func liquidGlassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius))
    }

    func liquidGlassCircle(isActive: Bool = false, activeTint: Color = .pink) -> some View {
        modifier(LiquidGlassCircleModifier(isActive: isActive, activeTint: activeTint))
    }
}
