import Foundation

/// LRC 歌詞解析與雙語合併引擎
public final class LRCParser {
    public static let shared = LRCParser()

    private init() {}

    /// 解析 LRC 字串為時間排序的 LyricLine 陣列
    public func parse(lrcContent: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let rawLines = lrcContent.components(separatedBy: .newlines)

        // 正則表示式匹配 [01:23.45] 或 [01:23.456]
        let regex = try? NSRegularExpression(pattern: "\\[(\\d{2,}):(\\d{2})(?:\\.(\\d{2,3}))?\\]", options: [])

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // 略過純元資料標籤（如 [ti:Song], [ar:Artist], [offset:0]）
            if trimmed.hasPrefix("[ti:") || trimmed.hasPrefix("[ar:") || trimmed.hasPrefix("[al:") || trimmed.hasPrefix("[by:") {
                continue
            }

            guard let regex = regex else { continue }
            let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count))
            guard !matches.isEmpty else { continue }

            // 取得最後一個時間標籤後面的文字內容
            let lastMatch = matches[matches.count - 1]
            let textStartIndex = lastMatch.range.location + lastMatch.range.length
            let nsString = trimmed as NSString
            let lyricText = nsString.substring(from: textStartIndex).trimmingCharacters(in: .whitespaces)

            // 支援一對多時間標籤（如 [00:10.00][01:20.00] 相同歌詞）
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }

                let minString = nsString.substring(with: match.range(at: 1))
                let secString = nsString.substring(with: match.range(at: 2))
                var msValue = 0

                if match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound {
                    let msString = nsString.substring(with: match.range(at: 3))
                    if msString.count == 2 {
                        msValue = (Int(msString) ?? 0) * 10
                    } else if msString.count >= 3 {
                        msValue = Int(msString.prefix(3)) ?? 0
                    }
                }

                let minutes = Int(minString) ?? 0
                let seconds = Int(secString) ?? 0
                let totalMs = (minutes * 60 + seconds) * 1000 + msValue

                lines.append(LyricLine(timeMs: totalMs, text: lyricText))
            }
        }

        // 依時間排序
        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    /// 將原文歌詞與翻譯歌詞依時間戳比對合併
    public func mergeTranslations(original: [LyricLine], translation: [LyricLine], thresholdMs: Int = 800) -> [LyricLine] {
        guard !translation.isEmpty else { return original }

        var result: [LyricLine] = []

        for orig in original {
            // 在容許時間差內尋找最接近的翻譯行
            let closestTrans = translation.min(by: { abs($0.timeMs - orig.timeMs) < abs($1.timeMs - orig.timeMs) })
            var translatedText: String? = nil

            if let closest = closestTrans, abs(closest.timeMs - orig.timeMs) <= thresholdMs {
                let trimmed = closest.text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    translatedText = trimmed
                }
            }

            result.append(LyricLine(
                id: orig.id,
                timeMs: orig.timeMs,
                text: orig.text,
                translation: translatedText
            ))
        }

        return result
    }
}
