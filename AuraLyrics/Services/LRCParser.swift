import Foundation

/// LRC 歌詞解析與雙語合併引擎（支援標準 LRC 與 Enhanced LRC 逐字時間軸）
public final class LRCParser {
    public static let shared = LRCParser()

    private init() {}

    /// 解析 LRC 字串為時間排序的 LyricLine 陣列（支援逐字音節解析）
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

            // 取得最後一個行時間標籤後面的文字內容
            let lastMatch = matches[matches.count - 1]
            let textStartIndex = lastMatch.range.location + lastMatch.range.length
            let nsString = trimmed as NSString
            let rawLyricText = nsString.substring(from: textStartIndex).trimmingCharacters(in: .whitespaces)

            // 解析是否含有 Enhanced 逐字音節標籤
            let (cleanText, syllables) = parseEnhancedSyllables(from: rawLyricText)

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

                lines.append(LyricLine(
                    timeMs: totalMs,
                    text: cleanText,
                    syllables: syllables
                ))
            }
        }

        // 依時間排序
        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    /// 解析單行文字中是否夾帶 Enhanced LRC 音節標籤（如 <00:12.34>字<00:12.80>詞）
    private func parseEnhancedSyllables(from text: String) -> (cleanText: String, syllables: [LyricSyllable]?) {
        guard text.contains("<") && text.contains(">") else {
            return (text, nil)
        }

        let syllablePattern = "<(\\d{2,}):(\\d{2})(?:\\.(\\d{2,3}))?>([^<]*)"
        guard let regex = try? NSRegularExpression(pattern: syllablePattern, options: []) else {
            return (text, nil)
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        guard !matches.isEmpty else { return (text, nil) }

        var clean = ""
        var syllables: [LyricSyllable] = []

        for match in matches {
            guard match.numberOfRanges >= 5 else { continue }
            let minStr = nsString.substring(with: match.range(at: 1))
            let secStr = nsString.substring(with: match.range(at: 2))
            var msVal = 0

            if match.range(at: 3).location != NSNotFound {
                let msStr = nsString.substring(with: match.range(at: 3))
                if msStr.count == 2 {
                    msVal = (Int(msStr) ?? 0) * 10
                } else if msStr.count >= 3 {
                    msVal = Int(msStr.prefix(3)) ?? 0
                }
            }

            let sylText = nsString.substring(with: match.range(at: 4))
            let minutes = Int(minStr) ?? 0
            let seconds = Int(secStr) ?? 0
            let timeMs = (minutes * 60 + seconds) * 1000 + msVal

            clean += sylText
            syllables.append(LyricSyllable(text: sylText, timeMs: timeMs))
        }

        // 計算各音節持續時間
        for i in 0..<syllables.count {
            if i + 1 < syllables.count {
                syllables[i].durationMs = max(50, syllables[i+1].timeMs - syllables[i].timeMs)
            } else {
                syllables[i].durationMs = 500
            }
        }

        return (clean.isEmpty ? text : clean, syllables.isEmpty ? nil : syllables)
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
                translation: translatedText,
                syllables: orig.syllables
            ))
        }

        return result
    }
}
