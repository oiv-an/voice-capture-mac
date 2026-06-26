import Foundation

/// Одна запись истории распознавания.
struct RecognitionEntry: Codable {
    let text: String
    let date: Date
    let source: String  // "Local", "Groq" или ""

    /// Количество слов в тексте.
    var wordCount: Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}

/// История распознаваний + счётчики. Хранится в history.json рядом с настройками.
/// Singleton — одна точка доступа из AppDelegate.
final class RecognitionHistory: Codable {
    static let shared = RecognitionHistory.load()

    /// Последние записи (новые — в начале). Ограничено maxEntries.
    private(set) var entries: [RecognitionEntry] = []
    /// Всего распознаваний за всё время.
    private(set) var totalCount: Int = 0
    /// Всего слов распознано за всё время.
    private(set) var totalWords: Int = 0

    private static let maxEntries = 10

    private enum CodingKeys: String, CodingKey {
        case entries, totalCount, totalWords
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decodeIfPresent([RecognitionEntry].self, forKey: .entries)) ?? []
        totalCount = (try? c.decodeIfPresent(Int.self, forKey: .totalCount)) ?? 0
        totalWords = (try? c.decodeIfPresent(Int.self, forKey: .totalWords)) ?? 0
    }

    /// Добавить новое распознавание и сохранить.
    func add(text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = RecognitionEntry(text: trimmed, date: Date(), source: source)
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        totalCount += 1
        totalWords += entry.wordCount
        save()
    }

    /// Очистить список последних записей (счётчики totalCount/totalWords сохраняются).
    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    static var fileURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("history.json")
    }

    static func load() -> RecognitionHistory {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(RecognitionHistory.self, from: data)
        else {
            return RecognitionHistory()
        }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL)
        }
    }
}
