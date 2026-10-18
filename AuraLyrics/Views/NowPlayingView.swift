import SwiftUI
import MediaPlayer
import UIKit

/// Apple Music 正在播放與即時歌詞同步畫面（HIG 沉浸流光舞台 + Liquid Glass 頂部資訊條與智能跟隨）
struct NowPlayingView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var liveActivityEngine = LiveActivityLyricsEngine.shared

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSearchSheet = false
    @State private var showFileImporter = false
    @AppStorage("showBilingualLyrics") private var showTranslation = true

    /// 記錄當前在螢幕可視範圍內的歌詞行索引（支援 Apple Music 智能跟隨）
    @State private var visibleLineIndices: Set<Int> = []

    var body: some View {
        NavigationStack {
            ZStack {
                // MARK: - 內容底層：沉浸式專輯光暈背景 (Ambient Backdrop)
                ambientBackdrop

                // MARK: - 內容中層：可滾動穿透之歌詞清單
                lyricsScrollView
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    environmentBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        // 需求 2：獨立右上角懸浮窗小圓按鈕
                        pipCircularButton

                        // 更多功能選單小圓按鈕
                        moreMenuCircularButton
                    }
                }
            }
            // MARK: - 功能浮動層：頂部曲目資訊條
            .safeAreaInset(edge: .top) {
                compactTrackHeader
            }
            .sheet(isPresented: $showSearchSheet) {
                LyricsSearchSheet(currentTrack: monitor.currentTrack) { selectedLyrics in
                    monitor.applyCustomLyrics(selectedLyrics)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.text, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let imported = LyricsProviderService.shared.importLocalLRCFile(
                            url: url,
                            title: monitor.currentTrack.title,
                            artist: monitor.currentTrack.artist
                        ) {
                            monitor.applyCustomLyrics(imported)
                        }
                    }
                }
            }
            .onChange(of: monitor.currentLineIndex) { newIndex in
                guard let index = newIndex, monitor.currentLyrics.lines.indices.contains(index) else { return }
                let current = monitor.currentLyrics.lines[index]

                var secondaryText: String? = nil
                if showTranslation, let trans = current.translation, !trans.isEmpty {
                    secondaryText = trans
                } else if index + 1 < monitor.currentLyrics.lines.count {
                    secondaryText = monitor.currentLyrics.lines[index + 1].text
                }

                // 推送至 PiP 引擎
                pipEngine.updateLyrics(
                    line: current.text,
                    secondaryLine: secondaryText,
                    progress: monitor.playbackProgress
                )

                // 推送至即時動態引擎
                liveActivityEngine.updateLyrics(
                    line: current.text,
                    secondaryLine: secondaryText,
                    track: monitor.currentTrack,
                    isPlaying: monitor.isPlaying,
                    progress: monitor.playbackProgress
                )
            }
        }
    }

    // MARK: - 右上角獨立小圓按鈕 (PiP 懸浮窗)
    private var pipCircularButton: some View {
        let isPiPOn = pipEngine.isPiPActive || pipEngine.isPiPEnabled
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            pipEngine.togglePiP()
        } label: {
            ZStack {
                Circle()
                    .fill(isPiPOn ? Color.pink : Color(.tertiarySystemFill))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    )

                Image(systemName: isPiPOn ? "pip.exit" : "pip.enter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isPiPOn ? .white : .primary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(isPiPOn ? "關閉畫中畫懸浮窗" : "開啟畫中畫懸浮窗")
    }

    // MARK: - 右上角更多操作選單小圓按鈕
    private var moreMenuCircularButton: some View {
        Menu {
            // 需求 4：雙語改到選單裡，開啟後後面帶有單純勾勾 (checkmark)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showTranslation.toggle()
            } label: {
                if showTranslation {
                    Label("雙語歌詞", systemImage: "checkmark")
                } else {
                    Text("雙語歌詞")
                }
            }

            // 動態島開關（在非 LiveContainer 環境下提供）
            if !envDetector.isLiveContainer {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if liveActivityEngine.isActivityActive {
                        liveActivityEngine.endActivity()
                    } else {
                        liveActivityEngine.startActivity(track: monitor.currentTrack)
                    }
                } label: {
                    Label(
                        liveActivityEngine.isActivityActive ? "結束動態島同步" : "啟動動態島同步",
                        systemImage: liveActivityEngine.isActivityActive ? "waveform.badge.minus" : "waveform.badge.plus"
                    )
                }
            }

            Divider()

            Button {
                showSearchSheet = true
            } label: {
                Label("線上搜尋歌詞", systemImage: "magnifyingglass")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("匯入本地 .lrc", systemImage: "square.and.arrow.down")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    )

                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("更多歌詞操作選項")
    }

    // MARK: - 沉浸式氛圍背景 (Ambient Backdrop)
    @ViewBuilder
    private var ambientBackdrop: some View {
        if !reduceTransparency,
           let artworkData = monitor.currentTrack.artworkData,
           let uiImage = UIImage(data: artworkData) {
            GeometryReader { geo in
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 50)
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color(.systemBackground).opacity(0.85),
                                Color(.systemBackground).opacity(0.70),
                                Color(.systemBackground).opacity(0.92)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        } else {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    // MARK: - 頂部精簡浮動曲目卡 (Compact Track Header)
    private var compactTrackHeader: some View {
        HStack(spacing: 12) {
            // 封面圖示
            if let artworkData = monitor.currentTrack.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 46, height: 46)
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.pink)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.currentTrack.title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(monitor.currentTrack.artist)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 來源標籤
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.pink)
                if !monitor.currentLyrics.source.isEmpty && monitor.currentLyrics.source != "None" {
                    Text(monitor.currentLyrics.source)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                } else {
                    Text("AuraLyrics")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - 中央滾動歌詞清單 (Scroll-Through Lyrics with Apple Music Smart Follow)
    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 頂部回滾定位錨點
                Color.clear
                    .frame(height: 1)
                    .id("LyricsTopAnchor")

                if monitor.currentLyrics.lines.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 42))
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)

                        Text(monitor.isLoadingLyrics ? "正在為你檢索同步歌詞..." : "目前曲目無同步時間軸歌詞")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.primary)

                        Text("可嘗試線上搜尋其他版本，或手動匯入本地 .lrc 檔案")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        HStack(spacing: 12) {
                            Button {
                                showSearchSheet = true
                            } label: {
                                Label("搜尋歌詞", systemImage: "magnifyingglass")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pink)

                            Button {
                                showFileImporter = true
                            } label: {
                                Label("匯入 .lrc", systemImage: "square.and.arrow.down")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 100)
                } else {
                    LazyVStack(spacing: 24) {
                        ForEach(Array(monitor.currentLyrics.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = (index == monitor.currentLineIndex)

                            HStack(alignment: .top, spacing: 10) {
                                // 當前歌詞行指示色條
                                Capsule()
                                    .fill(isCurrent ? Color.pink : Color.clear)
                                    .frame(width: 4)
                                    .frame(maxHeight: .infinity)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(line.text)
                                        .font(.system(isCurrent ? .title2 : .title3, design: .rounded))
                                        .fontWeight(isCurrent ? .bold : .medium)
                                        .foregroundColor(isCurrent ? .primary : .secondary)
                                        .multilineTextAlignment(.leading)

                                    if showTranslation, let trans = line.translation, !trans.isEmpty {
                                        Text(trans)
                                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                                            .foregroundColor(isCurrent ? .pink : Color(.secondaryLabel))
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 點擊手動對齊時間軸並給予輕微觸覺回饋，同時置中畫面恢復跟隨
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                monitor.currentLineIndex = index
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                            .onAppear {
                                visibleLineIndices.insert(index)
                            }
                            .onDisappear {
                                visibleLineIndices.remove(index)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(line.text + (line.translation.map { "，翻譯：\($0)" } ?? ""))
                            .accessibilityHint(isCurrent ? "目前唱到的歌詞" : "點擊跳轉至此句")
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 96) // 預留底部空間，避免被懸浮底欄遮蔽
                }
            }
            // 需求 5：Apple Music 智能跟隨（播放中歌詞在畫面內才跟隨，移出畫面外暫停，回到畫面繼續）
            .onChange(of: monitor.currentLineIndex) { newIndex in
                guard let index = newIndex else { return }
                let isVisible = visibleLineIndices.contains(index)
                if isVisible {
                    if reduceMotion {
                        proxy.scrollTo(index, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
            // 需求 6：每首歌播完切換下一首時顯示新歌詞並同時滾動回最上方（無視歌詞是否在畫面內外）
            .onChange(of: monitor.currentTrack.title) { _ in
                scrollToTop(proxy: proxy)
            }
            .onChange(of: monitor.currentLyrics.id) { _ in
                scrollToTop(proxy: proxy)
            }
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        visibleLineIndices.removeAll()
        if reduceMotion {
            proxy.scrollTo("LyricsTopAnchor", anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("LyricsTopAnchor", anchor: .top)
            }
        }
    }

    // MARK: - 環境標籤
    private var environmentBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(envDetector.isLiveContainer ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(envDetector.isLiveContainer ? "LiveContainer" : "獨立側載")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(envDetector.isLiveContainer ? "運行於 LiveContainer 容器環境" : "運行於原生獨立側載環境")
    }
}
