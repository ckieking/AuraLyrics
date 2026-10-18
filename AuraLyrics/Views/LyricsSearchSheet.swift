import SwiftUI

/// 手動線上搜尋歌詞彈跳視窗（Apple HIG 抽屜卡片、細緻標籤與即時預覽）
struct LyricsSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currentTrack: TrackInfo
    let onSelect: (SyncedLyrics) -> Void

    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var searchResults: [SyncedLyrics] = []
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    loadingView
                } else if let error = errorMessage {
                    errorStateView(error)
                } else if searchResults.isEmpty {
                    emptyPromptView
                } else {
                    resultsListView
                }
            }
            .navigationTitle("搜尋歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜尋歌曲、歌手或關鍵字"
            )
            .onSubmit(of: .search) {
                performSearch()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .font(.body)
                }

                if !searchText.isEmpty && !isSearching {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("搜尋") {
                            performSearch()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                if searchText.isEmpty && !currentTrack.title.isEmpty && currentTrack.title != "尚未播放音樂" {
                    searchText = "\(currentTrack.title) \(currentTrack.artist)".trimmingCharacters(in: .whitespaces)
                    performSearch()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 搜尋結果列表
    private var resultsListView: some View {
        List {
            Section {
                ForEach(searchResults, id: \.trackTitle) { lyrics in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onSelect(lyrics)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(lyrics.trackTitle)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    Text(lyrics.artistName.isEmpty ? "未知歌手" : lyrics.artistName)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                // 來源徽章
                                Text(lyrics.source)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color(.tertiarySystemFill))
                                    .cornerRadius(5)
                            }

                            // 標籤群組 (雙語 + 行數)
                            HStack(spacing: 6) {
                                if lyrics.lines.contains(where: { $0.translation != nil && !($0.translation?.isEmpty ?? true) }) {
                                    Text("雙語歌詞")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.pink)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.pink.opacity(0.12))
                                        .cornerRadius(4)
                                }

                                Text("\(lyrics.lines.count) 行時間軸")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            // 前兩行預覽
                            if let firstLine = lyrics.lines.first?.text, !firstLine.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("「\(firstLine)」")
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.85))
                                        .lineLimit(1)

                                    if lyrics.lines.count > 1, let secondLine = lyrics.lines.dropFirst().first?.text, !secondLine.isEmpty {
                                        Text("「\(secondLine)」")
                                            .font(.caption)
                                            .foregroundColor(.secondary.opacity(0.65))
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("套用 \(lyrics.trackTitle)，\(lyrics.artistName)，來源 \(lyrics.source)")
                }
            } header: {
                Text("線上結果 (\(searchResults.count))")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 載入中狀態
    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.pink)

            Text("正在跨庫檢索時間軸歌詞...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 初始提示狀態
    private var emptyPromptView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.pink.opacity(0.1))
                    .frame(width: 72, height: 72)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(.pink)
            }

            Text("線上歌詞檢索")
                .font(.headline)
                .foregroundColor(.primary)

            Text("輸入歌名、歌手或關鍵字\n即時檢索 LRCLIB 與網易雲時間軸歌詞")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 錯誤或無結果狀態
    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("未找到相符歌詞")
                .font(.headline)
                .foregroundColor(.primary)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("重新搜尋") {
                performSearch()
            }
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.pink)
            .frame(minHeight: 44)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 搜尋邏輯
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        searchResults = []

        Task {
            var results: [SyncedLyrics] = []

            // 同步嘗試網易雲公開 API
            if let netEaseResult = await LyricsProviderService.shared.fetchFromNetEase(title: query, artist: "") {
                results.append(netEaseResult)
            }

            // 同步嘗試 LRCLIB
            let dummyTrack = TrackInfo(title: query, artist: "", album: "", duration: 0)
            if let lrcResult = await LyricsProviderService.shared.fetchLyrics(track: dummyTrack) {
                if !results.contains(where: { $0.source == lrcResult.source && $0.trackTitle == lrcResult.trackTitle }) {
                    results.append(lrcResult)
                }
            }

            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
                if results.isEmpty {
                    self.errorMessage = "未找到與「\(query)」相符的時間軸歌詞，請嘗試簡化關鍵字或去除特殊符號。"
                }
            }
        }
    }
}
