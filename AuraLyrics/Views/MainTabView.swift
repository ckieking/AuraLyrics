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

    var iconName: String {
        switch self {
        case .nowPlaying: return "play.circle.fill"
        case .library: return "music.note.list"
        case .settings: return "gearshape.fill"
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

/// 主導覽分頁視圖（iOS 27 原生 Apple Liquid Glass 懸浮動態膠囊底欄）
struct MainTabView: View {
    @State private var selectedTab: MainTab = .nowPlaying
    @Namespace private var tabNamespace

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

            // MARK: - 功能浮動層：Apple Liquid Glass 懸浮膠囊底欄
            liquidGlassBottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sensoryFeedback(.selection, trigger: selectedTab)
    }

    // MARK: - Apple Liquid Glass 懸浮膠囊底欄
    private var liquidGlassBottomBar: some View {
        HStack(spacing: 6) {
            ForEach(MainTab.allCases) { tab in
                let isSelected = (selectedTab == tab)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                            .foregroundColor(isSelected ? .pink : .secondary)
                            .symbolEffect(.bounce, value: isSelected)

                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.pink.opacity(0.12))
                                .matchedGeometryEffect(id: "ActiveTabGlass", in: tabNamespace)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.pink.opacity(0.28), lineWidth: 0.85)
                                )
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.95))
                .accessibilityLabel("\(tab.title)分頁\(isSelected ? "，目前選取" : "")")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .liquidGlassCapsule()
    }
}
