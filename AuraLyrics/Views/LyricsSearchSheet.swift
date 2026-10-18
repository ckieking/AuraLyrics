import SwiftUI

/// 手動線上搜尋歌詞彈跳視窗
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
            List {
                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView("正在檢索歌詞庫...")
                            .padding(.vertical, 24)
                        Spacer()
                    }
                } else if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("搜尋失敗")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 12)
                } else if searchResults.isEmpty {
                    VStack(alignment: .center, spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("請輸入歌曲名稱或歌手搜尋歌詞")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    ForEach(searchResults, id: \.trackTitle) { lyrics in
                        Button {
                            onSelect(lyrics)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(lyrics.trackTitle)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(lyrics.source)
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill))
                                        .cornerRadius(4)
                                }

                                Text(lyrics.artistName)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                if let firstLine = lyrics.lines.first?.text {
                                    Text(firstLine)
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.8))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜尋歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜尋歌曲、歌手")
            .onSubmit(of: .search) {
                performSearch()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
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
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isSearching = true
        errorMessage = nil
        searchResults = []

        Task {
            var results: [SyncedLyrics] = []

            // 同步嘗試網易雲公開 API
            if let netEaseResult = await LyricsProviderService.shared.fetchFromNetEase(title: searchText, artist: "") {
                results.append(netEaseResult)
            }

            // 同步嘗試 LRCLIB
            let dummyTrack = TrackInfo(title: searchText, artist: "", album: "", duration: 0)
            if let lrcResult = await LyricsProviderService.shared.fetchLyrics(track: dummyTrack) {
                if !results.contains(where: { $0.source == lrcResult.source && $0.trackTitle == lrcResult.trackTitle }) {
                    results.append(lrcResult)
                }
            }

            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
                if results.isEmpty {
                    self.errorMessage = "未找到相符的時間軸歌詞，請嘗試不同關鍵字。"
                }
            }
        }
    }
}
