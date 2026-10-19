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

    // MARK: - 網易雲 YRC 原生逐字歌詞解析
    /// 解析網易雲 YRC 逐字歌詞（格式如：[16210,3460](16210,280,0)字(16490,310,0)詞）
    public func parseYRC(yrcContent: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let rawLines = yrcContent.components(separatedBy: .newlines)

        // 匹配行首 [lineStartMs,lineDurationMs]
        let lineRegex = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#, options: [])
        // 匹配音節 (wordStartMs,wordDurationMs,0)文字
        let sylRegex = try? NSRegularExpression(pattern: #"\((\d+),(\d+),(\d+)\)([^\(\[]*)"#, options: [])

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // 略過純 JSON 元資料行（若有的話）
            if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
                continue
            }

            guard let lineRegex = lineRegex else { continue }
            let nsLine = trimmed as NSString
            let lineMatches = lineRegex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count))
            guard let lineMatch = lineMatches.first, lineMatch.numberOfRanges >= 3 else {
                continue
            }

            let startMsStr = nsLine.substring(with: lineMatch.range(at: 1))
            let lineStartMs = Int(startMsStr) ?? 0

            // 取出行標籤後方字串
            let tagEndIndex = lineMatch.range.location + lineMatch.range.length
            let contentString = nsLine.substring(from: tagEndIndex)

            // 解析音節
            var syllables: [LyricSyllable] = []
            var fullText = ""

            if let sylRegex = sylRegex {
                let sylMatches = sylRegex.matches(in: contentString, options: [], range: NSRange(location: 0, length: contentString.utf16.count))
                let nsContent = contentString as NSString

                for sylMatch in sylMatches {
                    guard sylMatch.numberOfRanges >= 5 else { continue }
                    let wordStartStr = nsContent.substring(with: sylMatch.range(at: 1))
                    let wordDurStr = nsContent.substring(with: sylMatch.range(at: 2))
                    let wordText = nsContent.substring(with: sylMatch.range(at: 4))

                    let wordStartMs = Int(wordStartStr) ?? lineStartMs
                    let wordDurationMs = max(10, Int(wordDurStr) ?? 100)

                    fullText += wordText
                    syllables.append(LyricSyllable(
                        text: wordText,
                        timeMs: wordStartMs,
                        durationMs: wordDurationMs
                    ))
                }
            }

            // 若該行沒有音節括號，則為純文字行
            if syllables.isEmpty {
                let plainText = contentString.trimmingCharacters(in: .whitespaces)
                if !plainText.isEmpty {
                    lines.append(LyricLine(
                        timeMs: lineStartMs,
                        text: plainText,
                        syllables: nil
                    ))
                }
            } else {
                lines.append(LyricLine(
                    timeMs: lineStartMs,
                    text: fullText,
                    syllables: syllables
                ))
            }
        }

        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    // MARK: - 酷狗/舊版卡拉OK KRC 逐字歌詞解析
    /// 解析 KRC 格式逐字歌詞（格式如：[16210,3460]<0,280>字 或 (0,280)字）
    public func parseKRC(krcContent: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let rawLines = krcContent.components(separatedBy: .newlines)

        let lineRegex = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#, options: [])
        let sylRegex = try? NSRegularExpression(pattern: #"[<\(](\d+),(\d+)[>\)]([^<\[\(\)]*)"#, options: [])

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let lineRegex = lineRegex else { continue }
            let nsLine = trimmed as NSString
            let lineMatches = lineRegex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count))
            guard let lineMatch = lineMatches.first, lineMatch.numberOfRanges >= 3 else {
                continue
            }

            let startMsStr = nsLine.substring(with: lineMatch.range(at: 1))
            let lineStartMs = Int(startMsStr) ?? 0

            let tagEndIndex = lineMatch.range.location + lineMatch.range.length
            let contentString = nsLine.substring(from: tagEndIndex)

            var syllables: [LyricSyllable] = []
            var fullText = ""

            if let sylRegex = sylRegex {
                let sylMatches = sylRegex.matches(in: contentString, options: [], range: NSRange(location: 0, length: contentString.utf16.count))
                let nsContent = contentString as NSString

                for sylMatch in sylMatches {
                    guard sylMatch.numberOfRanges >= 4 else { continue }
                    let num1Str = nsContent.substring(with: sylMatch.range(at: 1))
                    let num2Str = nsContent.substring(with: sylMatch.range(at: 2))
                    let wordText = nsContent.substring(with: sylMatch.range(at: 3))

                    let num1 = Int(num1Str) ?? 0
                    let duration = max(10, Int(num2Str) ?? 100)

                    // 若 num1 小於 lineStartMs，視為行內相對偏移量；否則為絕對時間戳
                    let wordStartMs = (num1 < lineStartMs) ? (lineStartMs + num1) : num1

                    fullText += wordText
                    syllables.append(LyricSyllable(
                        text: wordText,
                        timeMs: wordStartMs,
                        durationMs: duration
                    ))
                }
            }

            if syllables.isEmpty {
                let plainText = contentString.trimmingCharacters(in: .whitespaces)
                if !plainText.isEmpty {
                    lines.append(LyricLine(
                        timeMs: lineStartMs,
                        text: plainText,
                        syllables: nil
                    ))
                }
            } else {
                lines.append(LyricLine(
                    timeMs: lineStartMs,
                    text: fullText,
                    syllables: syllables
                ))
            }
        }

        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    // MARK: - 製作人員與創作團隊名單識別過濾 (Apple Music Credits)
    private static let creditRoleKeywords: [String] = [
        "作词", "作詞", "作曲", "编曲", "編曲",
        "制作人", "製作人", "制作", "製作", "监制", "監製",
        "吉他", "贝斯", "貝斯", "鼓", "键盘", "鍵盤", "钢琴", "鋼琴", "弦乐", "弦樂", "和声", "和聲",
        "录音", "錄音", "混音", "母带", "母帶", "音频", "音訊", "配唱",
        "企划", "企劃", "统筹", "統籌", "出品", "发行", "發行", "文案", "版权", "版權",
        "歌词制作", "歌詞製作", "歌词编辑", "歌詞編輯", "打轴", "校对", "校對", "动态歌词", "動態歌詞",
        "OP", "SP", "ISRC", "UPC",
        "Written by", "Produced by", "Mixed by", "Mastered by", "Recorded by",
        "Arranged by", "Composed by", "Lyrics by", "Vocals by",
        "Lyricist", "Composer", "Arranger", "Producer"
    ]

    /// 判斷某行文本是否屬於製作名單（僅限歌曲開頭或結尾）
    public func isCreditLine(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 1. 直接以英文創作職能開頭 (如 "Written by...", "Produced by...")
        let englishPrefixes = ["written by", "produced by", "mixed by", "mastered by", "recorded by", "arranged by", "composed by", "lyrics by", "vocals by", "op:", "sp:"]
        let lower = trimmed.lowercased()
        for prefix in englishPrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        // 2. 包含冒號分隔符號（: 或 ：）
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ":："))
        if parts.count >= 2 {
            let role = parts[0].trimmingCharacters(in: .whitespaces)
            let lowerRole = role.lowercased()
            for kw in Self.creditRoleKeywords {
                if lowerRole == kw.lowercased() || role.hasPrefix(kw) || role.hasSuffix(kw) {
                    return true
                }
            }
        }

        // 3. 包含常見打軸或版權特徵
        if trimmed.contains("歌词制作") || trimmed.contains("歌詞製作") || trimmed.contains("打轴") || trimmed.contains("QQ:") || trimmed.contains("QQ群") {
            return true
        }

        return false
    }

    /// 將原始名單轉換為 Apple Music 風格（例如 "Written by 周杰倫"）
    public func formatCredit(raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ":："))
        guard parts.count >= 2 else {
            return trimmed
        }
        let role = parts[0].trimmingCharacters(in: .whitespaces)
        let name = parts.dropFirst().joined(separator: "：").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return trimmed }

        switch role {
        case "作词", "作詞", "詞", "词", "Lyrics", "Lyricist", "Lyrics by":
            return "Written by \(name)"
        case "作曲", "曲", "Music", "Composer", "Composed by":
            return "Composed by \(name)"
        case "编曲", "編曲", "Arrangement", "Arranger", "Arranged by":
            return "Arranged by \(name)"
        case "制作人", "製作人", "音乐制作人", "音樂製作人", "Producer", "Produced by":
            return "Produced by \(name)"
        case "混音", "混音师", "混音師", "Mixing", "Mixed by":
            return "Mixed by \(name)"
        case "母带", "母带工程师", "母帶工程師", "Mastering", "Mastered by":
            return "Mastered by \(name)"
        case "录音", "錄音", "录音师", "錄音師", "Recording", "Recorded by":
            return "Recorded by \(name)"
        default:
            return "\(role)：\(name)"
        }
    }

    /// 從解析好的歌詞行中提取出製作名單，並回傳純淨歌詞與 Credits 清單
    public func extractCredits(from lines: [LyricLine]) -> (cleanLines: [LyricLine], credits: [String]) {
        guard !lines.isEmpty else { return ([], []) }

        var credits: [String] = []
        var cleanLines: [LyricLine] = []

        for (index, line) in lines.enumerated() {
            let isCredit = isCreditLine(text: line.text)
            // 只有在開頭前 15 行且時間在前 45 秒內，或者在歌曲最後 5 行內才視為 Credit
            let isHeadCandidate = (index < 15 && line.timeMs < 45_000)
            let isTailCandidate = (index >= max(0, lines.count - 5))

            if isCredit && (isHeadCandidate || isTailCandidate) {
                // 忽略非官方打軸或QQ群等純垃圾訊息，有價值的製作資訊才加入 credits
                if !line.text.contains("打轴") && !line.text.contains("QQ:") && !line.text.contains("QQ群") {
                    let formatted = formatCredit(raw: line.text)
                    if !credits.contains(formatted) {
                        credits.append(formatted)
                    }
                }
            } else {
                cleanLines.append(line)
            }
        }

        return (cleanLines, credits)
    }

    /// 解析 LRC 並直接分離 Credits
    public func parseWithCredits(lrcContent: String) -> (lines: [LyricLine], credits: [String]) {
        let raw = parse(lrcContent: lrcContent)
        return extractCredits(from: raw)
    }
}

