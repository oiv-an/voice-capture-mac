import AppKit
import Foundation

/// Parakeet v3 / Fluid Speech Pro pick the language per token, so short Russian phrases sometimes
/// come out in Polish/Czech-like Latin spelling («Publicuj.», «Uh, пуblikuj.»).
/// Model weights are not touched (no Latin penalty): real English stays English.
/// A Latin word is converted to Cyrillic only when
/// - it is not a valid English word, is not a capitalized name in mid-sentence,
///   and its transliteration is a valid Russian word (system spell checker), or
/// - it is mixed-script garbage («пуblikuj»).
/// A purely Latin phrase that is mostly valid English is left untouched.
enum RussianLatinFixer {
    private struct Part {
        var text: String
        let isWord: Bool
    }

    static func fix(_ text: String) -> String {
        guard text.contains(where: isLatin) else { return text }
        var parts = split(text)
        let wordIdx = parts.indices.filter { parts[$0].isWord }

        func sentenceStart(_ n: Int) -> Bool {
            guard n > 0 else { return true }
            let gap = parts[(wordIdx[n - 1] + 1)..<wordIdx[n]].map(\.text).joined()
            return gap.contains { ".!?…".contains($0) }
        }

        // Whole English phrase («fluid speech pro», «let's go») — keep as is.
        if !text.contains(where: isCyrillic), wordIdx.count >= 2 {
            let english = wordIdx.filter { isValid(parts[$0].text, language: "en") }.count
            if english * 2 >= wordIdx.count { return text }
        }

        for (n, i) in wordIdx.enumerated() {
            let word = parts[i].text
            guard word.contains(where: isLatin) else { continue }
            if word.contains(where: isCyrillic) {
                if let ru = russian(for: word, requireValid: false) { parts[i].text = ru }
                continue
            }
            // Single-word dictation of a Russian word that is also an English one («Privet», «Da»).
            let lone = wordIdx.count == 1 && ambiguous.contains(word.lowercased())
            if !lone && isValid(word, language: "en") { continue }
            if word.first?.isUppercase == true && !sentenceStart(n) { continue }  // name/brand
            if let ru = russian(for: word, requireValid: true) { parts[i].text = ru }
        }

        return parts.map(\.text).joined()
    }
    /// Russian words in Latin spelling that the English spell checker also accepts.
    private static let ambiguous: Set<String> = [
        "da", "net", "nu", "vot", "tak", "kak", "privet", "ladno", "dobro", "eto", "kto",
        "chto", "gde", "tam", "tut", "oni", "ona", "ono", "mama", "papa", "pora", "davai",
        "davay", "ura", "ugu", "aga",
    ]

    // MARK: - Transliteration

    private static let rules: [String: [String]] = [
        "shch": ["щ"], "szcz": ["щ"], "sch": ["щ", "сх"],
        "ch": ["ч", "х"], "cz": ["ч"], "sh": ["ш"], "sz": ["ш"], "zh": ["ж"], "rz": ["ж", "рз"],
        "kh": ["х"], "ts": ["ц", "тс"], "ck": ["к"],
        "ya": ["я"], "ja": ["я"], "yu": ["ю"], "ju": ["ю"], "ye": ["е"], "je": ["е"],
        "yo": ["ё"], "jo": ["ё"], "ia": ["я", "иа"], "iu": ["ю", "иу"], "ie": ["е", "ие"],
        "io": ["ё", "ио"],
        "a": ["а"], "b": ["б"], "c": ["к", "ц"], "d": ["д"], "e": ["е", "э"], "f": ["ф"],
        "g": ["г"], "h": ["х"], "i": ["и", "ы"], "j": ["й"], "k": ["к"], "l": ["л", "ль"],
        "m": ["м"], "n": ["н", "нь"], "o": ["о"], "p": ["п"], "q": ["к"], "r": ["р"],
        "s": ["с"], "t": ["т", "ть"],
        "u": ["у"], "v": ["в"], "w": ["в"], "x": ["кс"], "y": ["ы", "й", "и"], "z": ["з"],
        "ł": ["л"], "ó": ["о"], "ś": ["сь"], "ź": ["зь"], "ż": ["ж"], "ń": ["нь"],
        "ć": ["ць", "ч"], "ą": ["он", "ом"], "ę": ["ен", "ем"], "š": ["ш"], "č": ["ч"],
        "ž": ["ж"], "ř": ["р"], "ě": ["е"], "ý": ["ый", "ы"], "á": ["а"], "é": ["е"],
        "í": ["и"], "ú": ["у"], "ů": ["у"], "ň": ["нь"], "ť": ["ть"], "ď": ["дь"],
    ]
    private static let maxRuleLength = 4
    private static let maxCandidates = 2048

    private static func russian(for word: String, requireValid: Bool) -> String? {
        let chars = Array(word.lowercased())
        var candidates: [String] = []

        func walk(_ pos: Int, _ acc: String) {
            guard candidates.count < maxCandidates else { return }
            guard pos < chars.count else {
                candidates.append(acc)
                return
            }
            if isCyrillic(chars[pos]) || !chars[pos].isLetter {
                walk(pos + 1, acc + String(chars[pos]))
                return
            }
            var matched = false
            for len in stride(from: min(maxRuleLength, chars.count - pos), through: 1, by: -1) {
                guard let options = rules[String(chars[pos..<(pos + len)])] else { continue }
                matched = true
                for option in options { walk(pos + len, acc + option) }
            }
            if !matched { walk(pos + 1, acc + String(chars[pos])) }
        }
        walk(0, "")

        let pick = candidates.first {
            $0.allSatisfy { !isLatin($0) } && isValid($0, language: "ru")
        }
        guard let result = pick ?? (requireValid ? nil : candidates.first) else { return nil }
        return restoreCase(result, like: word)
    }

    private static func restoreCase(_ ru: String, like source: String) -> String {
        let letters = source.filter(\.isLetter)
        if letters.count > 1 && letters.allSatisfy(\.isUppercase) { return ru.uppercased() }
        guard source.first?.isUppercase == true, let head = ru.first else { return ru }
        return head.uppercased() + ru.dropFirst()
    }

    // MARK: - Helpers

    private static func split(_ text: String) -> [Part] {
        var parts: [Part] = []
        var current = ""
        var inWord = false
        for ch in text {
            let letter = ch.isLetter
            if letter != inWord && !current.isEmpty {
                parts.append(Part(text: current, isWord: inWord))
                current = ""
            }
            inWord = letter
            current.append(ch)
        }
        if !current.isEmpty { parts.append(Part(text: current, isWord: inWord)) }
        return parts
    }

    private static func isLatin(_ ch: Character) -> Bool {
        guard ch.isLetter, let v = ch.unicodeScalars.first?.value else { return false }
        return v < 0x80 || (0xC0...0x24F).contains(v)
    }

    private static func isCyrillic(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x400...0x4FF).contains(v)
    }

    private static func isValid(_ word: String, language: String) -> Bool {
        let check = {
            NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
        if Thread.isMainThread { return check() }
        return DispatchQueue.main.sync(execute: check)
    }
}
