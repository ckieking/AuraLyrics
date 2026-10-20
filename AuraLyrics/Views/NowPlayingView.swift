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
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSearchSheet = false
    @State private var showFileImporter = false
    @AppStorage("showBilingualLyrics") private var showTranslation = true
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true

    /// 零重繪之可視行索引追蹤器（參考型別，不觸發全視圖 body 刷新）
    @State private var tracker = ViewportTracker()

    /// 焦點歌詞當前是否在螢幕可視範圍內（僅在布林值翻轉時更新 @State）
    @State private var isCurrentLineInViewport: Bool = true

    /// 記錄使用者是否正在手動滑動螢幕（滑動時立即解除模糊，閒置 1.5s 平滑恢復）
    @State private var isUserScrolling: Bool = false
    @State private var scrollIdleTask: Task<Void, Never>? = nil

    /// 快取解碼後之專輯封面圖，避免在 body 內高頻重複解碼 PNG
    @State private var cachedArtworkImage: UIImage? = nil

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
            .onChange(of: showTranslation) { _, _ in
                monitor.syncExternalEngines()
            }
        }
    }

    // MARK: - 右上角獨立按鈕：畫中畫 (PiP 懸浮窗，直徑 40pt，按鈕即為最底層)
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
            //雙語歌詞選項
            Button {
                showTranslation.toggle()
            } label: {
                if showTranslation {
                    Label("雙語歌詞", systemImage: "checkmark")
                } else {
                    Text("雙語歌詞")
                }
            }

            // 即時動態與動態島開關（在非 LiveContainer 環境下提供，雙向同步設定）
            if !envDetector.isLiveContainer {
                Button {
                    if liveActivityEngine.isEnabled {
                        liveActivityEngine.isEnabled = false
                    } else {
                        liveActivityEngine.isEnabled = true
                        liveActivityEngine.startActivity(track: monitor.currentTrack)
                        monitor.syncExternalEngines()
                    }
                } label: {
                    Label(
                        liveActivityEngine.isEnabled ? "關閉即時動態與動態島" : "開啟即時動態與動態島",
                        systemImage: liveActivityEngine.isEnabled ? "waveform.badge.minus" : "waveform.badge.plus"
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

    // MARK: - 沉浸式氛圍背景 (Ambient Backdrop，快取解碼避免每幀 PNG 重複解碼)
    @ViewBuilder
    private var ambientBackdrop: some View {
        if !reduceTransparency, let uiImage = cachedArtworkImage {
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

                        Text(monitor.isLoadingLyrics ? "正在檢索歌詞..." : "目前曲目無對應歌詞")
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
                    LazyVStack(spacing: 26) {
                        ForEach(Array(monitor.currentLyrics.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = (index == monitor.currentLineIndex)

                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if isCurrent {
                                        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !monitor.isPlaying)) { _ in
                                            let currentPlayMs = monitor.interpolatedPlaybackTimeMs()
                                            AppleMusicKaraokeText(
                                                text: line.text,
                                                syllables: line.syllables,
                                                isCurrent: true,
                                                currentPlaybackTimeMs: currentPlayMs,
                                                blurRadius: 0
                                            )
                                        }
                                    } else {
                                        AppleMusicKaraokeText(
                                            text: line.text,
                                            syllables: line.syllables,
                                            isCurrent: false,
                                            currentPlaybackTimeMs: 0,
                                            blurRadius: blurRadius(for: index)
                                        )
                                        .animation(.easeInOut(duration: 0.35), value: blurRadius(for: index))
                                    }

                                    if showTranslation, let trans = line.translation, !trans.isEmpty {
                                        Text(trans)
                                            .font(.system(size: 16, weight: .medium, design: .default))
                                            .foregroundColor(isCurrent ? .pink : Color(.secondaryLabel))
                                            .blur(radius: isCurrent ? 0 : translationBlurRadius(for: index))
                                            .animation(.easeInOut(duration: 0.35), value: translationBlurRadius(for: index))
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                scrollIdleTask?.cancel()
                                scrollIdleTask = nil
                                isUserScrolling = false
                                monitor.seek(toMs: line.timeMs)
                                isCurrentLineInViewport = true
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                            .onAppear {
                                tracker.visibleIndices.insert(index)
                                checkCurrentLineVisibility()
                            }
                            .onDisappear {
                                tracker.visibleIndices.remove(index)
                                checkCurrentLineVisibility()
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
            .onScrollPhaseChange { oldPhase, newPhase in
                if newPhase == .interacting || newPhase == .decelerating {
                    scrollIdleTask?.cancel()
                    scrollIdleTask = nil
                    if !isUserScrolling {
                        isUserScrolling = true
                    }
                } else if newPhase == .idle {
                    scrollIdleTask?.cancel()
                    scrollIdleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        isUserScrolling = false
                    }
                }
            }
            //智能跟隨（播放中歌詞在畫面內才跟隨，移出畫面外暫停，回到畫面繼續；初始前兩行必定跟隨）
            .onChange(of: monitor.currentLineIndex) { _, newIndex in
                checkCurrentLineVisibility()
                guard let index = newIndex else { return }
                let isVisible = tracker.visibleIndices.contains(index) || index <= 1
                if isVisible && !isUserScrolling {
                    if reduceMotion {
                        proxy.scrollTo(index, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
            //每首歌播完切換下一首時顯示新歌詞並同時滾動回最上方（無視歌詞是否在畫面內外）
            .onChange(of: monitor.currentTrack) { _, _ in
                scrollToTop(proxy: proxy)
            }
            .onChange(of: monitor.currentLyrics.id) { _, _ in
                scrollToTop(proxy: proxy)
            }
            //當使用者重新將本頁面作為焦點頁面時（App 回到前景、分頁切回），強制定位到目前歌詞進度並恢復跟隨
            .onAppear {
                updateCachedArtwork()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    forceScrollToCurrentLine(proxy: proxy, animated: false)
                }
            }
            .onDisappear {
                scrollIdleTask?.cancel()
                scrollIdleTask = nil
            }
            .onChange(of: monitor.currentTrack.artworkData) { _, _ in
                updateCachedArtwork()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { return }
                        forceScrollToCurrentLine(proxy: proxy, animated: true)
                    }
                }
            }
        }
    }

    /// 計算主歌詞行的單層級景深模糊半徑（非焦點行統一 2.0pt，換行時僅 2 行切換狀態，極致省電流暢）
    private func blurRadius(for index: Int) -> CGFloat {
        guard enableLyricDefocusBlur, !reduceTransparency, !isUserScrolling, isCurrentLineInViewport else {
            return 0.0
        }
        guard let current = monitor.currentLineIndex else {
            return 0.0
        }
        return (index == current) ? 0.0 : 2.0
    }

    /// 計算翻譯文字的單層級景深模糊半徑
    private func translationBlurRadius(for index: Int) -> CGFloat {
        guard enableLyricDefocusBlur, !reduceTransparency, !isUserScrolling, isCurrentLineInViewport else {
            return 0.0
        }
        guard let current = monitor.currentLineIndex else {
            return 0.0
        }
        return (index == current) ? 0.0 : 1.2
    }

    /// 檢查焦點行是否在目前畫面可視範圍內（僅在結果翻轉時更新 @State）
    private func checkCurrentLineVisibility() {
        guard let current = monitor.currentLineIndex else {
            if !isCurrentLineInViewport {
                isCurrentLineInViewport = true
            }
            return
        }
        let isVisible = tracker.visibleIndices.contains(current) || current <= 1
        if isCurrentLineInViewport != isVisible {
            isCurrentLineInViewport = isVisible
        }
    }

    private func updateCachedArtwork() {
        if let data = monitor.currentTrack.artworkData {
            cachedArtworkImage = UIImage(data: data)
        } else {
            cachedArtworkImage = nil
        }
    }

    /// 強制滾動定位至當前正在播放的歌詞行（居中），並自然將其納入 tracker 以恢復智能跟隨
    private func forceScrollToCurrentLine(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let currentIndex = monitor.currentLineIndex,
              monitor.currentLyrics.lines.indices.contains(currentIndex) else { return }

        if reduceMotion || !animated {
            proxy.scrollTo(currentIndex, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.40)) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        tracker.visibleIndices.removeAll()
        if reduceMotion {
            proxy.scrollTo("LyricsTopAnchor", anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("LyricsTopAnchor", anchor: .top)
            }
        }
    }
}

/// 零重繪之可視行索引追蹤器（參考型別，不觸發全視圖 body 刷新）
private final class ViewportTracker {
    var visibleIndices: Set<Int> = []
}

