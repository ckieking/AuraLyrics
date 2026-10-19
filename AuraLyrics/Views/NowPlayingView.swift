import SwiftUI
import MediaPlayer
import UIKit

/// Apple Music 正在播放與即時歌詞同步畫面（iOS 27 原生 Apple HIG 沉浸流光舞台 + 右上角獨立放大 Liquid Glass 雙圓鈕）
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
            ZStack(alignment: .topTrailing) {
                // MARK: - 內容底層：沉浸式動態專輯流光背景 (Ambient Backdrop)
                ambientBackdrop

                // MARK: - 內容中層：可滾動穿透之歌詞清單
                lyricsScrollView

                // MARK: - 內容頂層：右上角兩顆完全獨立放大的 Liquid Glass 圓形按鈕
                // 擺脫系統 ToolbarItem 自動分組機制，徹底消除系統膠囊底襯，按鈕即為最底層！
                HStack(spacing: 12) {
                    pipIndependentButton
                    moreMenuIndependentButton
                }
                .padding(.trailing, 20)
                .padding(.top, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
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
            .onChange(of: monitor.currentLineIndex) { _, newIndex in
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

    // MARK: - 右上角獨立小圓按鈕：畫中畫 (PiP 懸浮窗，直徑 40pt，按鈕即為最底層)
    private var pipIndependentButton: some View {
        let isPiPOn = pipEngine.isPiPActive || pipEngine.isPiPEnabled
        let buttonDiameter: CGFloat = 40

        return Button {
            pipEngine.togglePiP()
        } label: {
            ZStack {
                Image(systemName: isPiPOn ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isPiPOn ? .white : .primary)
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: isPiPOn, activeTint: .pink)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.90))
        .sensoryFeedback(.impact(weight: .medium), trigger: isPiPOn)
        .accessibilityLabel(isPiPOn ? "關閉畫中畫懸浮窗" : "開啟畫中畫懸浮窗")
    }

    // MARK: - 右上角獨立小圓按鈕：更多操作選單 (直徑 40pt，按鈕即為最底層)
    private var moreMenuIndependentButton: some View {
        let buttonDiameter: CGFloat = 40

        return Menu {
            // 需求 4：雙語改到選單裡，開啟後後面帶有單純勾勾 (checkmark)
            Button {
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: false)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.90))
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
                    .blur(radius: 54)
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color(.systemBackground).opacity(0.82),
                                Color(.systemBackground).opacity(0.68),
                                Color(.systemBackground).opacity(0.94)
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

                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if isCurrent {
                                        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !monitor.isPlaying)) { _ in
                                            let currentPlayMs = monitor.interpolatedPlaybackTimeMs()
                                            AppleMusicKaraokeText(
                                                text: line.text,
                                                syllables: line.syllables,
                                                isCurrent: true,
                                                currentPlaybackTimeMs: currentPlayMs
                                            )
                                        }
                                    } else {
                                        AppleMusicKaraokeText(
                                            text: line.text,
                                            syllables: line.syllables,
                                            isCurrent: false,
                                            currentPlaybackTimeMs: 0
                                        )
                                    }

                                    if showTranslation, let trans = line.translation, !trans.isEmpty {
                                        Text(trans)
                                            .font(.system(.body, design: .default).weight(.medium))
                                            .foregroundColor(isCurrent ? .pink : Color(.secondaryLabel))
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                monitor.currentLineIndex = index
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                            .sensoryFeedback(.impact(weight: .light), trigger: monitor.currentLineIndex)
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

                        // MARK: - Apple Music 原生風格：參與人員與創作名單 (Credits, e.g. Written by ...)
                        if !monitor.currentLyrics.credits.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("參與人員")
                                    .font(.system(size: 15, weight: .semibold, design: .default))
                                    .foregroundColor(Color.white.opacity(0.65))
                                    .padding(.bottom, 2)

                                ForEach(Array(monitor.currentLyrics.credits.enumerated()), id: \.offset) { _, credit in
                                    Text(credit)
                                        .font(.system(size: 13, weight: .regular, design: .default))
                                        .foregroundColor(Color.white.opacity(0.42))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 36)
                            .padding(.bottom, 48)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            // 需求 5：Apple Music 智能跟隨（播放中歌詞在畫面內才跟隨，移出畫面外暫停，回到畫面繼續；初始前兩行必定跟隨）
            .onChange(of: monitor.currentLineIndex) { _, newIndex in
                guard let index = newIndex else { return }
                let isVisible = visibleLineIndices.contains(index) || index <= 1
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
            .onChange(of: monitor.currentTrack) { _, _ in
                scrollToTop(proxy: proxy)
            }
            .onChange(of: monitor.currentLyrics.id) { _, _ in
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
}

