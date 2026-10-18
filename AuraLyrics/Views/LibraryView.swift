import SwiftUI

/// 本地歌詞庫與快取管理視圖（Apple HIG 搜尋、預覽彈窗與狀態感知）
struct LibraryView: View {
    @ObservedObject private var musicMonitor = AppleMusicMonitor.shared
    @State private var cachedLyrics: [SyncedLyrics] = []
    @State private var searchQuery: String = ""
    @State private var showFileImporter = false
    @State private var previewTarget: SyncedLyrics? = nil
    @State private var appliedToastTrack: String? = nil

    private var filteredLyrics: [SyncedLyrics] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return cachedLyrics }
        return cachedLyrics.filter {
            $0.trackTitle.localizedCaseInsensitiveContains(query) ||
            $0.artistName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if cachedLyrics.isEmpty {
                    emptyLibraryView
                } else if filteredLyrics.isEmpty {
                    emptySearchView
                } else {
                    lyricsListView
                }
            }
            .navigationTitle("歌詞庫")
            .searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "搜尋已快取歌曲或歌手"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("匯入歌詞", systemImage: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("匯入外部 .lrc 檔案")
                }
            }
            .onAppear {
                reloadCache()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.text, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .sheet(item: $previewTarget) { lyrics in
                LyricsPreviewSheet(lyrics: lyrics) {
                    applyLyrics(lyrics)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .bottom) {
                if let toast = appliedToastTrack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.pink)
                        Text("已套用「\(toast)」歌詞")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlassCapsule()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appliedToastTrack)
        }
    }

    // MARK: - 歌詞列表
    private var lyricsListView: some View {
        List {
            Section {
                ForEach(filteredLyrics, id: \.trackTitle) { lyrics in
                    let isPlaying = isCurrentPlaying(lyrics)

                    HStack(spacing: 12) {
                        // 點選套用主要熱區
                        Button {
                            applyLyrics(lyrics)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(lyrics.trackTitle)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    if isPlaying {
                                        HStack(spacing: 3) {
                                            Circle()
                                                .fill(Color.pink)
                                                .frame(width: 6, height: 6)
                                            Text("播放中")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundColor(.pink)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.pink.opacity(0.12))
                                        .clipShape(Capsule())
                                    }

                                    Spacer()
                                }

                                Text(lyrics.artistName.isEmpty ? "未知歌手" : lyrics.artistName)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(lyrics.source)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill))
                                        .cornerRadius(4)

                                    if lyrics.lines.contains(where: { $0.translation != nil && !($0.translation?.isEmpty ?? true) }) {
                                        Text("雙語")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.pink)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.pink.opacity(0.12))
                                            .cornerRadius(4)
                                    }

                                    Text("\(lyrics.lines.count) 行歌詞")
                                        .font(.caption2)
                                        .foregroundColor(.secondary.opacity(0.8))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(lyrics.trackTitle)，\(lyrics.artistName)，來源 \(lyrics.source)\(isPlaying ? "，正在套用中" : "")")

                        // 獨立預覽按鈕 (>= 44x44pt 拇指熱區)
                        Button {
                            previewTarget = lyrics
                        } label: {
                            Image(systemName: "text.quote")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.pink)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("預覽「\(lyrics.trackTitle)」歌詞時間軸")
                    }
                    .padding(.vertical, 3)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteLyrics(lyrics)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("已快取曲目 (\(filteredLyrics.count))")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 空資料夾狀態
    private var emptyLibraryView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.pink.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "music.note.list")
                    .font(.system(size: 36))
                    .foregroundColor(.pink)
            }

            VStack(spacing: 6) {
                Text("尚無本地快取歌詞")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("在 Apple Music 聆聽音樂或於首頁搜尋後\n時間軸歌詞將自動離線儲存於此")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                showFileImporter = true
            } label: {
                Label("匯入外部 .lrc 檔案", systemImage: "doc.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.pink)
                    .clipShape(Capsule())
            }
            .frame(minHeight: 44)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 搜尋無結果狀態
    private var emptySearchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("找不到相符的歌詞")
                .font(.headline)
                .foregroundColor(.primary)

            Text("找不到與「\(searchQuery)」相關的本地快取")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("清除搜尋條件") {
                searchQuery = ""
            }
            .font(.subheadline)
            .foregroundColor(.pink)
            .padding(.top, 4)
            .frame(minHeight: 44)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 輔助方法
    private func isCurrentPlaying(_ lyrics: SyncedLyrics) -> Bool {
        guard !musicMonitor.currentTrack.title.isEmpty else { return false }
        return musicMonitor.currentLyrics.trackTitle == lyrics.trackTitle &&
               musicMonitor.currentLyrics.artistName == lyrics.artistName
    }

    private func applyLyrics(_ lyrics: SyncedLyrics) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        musicMonitor.applyCustomLyrics(lyrics)
        appliedToastTrack = lyrics.trackTitle
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if appliedToastTrack == lyrics.trackTitle {
                appliedToastTrack = nil
            }
        }
    }

    private func deleteLyrics(_ lyrics: SyncedLyrics) {
        LyricsProviderService.shared.deleteCachedLyrics(
            title: lyrics.trackTitle,
            artist: lyrics.artistName
        )
        reloadCache()
    }

    private func reloadCache() {
        cachedLyrics = LyricsProviderService.shared.listAllCachedLyrics()
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                let fileName = url.deletingPathExtension().lastPathComponent
                let components = fileName.components(separatedBy: " - ")
                let title = components.first ?? fileName
                let artist = components.count > 1 ? components[1] : "本地匯入"

                _ = LyricsProviderService.shared.importLocalLRCFile(
                    url: url,
                    title: title,
                    artist: artist
                )
                reloadCache()
            }
        }
    }
}

// MARK: - 歌詞預覽彈窗 (Apple Sheet 風格)
private struct LyricsPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lyrics: SyncedLyrics
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lyrics.trackTitle)
                            .font(.title3)
                            .fontWeight(.bold)

                        Text(lyrics.artistName.isEmpty ? "未知歌手" : lyrics.artistName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Label(lyrics.source, systemImage: "server.rack")
                            Text("·")
                            Text("\(lyrics.lines.count) 行歌詞")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("時間軸歌詞全文")) {
                    ForEach(lyrics.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(formatTime(ms: line.timeMs))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.pink)
                                    .frame(width: 50, alignment: .leading)

                                Text(line.text.isEmpty ? "♫" : line.text)
                                    .font(.body)
                                    .foregroundColor(.primary)
                            }

                            if let trans = line.translation, !trans.isEmpty {
                                HStack {
                                    Spacer().frame(width: 50)
                                    Text(trans)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("歌詞預覽")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onApply()
                        dismiss()
                    } label: {
                        Text("套用此歌詞")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func formatTime(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
