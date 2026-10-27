import SwiftUI

/// 歌詞來源與逐字時間軸搜尋順位設定視圖（支援三語系獨立順位設定，採用 Apple HIG 原生 onMove 與 EditButton 架構）
struct LyricsSourcePriorityView: View {
    @ObservedObject var lyricsProvider = LyricsProviderService.shared

    @State private var selectedProfile: LyricsLanguageProfile = .japanese
    @State private var items: [LyricsSearchPriorityItem] = []
    @State private var showResetAlert = false

    var body: some View {
        List {
            // MARK: - 語系分類選擇器
            Section {
                Picker("語系分類", selection: $selectedProfile) {
                    ForEach(LyricsLanguageProfile.allCases) { profile in
                        Text(profile.localizedTitle).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("搜尋語系")
            } footer: {
                switch selectedProfile {
                case .japanese:
                    Text("自動辨識含日文假名、日系專屬標記、J-Pop/Anime 類型或日本常見歌手之曲目，預設優先採用日文庫最完整之 PetitLyrics 逐字時間軸。")
                case .asian:
                    Text("自動辨識含中文、韓文諺文或華語/韓語類型之曲目，預設優先採用網易雲音樂逐字時間軸與雙語翻譯。")
                case .western:
                    Text("其餘歐美流行或未分類曲目，預設優先採用 Musixmatch 與 LRCLIB。")
                }
            }

            // MARK: - 該語系搜尋順位列表
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
                                    lyricsProvider.savePriorityItems(items, for: selectedProfile)
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
                Text(String(format: String(localized: "%@ 順位清單"), selectedProfile.localizedTitle))
            } footer: {
                Text("播放此語系曲目時，系統將由上至下依序查詢已啟用的歌詞來源。點選右上角「編輯」即可拖曳排序；點選開關可停用特定來源。")
            }

            // MARK: - 重設順位
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
            items = lyricsProvider.priorityItems(for: selectedProfile)
        }
        .onChange(of: selectedProfile) { _, newProfile in
            items = lyricsProvider.priorityItems(for: newProfile)
        }
        .alert("確定重設搜尋順位？", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("僅重設目前語系", role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lyricsProvider.resetPriorityItems(for: selectedProfile)
                items = lyricsProvider.priorityItems(for: selectedProfile)
            }
            Button("重設全部語系", role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lyricsProvider.resetAllPriorityItems()
                items = lyricsProvider.priorityItems(for: selectedProfile)
            }
        } message: {
            Text("此操作將恢復各歌詞庫與逐字/逐行時間軸的原始推薦順序。")
        }
    }

    private func moveItem(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lyricsProvider.savePriorityItems(items, for: selectedProfile)
    }
}
