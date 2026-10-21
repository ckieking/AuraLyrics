import SwiftUI

/// 歌詞來源與逐字時間軸搜尋順位設定視圖（支援拖曳重排、個別啟用/停用與重設預設值）
struct LyricsSourcePriorityView: View {
    @ObservedObject var lyricsProvider = LyricsProviderService.shared

    @State private var items: [LyricsSearchPriorityItem] = []
    @State private var showResetAlert = false

    var body: some View {
        List {
            Section {
                ForEach($items) { $item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundColor(item.isEnabled ? .pink : .secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(item.isEnabled ? .primary : .secondary)

                                if item.isWordSync {
                                    Text("逐字")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.pink)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.pink.opacity(0.12))
                                        .clipShape(Capsule())
                                } else {
                                    Text("逐行")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(Capsule())
                                }
                            }

                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $item.isEnabled)
                            .labelsHidden()
                            .onChange(of: item.isEnabled) { _ in
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                lyricsProvider.savePriorityItems(items)
                            }
                    }
                    .padding(.vertical, 4)
                }
                .onMove { indices, newOffset in
                    items.move(fromOffsets: indices, toOffset: newOffset)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    lyricsProvider.savePriorityItems(items)
                }
            } header: {
                Text("搜尋順位清單")
            } footer: {
                Text("播放曲目時，系統將由上至下依序查詢已啟用的歌詞來源。點選右側開關可停用特定來源；長按右側把手上下拖曳可變更搜尋優先序。")
            }

            Section {
                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重設為預設順位")
                    }
                    .frame(minHeight: 36)
                }
            } footer: {
                Text("預設順位：Musixmatch 逐字 → 網易雲 逐字 → LRCLIB 逐字 → Musixmatch 逐行 → 網易雲 逐行 → LRCLIB 逐行。")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("自動搜尋歌詞順位")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            items = lyricsProvider.priorityItems
        }
        .alert("確定重設搜尋順位？", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("重設", role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lyricsProvider.resetPriorityItems()
                items = lyricsProvider.priorityItems
            }
        } message: {
            Text("此操作將恢復各歌詞庫與逐字/逐行時間軸的原始推薦順序。")
        }
    }
}
