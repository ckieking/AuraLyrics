import SwiftUI

/// 歌詞來源與逐字時間軸搜尋順位設定視圖（採用 Apple HIG 原生 onMove 與 EditButton 架構）
struct LyricsSourcePriorityView: View {
    @ObservedObject var lyricsProvider = LyricsProviderService.shared

    @State private var items: [LyricsSearchPriorityItem] = []
    @State private var showResetAlert = false

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
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

                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { newValue in
                                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    items[idx].isEnabled = newValue
                                    lyricsProvider.savePriorityItems(items)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .pink))
                    }
                    .padding(.vertical, 4)
                }
                .onMove(perform: moveItem)
            } header: {
                Text("搜尋順位清單")
            } footer: {
                Text("播放曲目時，系統將由上至下依序查詢已啟用的歌詞來源。點選右上角「編輯」即可拖曳排序；點選開關可停用特定來源。")
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
            }
        }
        .navigationTitle("自動搜尋歌詞順位")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
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

    private func moveItem(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lyricsProvider.savePriorityItems(items)
    }
}
