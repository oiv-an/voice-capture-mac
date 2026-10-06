import Foundation

/// Удаляет только явные звуки-паразиты, не пытаясь переписывать смысл фразы.
enum SpeechTextCleaner {
    // Одиночные «а»/A, «м», единицу «мм», обычные слова и части составных слов не трогаем.
    private static let sound =
        #"(?:э+(?:[\p{Pd}]э+)*|э+м+|м{3,}|м(?:[\p{Pd}]м)+|а{2,}|а+(?:[\p{Pd}]а+)+)(?![\p{L}\p{N}_\p{Pd}])"#
    private static let fillers = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_\p{Pd}])"# + sound + #"(?:[ \t,;:]+"# + sound + #")*"#,
        options: [.caseInsensitive])

    static func clean(_ text: String) -> String {
        let matches = fillers.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        // Обратный порядок сохраняет UTF-16 offsets исходных совпадений.
        for match in matches.reversed() {
            var range = match.range
            let suffix = (result as String as NSString).substring(from: NSMaxRange(range))
            if let punctuation = suffix.range(of: #"^[ \t]*[,;:]"#, options: .regularExpression) {
                range.length += (String(suffix[punctuation]) as NSString).length
                let prefix = (result as String as NSString).substring(to: range.location)
                if let comma = prefix.range(of: #",[ \t]*$"#, options: .regularExpression) {
                    let length = (String(prefix[comma]) as NSString).length
                    range.location -= length
                    range.length += length
                }
            }
            result.replaceCharacters(in: range, with: "")
        }

        var cleaned = result as String
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+([,.;:!?…])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"[,;:]+([.!?…])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^[ \t]+"#, with: "", options: .regularExpression)
        // После начального междометия могут остаться запятая, точка или многоточие.
        cleaned = cleaned.replacingOccurrences(
            of: #"^[\s,.;:!?…]+"#, with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        return cleaned
    }
}
