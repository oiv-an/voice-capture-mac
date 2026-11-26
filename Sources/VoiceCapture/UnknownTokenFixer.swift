import AppKit
import Foundation

/// Parakeet v3 / Fluid Speech Pro vocabulary has neither «ё»/«Ё» nor quote characters:
/// all of them come out as the same `<unk>` token. Each occurrence is resolved separately:
/// - inside a word → ё;
/// - at a word edge → ё or a quote mark, decided by the Russian spell checker
///   («вс<unk>» → «всё», «<unk>И<unk>» → «И», «<unk>умный дом<unk>» → «умный дом»);
/// - standalone → quote mark, alternating « / ».
enum UnknownTokenFixer {
    static let token = "<unk>"
    private static let marker: Character = "\u{FFFC}"

    static func fix(_ text: String) -> String {
        guard text.contains(token) else { return text }
        let source = Array(text.replacingOccurrences(of: token, with: String(marker)))
        var out = ""
        var quoteOpen = false
        var i = 0
        while i < source.count {
            if source[i].isWhitespace {
                out.append(source[i])
                i += 1
                continue
            }
            var end = i
            while end < source.count && !source[end].isWhitespace { end += 1 }
            out += resolve(
                Array(source[i..<end]), sentenceStart: isSentenceStart(out),
                quoteOpen: &quoteOpen)
            i = end
        }
        // Standalone quote tokens arrive space-separated: « привет » → «привет».
        return
            out
            .replacingOccurrences(of: #"«\s+"#, with: "«", options: .regularExpression)
            .replacingOccurrences(of: #"\s+»"#, with: "»", options: .regularExpression)
    }

    private static func resolve(
        _ chunk: [Character], sentenceStart: Bool, quoteOpen: inout Bool
    ) -> String {
        guard chunk.contains(marker) else { return String(chunk) }

        func quote() -> Character {
            defer { quoteOpen.toggle() }
            return quoteOpen ? "»" : "«"
        }

        guard let first = chunk.firstIndex(where: { $0.isLetter }),
            let last = chunk.lastIndex(where: { $0.isLetter })
        else {
            return String(chunk.map { $0 == marker ? quote() : $0 })
        }

        // Markers between the first and last letter are always ё.
        var core = ""
        for k in first...last {
            if chunk[k] == marker {
                let prevUpper = k > first && chunk[k - 1].isUppercase
                let nextUpper = k < last && chunk[k + 1].isUppercase
                core.append(prevUpper && nextUpper ? "Ё" : "ё")
            } else {
                core.append(chunk[k])
            }
        }

        let cyrillic = core.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) }
        let latin = core.contains { $0.isASCII && $0.isLetter }

        // Leading edge: ё only before a lowercase Cyrillic letter, and only when it makes sense.
        var leadLetter = false
        if first > 0, chunk[first - 1] == marker, cyrillic, !latin,
            let head = core.first, head.isLowercase
        {
            let plain = isValidRussian(core)
            let withYo = isValidRussian("ё" + core)
            leadLetter = withYo || !plain
        }
        let leadIsQuote =
            first > 0 && chunk[0..<first].contains(marker) && !(leadLetter && first == 1)
        if leadLetter {
            core.insert(sentenceStart ? "Ё" : "ё", at: core.startIndex)
        }

        // Trailing edge.
        var trailLetter = false
        if last < chunk.count - 1, chunk[last + 1] == marker, cyrillic, !latin {
            let plain = isValidRussian(core)
            let yoLetter: Character =
                core.count > 1 && core.allSatisfy({ !$0.isLetter || $0.isUppercase }) ? "Ё" : "ё"
            let withYo = isValidRussian(core + String(yoLetter))
            if !plain && withYo {
                trailLetter = true
            } else if plain && withYo {
                // Both spellings exist: inside a quotation the closing quote is more likely,
                // unless two tokens follow the word («вс<unk><unk>» → «всё»).
                let doubled = last + 2 < chunk.count && chunk[last + 2] == marker
                trailLetter = doubled || !(quoteOpen || leadIsQuote)
            } else if !plain && !withYo {
                trailLetter = !(quoteOpen || leadIsQuote)
            }
            if trailLetter { core.append(yoLetter) }
        }

        var out = ""
        for k in 0..<first {
            if chunk[k] == marker {
                if !(leadLetter && k == first - 1) { out.append(quote()) }
            } else {
                out.append(chunk[k])
            }
        }
        out += core
        if last + 1 < chunk.count {
            for k in (last + 1)..<chunk.count {
                if chunk[k] == marker {
                    if !(trailLetter && k == last + 1) { out.append(quote()) }
                } else {
                    out.append(chunk[k])
                }
            }
        }
        return out
    }

    private static func isSentenceStart(_ text: String) -> Bool {
        guard let prev = text.last(where: { !$0.isWhitespace && $0 != "«" }) else { return true }
        return ".!?…".contains(prev)
    }

    private static func isValidRussian(_ word: String) -> Bool {
        let check = {
            NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: "ru", wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
        if Thread.isMainThread { return check() }
        return DispatchQueue.main.sync(execute: check)
    }
}
