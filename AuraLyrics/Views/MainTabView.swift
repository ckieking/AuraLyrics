import SwiftUI

/// 主導覽分頁列舉
enum MainTab: Int, CaseIterable, Identifiable {
    case nowPlaying = 0
    case library = 1
    case settings = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "正在播放"
        case .library: return "歌詞庫"
        case .settings: return "設定"
        }
    }

    func iconName(isSelected: Bool) -> String {
        switch self {
        case .nowPlaying:
            return isSelected ? "play.circle.fill" : "play.circle"
        case .library:
            return "music.note.list"
        case .settings:
            return isSelected ? "gearshape.fill" : "gearshape"
        }
    }
}

/// UIViewRepresentable 將 PiPLyricsEngine 的 sourceView 嵌入 View 樹狀結構中，確保系統允許啟動畫中畫
struct PiPSourceViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        return PiPLyricsEngine.shared.sourceView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 主導覽分頁視圖（純圖示 Dark Liquid Glass 懸浮膠囊底欄）
struct MainTabView: View {
    @State private var selectedTab: MainTab = .nowPlaying
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景不可見但存在於 View 樹狀階層的 PiP 錨點容器
            PiPSourceViewRepresentable()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)

            // 分頁內容層
            TabView(selection: $selectedTab) {
                NowPlayingView()
                    .tag(MainTab.nowPlaying)
                    .toolbar(.hidden, for: .tabBar)

                LibraryView()
                    .tag(MainTab.library)
                    .toolbar(.hidden, for: .tabBar)

                SettingsView()
                    .tag(MainTab.settings)
                    .toolbar(.hidden, for: .tabBar)
            }

            // MARK: - 功能浮動層：Dark Liquid Glass 純圖示懸浮膠囊底欄
            darkLiquidGlassDock
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sensoryFeedback(.selection, trigger: selectedTab)
    }

    // MARK: - Dark Liquid Glass 純圖示懸浮膠囊底欄
    private var darkLiquidGlassDock: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                let isSelected = (selectedTab == tab)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    ZStack {
                        // 選中項目的獨立半透明高光島 (Active Dock Island)
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.16),
                                            Color.white.opacity(0.07)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                                )
                                .frame(width: 68, height: 48)
                                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                                .matchedGeometryEffect(id: "ActiveDockIsland", in: tabNamespace)
                        }

                        Image(systemName: tab.iconName(isSelected: isSelected))
                            .font(.system(size: 21, weight: isSelected ? .bold : .semibold))
                            .foregroundColor(isSelected ? .white : Color.white.opacity(0.72))
                            .symbolEffect(.bounce, value: isSelected)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.94))
                .accessibilityLabel("\(tab.title)分頁\(isSelected ? "，目前選取" : "")")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 62)
        .background {
            if reduceTransparency {
                Capsule(style: .continuous)
                    .fill(Color(.systemGray6))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
                    )
            } else {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)

                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.42))

                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.02),
                                    Color.white.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.85
                        )
                }
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
    }
}
