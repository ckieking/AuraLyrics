import SwiftUI

/// Main navigation tabs.
enum MainTab: Int, CaseIterable, Identifiable {
    case nowPlaying = 0
    case library = 1
    case settings = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return String(localized: "正在播放")
        case .library: return String(localized: "歌詞庫")
        case .settings: return String(localized: "設定")
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

/// Embeds PiPLyricsEngine sourceView in the view hierarchy for Picture-in-Picture session initialization.
struct PiPSourceViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        return PiPLyricsEngine.shared.sourceView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Main navigation tab view.
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
            // Invisible PiP source view anchor within view tree
            PiPSourceViewRepresentable()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }
}
