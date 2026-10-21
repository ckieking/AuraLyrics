import SwiftUI

/// 歌詞來源與逐字時間軸搜尋順位設定視圖（支援垂直 Y 軸鎖定拖曳重排、個別啟用/停用與重設預設值）
struct LyricsSourcePriorityView: View {
    @ObservedObject var lyricsProvider = LyricsProviderService.shared

    @State private var items: [LyricsSearchPriorityItem] = []
    @State private var showResetAlert = false
    @State private var draggingItemID: String? = nil
    @State private var dragStartIndex: Int? = nil
    @State private var currentTargetIndex: Int? = nil
    @State private var dragOffsetY: CGFloat = 0

    private let itemHeight: CGFloat = 60

    var body: some View {
        List {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let isDragging = (draggingItemID == item.id)

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

                        // 專屬純 Y 軸拖曳把手（嚴格限制 X 軸移動，並採用虛擬插槽預覽，杜絕重排抖動與二次回彈動畫）
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isDragging ? .pink : .secondary.opacity(0.6))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .global)
                                    .onChanged { gesture in
                                        if draggingItemID == nil {
                                            draggingItemID = item.id
                                            dragStartIndex = index
                                            currentTargetIndex = index
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        }

                                        guard draggingItemID == item.id,
                                              let startIndex = dragStartIndex else { return }

                                        let totalTranslationY = gesture.translation.height
                                        dragOffsetY = totalTranslationY

                                        let stepsFromStart = Int(round(totalTranslationY / itemHeight))
                                        let target = min(max(0, startIndex + stepsFromStart), items.count - 1)

                                        if target != currentTargetIndex {
                                            currentTargetIndex = target
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        }
                                    }
                                    .onEnded { _ in
                                        if let startIndex = dragStartIndex,
                                           let target = currentTargetIndex,
                                           startIndex != target {
                                            var newItems = items
                                            let moved = newItems.remove(at: startIndex)
                                            newItems.insert(moved, at: target)

                                            // 使用無動畫交易立即提交陣列新排列，因視覺位置已完全吻合，杜絕二次回彈動畫
                                            var transaction = Transaction()
                                            transaction.disablesAnimations = true
                                            withTransaction(transaction) {
                                                items = newItems
                                                draggingItemID = nil
                                                dragStartIndex = nil
                                                currentTargetIndex = nil
                                                dragOffsetY = 0
                                            }
                                            lyricsProvider.savePriorityItems(newItems)
                                        } else {
                                            // 原位釋放：以彈簧動畫平滑復位
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                                draggingItemID = nil
                                                dragStartIndex = nil
                                                currentTargetIndex = nil
                                                dragOffsetY = 0
                                            }
                                        }
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    }
                            )
                    }
                    .padding(.vertical, 4)
                    // 核心物理約束：X 軸位移永久鎖定為 0，純 Y 軸平滑過渡
                    .offset(x: 0, y: itemOffsetY(index: index))
                    .zIndex(isDragging ? 100 : 1)
                    .scaleEffect(isDragging ? 1.02 : 1.0)
                    .shadow(color: isDragging ? Color.black.opacity(0.15) : Color.clear, radius: 10, y: 5)
                    .animation(isDragging ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: currentTargetIndex)
                }
            } header: {
                Text("搜尋順位清單")
            } footer: {
                Text("播放曲目時，系統將由上至下依序查詢已啟用的歌詞來源。點選開關可停用特定來源；按住右側把手可垂直拖曳變更搜尋優先序。")
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

    private func itemOffsetY(index: Int) -> CGFloat {
        guard let startIndex = dragStartIndex,
              let targetIndex = currentTargetIndex,
              let draggingID = draggingItemID else {
            return 0
        }

        if items[index].id == draggingID {
            return dragOffsetY
        }

        if targetIndex > startIndex {
            if index > startIndex && index <= targetIndex {
                return -itemHeight
            }
        } else if targetIndex < startIndex {
            if index >= targetIndex && index < startIndex {
                return itemHeight
            }
        }

        return 0
    }
}
