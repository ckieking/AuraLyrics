import SwiftUI

/// 本地歌詞庫與快取管理視圖
struct LibraryView: View {
    @State private var cachedLyrics: [SyncedLyrics] = []
    @State private var showFileImporter = false
    @State private var showDeleteAlert = false
    @State private var selectedForDelete: SyncedLyrics?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("匯入外部 .lrc 檔案", systemImage: "doc.badge.plus")
                            .font(.body)
                    }
                }

                Section(header: Text("已快取歌詞 (\(cachedLyrics.count))")) {
                    if cachedLyrics.isEmpty {
                        VStack(spacing: 8) {
                            Text("尚無本地快取歌詞")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("播放音樂或線上搜尋後，歌詞將自動離線儲存於此")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .padding(.vertical, 16)
                    } else {
                        ForEach(cachedLyrics, id: \.trackTitle) { lyrics in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(lyrics.trackTitle)
                                        .font(.headline)
                                    Spacer()
                                    Text(lyrics.source)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill))
                                        .cornerRadius(4)
                                }

                                Text(lyrics.artistName)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                Text("\(lyrics.lines.count) 行歌詞 · 偏移 \(lyrics.offsetMs)ms")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 點選可將歌詞手動套用至當前歌曲
                                AppleMusicMonitor.shared.applyCustomLyrics(lyrics)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    LyricsProviderService.shared.deleteCachedLyrics(
                                        title: lyrics.trackTitle,
                                        artist: lyrics.artistName
                                    )
                                    reloadCache()
                                } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("歌詞庫")
            .onAppear {
                reloadCache()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.text, .data],
                allowsMultipleSelection: false
            ) { result in
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
    }

    private func reloadCache() {
        cachedLyrics = LyricsProviderService.shared.listAllCachedLyrics()
    }
}
