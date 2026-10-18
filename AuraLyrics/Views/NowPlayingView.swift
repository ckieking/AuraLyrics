import SwiftUI
import MediaPlayer
import UIKit

/// Apple Music 正在播放與即時歌詞同步畫面（HIG 沉浸流光舞台 + Liquid Glass 雙層材質與單手拇指熱區）
struct NowPlayingView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var liveActivityEngine = LiveActivityLyricsEngine.shared

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSearchSheet = false
    @State private var showFileImporter = false
    @State private var showTranslation = true
    @State private var autoScroll = true

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
                    Menu {
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
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多歌詞操作選項")
                }
            }
            // MARK: - 功能浮動層：頂部曲目資訊條
            .safeAreaInset(edge: .top) {
                compactTrackHeader
            }
            // MARK: - 功能浮動層：底部單手拇指控制艙 (Thumb-Zone Control Dock)
            .safeAreaInset(edge: .bottom) {
                thumbZoneControlDock
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

            Spacer(minLength: 8)

            // 來源標籤與載入中指示
            HStack(spacing: 5) {
                Text(monitor.currentLyrics.source)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundColor(.secondary)

                if monitor.isLoadingLyrics {
                    ProgressView()
                        .scaleEffect(0.65)
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

    // MARK: - 中央滾動歌詞清單 (Scroll-Through Lyrics)
    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
                                // 點擊手動對齊時間軸並給予輕微觸覺回饋
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                monitor.currentLineIndex = index
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(line.text + (line.translation.map { "，翻譯：\($0)" } ?? ""))
                            .accessibilityHint(isCurrent ? "目前唱到的歌詞" : "點擊跳轉至此句")
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .onChange(of: monitor.currentLineIndex) { newIndex in
                guard autoScroll, let index = newIndex else { return }
                if reduceMotion {
                    proxy.scrollTo(index, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 底部單手拇指控制艙 (Thumb-Zone Control Dock)
    private var thumbZoneControlDock: some View {
        VStack(spacing: 8) {
            // 第一排：雙引擎狀態膠囊開關 (PiP / 動態島)
            HStack(spacing: 10) {
                // PiP 懸浮窗按鈕
                let isPiPOn = pipEngine.isPiPActive || pipEngine.isPiPEnabled
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    pipEngine.togglePiP()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isPiPOn ? "pip.exit" : "pip.enter")
                            .font(.system(size: 15, weight: .bold))
                        Text(isPiPOn ? "懸浮窗：運作中" : "開啟懸浮窗")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                    }
                    .foregroundColor(isPiPOn ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(isPiPOn ? Color.pink : Color(.tertiarySystemFill))
                    .clipShape(Capsule())
                }
                .accessibilityLabel(isPiPOn ? "關閉畫中畫懸浮窗" : "開啟畫中畫懸浮窗")

                // 動態島按鈕（僅在非 LiveContainer 環境下提供）
                if !envDetector.isLiveContainer {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if liveActivityEngine.isActivityActive {
                            liveActivityEngine.endActivity()
                        } else {
                            liveActivityEngine.startActivity(track: monitor.currentTrack)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: liveActivityEngine.isActivityActive ? "dot.radiowaves.left.and.right" : "waveform")
                                .font(.system(size: 15, weight: .bold))
                            Text(liveActivityEngine.isActivityActive ? "動態島：同步中" : "啟動動態島")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                        }
                        .foregroundColor(liveActivityEngine.isActivityActive ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(liveActivityEngine.isActivityActive ? Color.pink : Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel(liveActivityEngine.isActivityActive ? "結束動態島即時動態" : "啟動動態島即時動態")
                }
            }

            // 第二排：時間軸微調、雙語、自動滾動控制項
            HStack(spacing: 12) {
                // 時間偏移 (-0.5s / +0.5s)
                HStack(spacing: 6) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        monitor.adjustOffset(byMs: -500)
                    } label: {
                        Text("-0.5s")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("歌詞延後 0.5 秒")

                    Text(String(format: "%+.1fs", Double(monitor.currentLyrics.offsetMs) / 1000.0))
                        .font(.system(.footnote, design: .monospaced).weight(.bold))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 46)
                        .accessibilityLabel("目前時間偏移 \(String(format: "%.1f", Double(monitor.currentLyrics.offsetMs) / 1000.0)) 秒")

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        monitor.adjustOffset(byMs: 500)
                    } label: {
                        Text("+0.5s")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("歌詞提前 0.5 秒")
                }

                Spacer()

                // 雙語翻譯切換開關
                Toggle(isOn: $showTranslation) {
                    Label("雙語", systemImage: "character.book.closed.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                }
                .toggleStyle(.button)
                .tint(.pink)
                .frame(minHeight: 44)
                .accessibilityLabel("切換雙語翻譯顯示")

                // 自動滾動開關
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    autoScroll.toggle()
                } label: {
                    Image(systemName: autoScroll ? "arrow.up.and.down.circle.fill" : "arrow.up.and.down.circle")
                        .font(.system(size: 20))
                        .foregroundColor(autoScroll ? .pink : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(autoScroll ? "鎖定自動滾動（目前開啟）" : "解鎖自動滾動（目前關閉）")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
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
