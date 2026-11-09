import SwiftUI
import MediaPlayer
import UIKit
import Translation

/// Now playing view displaying real-time synced lyrics with ambient gradient background and action buttons.
struct NowPlayingView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var liveActivityEngine = LiveActivityLyricsEngine.shared
    @ObservedObject var translationService = LyricsTranslationService.shared

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSearchSheet = false
    @State private var showFileImporter = false
    @State private var isUserScrolling = false
    @AppStorage("showBilingualLyrics") private var showTranslation = true
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true
    @AppStorage("inactiveLyricOpacity") private var inactiveLyricOpacity = 0.10

    /// Translation framework session configuration trigger.
    @State private var translationConfig: TranslationSession.Configuration? = nil

    /// Tracks visible line indices and scroll state without triggering view body redraws.
    @State private var tracker = ViewportTracker()

    /// Tracks whether current focused line is inside viewport.
    @State private var isCurrentLineInViewport: Bool = true

    /// Cached decoded artwork image to prevent repetitive decoding.
    @State private var cachedArtworkImage: UIImage? = nil

    /// Extracted artwork color palette for ambient gradient backdrop.
    @State private var currentPalette: ArtworkPalette = .fallback

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                // MARK: - Lyrics Scroll View
                lyricsScrollView

                // MARK: - Top-Trailing Controls
                HStack(spacing: 12) {
                    pipIndependentButton
                    moreMenuIndependentButton
                }
                .padding(.trailing, 20)
                .padding(.top, 8)
            }
            .background {
                // MARK: - Ambient Backdrop
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
            .onChange(of: showTranslation) { _, isEnabled in
                monitor.syncExternalEngines()
                if isEnabled {
                    checkAndTriggerTranslation()
                }
            }
            .onChange(of: monitor.currentLyrics.id) { _, _ in
                checkAndTriggerTranslation()
            }
            .onChange(of: translationService.currentTargetLanguage) { _, _ in
                checkAndTriggerTranslation(forceTargetLanguageChange: true)
            }
            .translationTask(translationConfig) { session in
                let targetId = translationService.currentTargetLanguage
                let lyrics = monitor.currentLyrics
                if let translated = await LyricsTranslationService.translateLyrics(lyrics, using: session, targetLanguageId: targetId) {
                    monitor.applyTranslatedLyrics(translated)
                }
            }
        }
    }

    /// Checks whether lyrics require translation and triggers translation session.
    private func checkAndTriggerTranslation(forceTargetLanguageChange: Bool = false) {
        guard showTranslation else { return }
        let lyrics = monitor.currentLyrics
        guard !lyrics.lines.isEmpty else { return }

        let targetId = translationService.currentTargetLanguage

        // Convert Simplified to Traditional Chinese directly if applicable, skipping API translation.
        if LyricsTranslationService.isSameLanguage(lyrics: lyrics, targetLanguageId: targetId) {
            if LyricsTranslationService.isTargetHantAndLyricsSimplified(lyrics: lyrics, targetLanguageId: targetId) {
                var converted = LyricsTranslationService.convertLyricsToTraditional(lyrics)
                converted.lines = converted.lines.map { line in
                    var copy = line
                    copy.translation = nil
                    return copy
                }
                converted.translationTargetLanguage = "zh-Hant"
                LyricsProviderService.shared.saveLyricsToCache(converted)
                monitor.applyTranslatedLyrics(converted)
            }
            return
        }

        if forceTargetLanguageChange || LyricsTranslationService.shouldTranslate(lyrics: lyrics, targetLanguageId: targetId) {
            let targetLocale = Locale.Language(identifier: targetId)
            if translationConfig?.target != targetLocale {
                translationConfig = .init(target: targetLocale)
            } else {
                translationConfig?.invalidate()
            }
        }
    }

    // MARK: - Picture-in-Picture Button
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

    // MARK: - More Options Menu
    private var moreMenuIndependentButton: some View {
        let buttonDiameter: CGFloat = 40

        return Menu {
            // Bilingual lyrics toggle
            Toggle(isOn: $showTranslation) {
                Text("雙語歌詞")
            }

            // Target language selection menu
            if showTranslation && !translationService.availableLanguages.isEmpty {
                Menu {
                    Picker("翻譯語言", selection: $translationService.currentTargetLanguage) {
                        ForEach(translationService.availableLanguages) { lang in
                            Text(lang.displayName).tag(lang.identifier)
                        }
                    }
                } label: {
                    Label(
                        String(format: String(localized: "翻譯語言：%@"), currentLanguageDisplayName),
                        systemImage: "character.bubble"
                    )
                }
            }

            // Live Activity toggle
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

    private var currentLanguageDisplayName: String {
        let currentId = translationService.currentTargetLanguage
        return translationService.availableLanguages.first(where: { $0.identifier == currentId })?.displayName ?? currentId
    }

    // MARK: - Ambient Backdrop
    @ViewBuilder
    private var ambientBackdrop: some View {
        AmbientGradientBackground(
            palette: currentPalette,
            artworkImage: cachedArtworkImage
        )
        .accessibilityHidden(true)
    }

    // MARK: - Lyrics Scroll View
    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Top scroll anchor
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
                            let rowBlur = defocusBlurRadius(for: index)

                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if isCurrent {
                                        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !monitor.isPlaying || scenePhase != .active)) { _ in
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
                                isCurrentLineInViewport = true
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
                            .blur(radius: isCurrent ? 0 : rowBlur)
                            .animation(reduceMotion || isUserScrolling ? nil : .easeInOut(duration: 0.35), value: rowOpacity)
                        }

                        // MARK: - Song Credits
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
                        let isVisible: Bool = {
                            guard let current = monitor.currentLineIndex else { return true }
                            return tracker.visibleIndices.contains(current) || current <= 1
                        }()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                            isCurrentLineInViewport = isVisible
                            isUserScrolling = false
                        }
                    }
                }
            }
            // Auto-scrolls to current playing line when visible in viewport
            .onChange(of: monitor.currentLineIndex) { _, newIndex in
                checkCurrentLineVisibility()
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
            // Reset scroll offset on track change
            .onChange(of: monitor.currentTrack) { _, _ in
                scrollToTop(proxy: proxy)
            }
            .onChange(of: monitor.currentLyrics.id) { _, _ in
                scrollToTop(proxy: proxy)
            }
            // Force scroll to current line on appear
            .onAppear {
                updateCachedArtwork()
                checkAndTriggerTranslation()
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

    /// Calculates defocus blur radius based on distance from current focused line.
    private func defocusBlurRadius(for index: Int) -> CGFloat {
        guard enableLyricDefocusBlur, !reduceTransparency, !isUserScrolling, isCurrentLineInViewport, scenePhase == .active else {
            return 0.0
        }
        guard let current = monitor.currentLineIndex else {
            return 0.0
        }
        let distance = abs(index - current)
        switch distance {
        case 0:
            return 0.0  // Current active line remains sharp
        case 1:
            return 0.6  // Immediate adjacent lines
        case 2:
            return 1.8  // Secondary adjacent lines
        default:
            return 3.0  // Distant lines
        }
    }

    /// Calculates opacity based on distance from current focused line.
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
        if !isCurrentLineInViewport || isUserScrolling {
            return max(inactiveLyricOpacity, 0.32) <= 0.35 ? 0.32 : inactiveLyricOpacity
        }
        let base = min(max(inactiveLyricOpacity, 0.05), 0.60)
        switch distance {
        case 1:
            return min(0.40, max(0.30, base * 2.8)) // Distance 1
        case 2:
            return min(0.24, max(0.16, base * 1.8)) // Distance 2
        default:
            return base                             // Distance >= 3
        }
    }

    /// Calculates translation text opacity based on distance from current line.
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
        if !isCurrentLineInViewport || isUserScrolling {
            return max(inactiveLyricOpacity, 0.28) <= 0.35 ? 0.28 : inactiveLyricOpacity
        }
        let base = min(max(inactiveLyricOpacity * 1.15, 0.06), 0.65)
        switch distance {
        case 1:
            return min(0.36, max(0.26, base * 2.5))
        case 2:
            return min(0.22, max(0.14, base * 1.5))
        default:
            return base
        }
    }

    /// Checks whether current focused line is inside the visible viewport.
    private func checkCurrentLineVisibility(animated: Bool = true) {
        guard let current = monitor.currentLineIndex else {
            if !isCurrentLineInViewport {
                isCurrentLineInViewport = true
            }
            return
        }
        let isVisible = tracker.visibleIndices.contains(current) || current <= 1
        if isCurrentLineInViewport != isVisible {
            if animated && !reduceMotion {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isCurrentLineInViewport = isVisible
                }
            } else {
                isCurrentLineInViewport = isVisible
            }
        }
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

    /// Scrolls to current playing lyric line and centers it in view.
    private func forceScrollToCurrentLine(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let currentIndex = monitor.currentLineIndex,
              monitor.currentLyrics.lines.indices.contains(currentIndex) else { return }

        isCurrentLineInViewport = true
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
        isCurrentLineInViewport = true
        if reduceMotion {
            proxy.scrollTo("LyricsTopAnchor", anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("LyricsTopAnchor", anchor: .top)
            }
        }
    }
}

/// Stores visible line indices and scroll state without triggering view body updates.
private final class ViewportTracker {
    var visibleIndices: Set<Int> = []
    var isUserScrolling: Bool = false
    var scrollIdleTask: Task<Void, Never>? = nil
}

