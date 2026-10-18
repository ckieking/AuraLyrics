import SwiftUI

/// UIViewRepresentable 將 PiPLyricsEngine 的 sourceView 嵌入 View 樹狀結構中，確保系統允許啟動畫中畫
struct PiPSourceViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        return PiPLyricsEngine.shared.sourceView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 主導覽分頁視圖（遵循 Apple HIG 標準 TabView 規範，三標籤精簡分頁）
struct MainTabView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        ZStack {
            // 背景不可見但存在於 View 樹狀階層的 PiP 錨點容器
            PiPSourceViewRepresentable()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)

            TabView(selection: $selectedTab) {
                NowPlayingView()
                    .tabItem {
                        Label("正在播放", systemImage: "play.circle.fill")
                    }
                    .tag(0)

                LibraryView()
                    .tabItem {
                        Label("歌詞庫", systemImage: "music.note.list")
                    }
                    .tag(1)

                SettingsView()
                    .tabItem {
                        Label("設定", systemImage: "gearshape.fill")
                    }
                    .tag(2)
            }
            .tint(.pink)
        }
    }
}
