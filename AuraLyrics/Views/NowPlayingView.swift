import SwiftUI
import MediaPlayer

/// Apple Music 正在播放與即時歌詞同步畫面
struct NowPlayingView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var liveActivityEngine = LiveActivityLyricsEngine.shared

    @State private var showSearchSheet = false
    @State private var showFileImporter = false
    @State private var showTranslation = true
    @State private var autoScroll = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 頂部曲目資訊與狀態橫幅
                trackHeaderView
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Divider()

                // 中央同步滾動歌詞清單
                lyricsScrollView

                Divider()

                // 底部就近操作工具列（符合 HIG Task-Specific Options 規範）
                bottomQuickToolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
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

                        Divider()

                        if monitor.isSimulationMode {
                            Button(role: .destructive) {
                                monitor.stopSimulation()
                            } label: {
                                Label("結束模擬播放", systemImage: "stop.circle")
                            }
                        } else {
                            Button {
                                monitor.startSimulation(sampleLyrics: SampleLyricsData.sample)
                            } label: {
                                Label("啟動模擬示範播放", systemImage: "play.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17))
                    }
                }
            }
            .sheet(isPresented: $showSearchSheet) {
                LyricsSearchSheet(currentTrack: monitor.currentTrack) { selectedLyrics in
                    monitor.applyCustomLyrics(selectedLyrics)
                }
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

    // MARK: - 頂部曲目資訊
    private var trackHeaderView: some View {
        HStack(spacing: 14) {
            // 封面圖示
            if let artworkData = monitor.currentTrack.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 54, height: 54)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 54, height: 54)
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
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

                HStack(spacing: 6) {
                    Text("來源: \(monitor.currentLyrics.source)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(6)

                    if monitor.isLoadingLyrics {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }

            Spacer()

            // 雙引擎快速啟動按鈕組
            engineActionButtons
        }
    }

    // MARK: - 引擎啟動按鈕
    private var engineActionButtons: some View {
        HStack(spacing: 8) {
            // PiP 畫中畫按鈕
            Button {
                pipEngine.togglePiP()
            } label: {
                Image(systemName: pipEngine.isPiPActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(pipEngine.isPiPActive ? .white : .primary)
                    .frame(width: 40, height: 40)
                    .background(pipEngine.isPiPActive ? Color.accentColor : Color(.tertiarySystemFill))
                    .clipShape(Circle())
            }

            // 動態島即時動態按鈕（非 LiveContainer 時啟用）
            if !envDetector.isLiveContainer {
                Button {
                    if liveActivityEngine.isActivityActive {
                        liveActivityEngine.endActivity()
                    } else {
                        liveActivityEngine.startActivity(track: monitor.currentTrack)
                    }
                } label: {
                    Image(systemName: liveActivityEngine.isActivityActive ? "dot.radiowaves.left.and.right" : "waveform")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(liveActivityEngine.isActivityActive ? .white : .primary)
                        .frame(width: 40, height: 40)
                        .background(liveActivityEngine.isActivityActive ? Color.pink : Color(.tertiarySystemFill))
                        .clipShape(Circle())
                }
            }
        }
    }

    // MARK: - 中央滾動歌詞清單
    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if monitor.currentLyrics.lines.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(monitor.isLoadingLyrics ? "正在為你抓取歌詞..." : "目前曲目無同步歌詞")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.secondary)

                        Button("手動搜尋歌詞") {
                            showSearchSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVStack(spacing: 20) {
                        ForEach(Array(monitor.currentLyrics.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = (index == monitor.currentLineIndex)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text)
                                    .font(.system(isCurrent ? .title3 : .body, design: .rounded))
                                    .fontWeight(isCurrent ? .bold : .medium)
                                    .foregroundColor(isCurrent ? .primary : .secondary.opacity(0.8))
                                    .multilineTextAlignment(.leading)

                                if showTranslation, let trans = line.translation, !trans.isEmpty {
                                    Text(trans)
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundColor(isCurrent ? .accentColor : .secondary.opacity(0.6))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 點擊手動對齊時間
                                monitor.currentLineIndex = index
                            }
                        }
                    }
                    .padding(.vertical, 32)
                }
            }
            .onChange(of: monitor.currentLineIndex) { newIndex in
                if autoScroll, let index = newIndex {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 底部快速工具列
    private var bottomQuickToolbar: some View {
        HStack(spacing: 16) {
            // 時間軸微調控制 (-0.5s / +0.5s)
            HStack(spacing: 8) {
                Button {
                    monitor.adjustOffset(byMs: -500)
                } label: {
                    Text("-0.5s")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Text(String(format: "%+.1fs", Double(monitor.currentLyrics.offsetMs) / 1000.0))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 46)

                Button {
                    monitor.adjustOffset(byMs: 500)
                } label: {
                    Text("+0.5s")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Spacer()

            // 雙語翻譯切換開關
            Toggle(isOn: $showTranslation) {
                Label("雙語", systemImage: "character.book.closed")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            .toggleStyle(.button)
            .controlSize(.small)

            // 自動滾動開關
            Button {
                autoScroll.toggle()
            } label: {
                Image(systemName: autoScroll ? "arrow.up.and.down.circle.fill" : "arrow.up.and.down.circle")
                    .font(.system(size: 16))
            }
        }
    }

    // MARK: - 環境標籤
    private var environmentBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(envDetector.isLiveContainer ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(envDetector.isLiveContainer ? "LiveContainer" : "原生側載")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 內建模擬示範歌詞資料
public struct SampleLyricsData {
    public static let sample = SyncedLyrics(
        trackTitle: "夜曲 (示範曲目)",
        artistName: "周杰倫",
        lines: [
            LyricLine(timeMs: 0, text: "一群嗜血的螞蟻 被腐肉所吸引", translation: "A swarm of bloodthirsty ants attracted by decaying flesh"),
            LyricLine(timeMs: 4000, text: "我面無表情 看孤獨的風景", translation: "Expressionless, I gaze upon the lonely scenery"),
            LyricLine(timeMs: 8000, text: "失去你 愛恨開始分明", translation: "Losing you, love and hate begin to become distinct"),
            LyricLine(timeMs: 12000, text: "失去你 還有什麼事好關心", translation: "Without you, what else is worth caring about"),
            LyricLine(timeMs: 16000, text: "為你彈奏蕭邦的夜曲 紀念我死去的愛情", translation: "Playing Chopin's nocturne for you, memorializing my departed love"),
            LyricLine(timeMs: 22000, text: "而我為你隱姓埋名 在月光下彈琴", translation: "And I conceal my name for you, playing the piano under the moonlight"),
            LyricLine(timeMs: 28000, text: "心碎的聲音 如此動聽", translation: "The sound of heartbreak is so pleasing to the ear")
        ],
        offsetMs: 0,
        source: "Demo"
    )
}
