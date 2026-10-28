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
    @State private var isUserScrolling = false
    @AppStorage("showBilingualLyrics") private var showTranslation = true
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true
    @AppStorage("inactiveLyricOpacity") private var inactiveLyricOpacity = 0.10

    /// 零重繪之可視行索引與滾動狀態追蹤器（參考型別，不觸發全視圖 body 刷新）
    @State private var tracker = ViewportTracker()

    /// 快取解碼後之專輯封面圖，避免在 body 內高頻重複解碼 PNG
    @State private var cachedArtworkImage: UIImage? = nil

    /// 當前專輯封面解析出之色彩調色盤（Apple Music 沉浸式流光背景）
    @State private var currentPalette: ArtworkPalette = .fallback

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                // MARK: - 內容層：可滾動穿透之歌詞清單（置於純淨空間，絕不被底層背景干擾佈局尺寸）
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
            .background {
                // MARK: - 內容底層修飾：沉浸式動態專輯流光背景 (Ambient Backdrop)
                ambientBackdrop
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

    // MARK: - 右上角獨立按鈕：子母畫面 (PiP，直徑 40pt，按鈕即為最底層)
    private var pipIndependentButton: some View {
        let isPiPOn = pipEngine.isPiPActive || pipEngine.isPiPEnabled
        let buttonDiameter: CGFloat = 40

        return Button {
            pipEngine.togglePiP()
        } label: {
            ZStack {
                Image(systemName: isPiPOn ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: isPiPOn, activeTint: .pink)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.90))
        .sensoryFeedback(.impact(weight: .medium), trigger: isPiPOn)
        .accessibilityLabel(isPiPOn ? String(localized: "關閉子母畫面 (PiP)") : String(localized: "開啟子母畫面 (PiP)"))
    }

    // MARK: - 右上角獨立小圓按鈕：更多操作選單 (直徑 40pt，按鈕即為最底層)
    private var moreMenuIndependentButton: some View {
        let buttonDiameter: CGFloat = 40

        return Menu {
            // 雙語歌詞選項
            Toggle(isOn: $showTranslation) {
                Text("雙語歌詞")
            }

            // 即時動態與動態島開關（在非 LiveContainer 環境下提供，雙向同步設定）
            if !envDetector.isLiveContainer {
                Toggle(isOn: Binding(
                    get: { liveActivityEngine.isEnabled },
                    set: { enabled in
                        liveActivityEngine.isEnabled = enabled
                        if enabled {
                            liveActivityEngine.startActivity(track: monitor.currentTrack)
                            monitor.syncExternalEngines()
                        }
                    }
                )) {
                    Text("即時動態與動態島")
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
                    .foregroundColor(.white)
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: false)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.90))
        .accessibilityLabel(String(localized: "更多歌詞操作選項"))
    }

    // MARK: - 沉浸式氛圍背景 (Apple Music 原生 Mesh 漸層，不受深淺模式影響，高對比度)
    @ViewBuilder
    private var ambientBackdrop: some View {
        AmbientGradientBackground(
            palette: currentPalette,
            artworkImage: cachedArtworkImage
        )
        .accessibilityHidden(true)
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
                            .foregroundColor(Color.white.opacity(0.45))
                            .accessibilityHidden(true)

                        Text(monitor.isLoadingLyrics ? "正在檢索歌詞..." : "目前曲目無對應歌詞")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)

                        Text("可嘗試線上搜尋其他版本，或手動匯入本地 .lrc 檔案")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.68))
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
                            .tint(.white)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 100)
                } else {
                    LazyVStack(spacing: 26) {
                        ForEach(Array(monitor.currentLyrics.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = (index == monitor.currentLineIndex)
                            let rowOpacity = lyricOpacity(for: index)

                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 6) {
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
                                            currentPlaybackTimeMs: 0,
                                            opacity: rowOpacity
                                        )
                                    }

                                    if showTranslation, let trans = line.translation, !trans.isEmpty {
                                        Text(trans)
                                            .font(.system(size: 16, weight: .medium, design: .default))
                                            .foregroundColor(isCurrent ? .pink : Color.white.opacity(translationOpacity(for: index)))
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
                                tracker.scrollIdleTask?.cancel()
                                tracker.scrollIdleTask = nil
                                tracker.isUserScrolling = false
                                if isUserScrolling {
                                    withAnimation(.easeInOut(duration: 0.35)) {
                                        isUserScrolling = false
                                    }
                                }
                                monitor.seek(toMs: line.timeMs)
                                if reduceMotion {
                                    proxy.scrollTo(index, anchor: .center)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.35)) {
                                        proxy.scrollTo(index, anchor: .center)
                                    }
                                }
                            }
                            .onAppear {
                                tracker.visibleIndices.insert(index)
                            }
                            .onDisappear {
                                tracker.visibleIndices.remove(index)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(line.text + (line.translation.map { String(format: String(localized: "，翻譯：%@"), $0) } ?? ""))
                            .accessibilityHint(isCurrent ? String(localized: "目前唱到的歌詞") : String(localized: "點擊跳轉至此句"))
                            .animation(reduceMotion || isUserScrolling ? nil : .easeInOut(duration: 0.35), value: rowOpacity)
                        }

                        // MARK: - Apple Music 原生風格：製作團隊與創作名單 (Credits, e.g. Written by ...)
                        if !monitor.currentLyrics.credits.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("製作團隊")
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
                    .padding(.top, 60)
                    .padding(.bottom, 72)
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                if newPhase == .interacting || newPhase == .decelerating {
                    tracker.scrollIdleTask?.cancel()
                    tracker.scrollIdleTask = nil
                    tracker.isUserScrolling = true
                    if !isUserScrolling {
                        isUserScrolling = true
                    }
                } else if newPhase == .idle {
                    tracker.scrollIdleTask?.cancel()
                    tracker.scrollIdleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled else { return }
                        tracker.isUserScrolling = false
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isUserScrolling = false
                        }
                    }
                }
            }
            //智能跟隨（播放中歌詞在畫面內才跟隨，移出畫面外暫停，回到畫面繼續；初始前兩行必定跟隨）
            .onChange(of: monitor.currentLineIndex) { _, newIndex in
                guard let index = newIndex else { return }
                let isVisible = tracker.visibleIndices.contains(index) || index <= 1
                if isVisible && !tracker.isUserScrolling {
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
                tracker.scrollIdleTask?.cancel()
                tracker.scrollIdleTask = nil
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

    /// 計算非焦點歌詞行之光學景深階梯透明度（原生硬體友善渲染，0 離屏 Pass，杜絕動畫雪崩與 GPU 負載）
    private func lyricOpacity(for index: Int) -> Double {
        guard let current = monitor.currentLineIndex else {
            return reduceTransparency ? 0.70 : 0.40
        }
        let distance = abs(index - current)
        if distance == 0 {
            return 1.0
        }
        if reduceTransparency {
            return 0.70
        }
        guard enableLyricDefocusBlur else {
            return 0.50
        }
        if isUserScrolling {
            return 0.65 // 使用者滑動螢幕時即時解除暗化，清晰展示全部可見歌詞
        }
        let base = min(max(inactiveLyricOpacity, 0.05), 0.60)
        let neighbor = min(0.85, base * 2.2)
        return (distance == 1) ? neighbor : base
    }

    /// 計算翻譯文字之階梯式景深透明度（依循無障礙與視覺焦點階層）
    private func translationOpacity(for index: Int) -> Double {
        guard let current = monitor.currentLineIndex else {
            return reduceTransparency ? 0.75 : 0.45
        }
        let distance = abs(index - current)
        if distance == 0 {
            return 1.0
        }
        if reduceTransparency {
            return 0.75
        }
        guard enableLyricDefocusBlur else {
            return 0.55
        }
        if isUserScrolling {
            return 0.65
        }
        let base = min(max(inactiveLyricOpacity * 1.15, 0.06), 0.65)
        let neighbor = min(0.85, base * 2.2)
        return (distance == 1) ? neighbor : base
    }

    private func updateCachedArtwork() {
        if let data = monitor.currentTrack.artworkData {
            let image = UIImage(data: data)
            cachedArtworkImage = image
            let key = "\(monitor.currentTrack.title)-\(monitor.currentTrack.artist)"
            Task { @MainActor in
                let palette = await ArtworkColorExtractor.shared.extractPalette(from: image, cacheKey: key)
                withAnimation(.easeInOut(duration: 0.8)) {
                    currentPalette = palette
                }
            }
        } else {
            cachedArtworkImage = nil
            withAnimation(.easeInOut(duration: 0.8)) {
                currentPalette = .fallback
            }
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

/// 零重繪之可視行索引與滾動狀態追蹤器（參考型別，不觸發全視圖 body 刷新）
private final class ViewportTracker {
    var visibleIndices: Set<Int> = []
    var isUserScrolling: Bool = false
    var scrollIdleTask: Task<Void, Never>? = nil
}

