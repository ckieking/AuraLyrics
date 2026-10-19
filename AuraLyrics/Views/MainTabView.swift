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

/// 主導覽分頁視圖（iOS 27 原生 SwiftUI TabView 控件 + 官方原生液態玻璃底欄）
struct MainTabView: View {
    @State private var selectedTab: MainTab = .nowPlaying

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(MainTab.nowPlaying.title, systemImage: MainTab.nowPlaying.iconName, value: .nowPlaying) {
                NowPlayingView()
            }

            Tab(MainTab.library.title, systemImage: MainTab.library.iconName, value: .library) {
                LibraryView()
            }

            Tab(MainTab.settings.title, systemImage: MainTab.settings.iconName, value: .settings) {
                SettingsView()
            }
        }
        .background {
            // 背景不可見但存在於 View 樹狀階層的 PiP 錨點容器
            PiPSourceViewRepresentable()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }
}
