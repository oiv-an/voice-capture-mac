import Foundation

/// Одна задача из текущего списка дел.
struct TodoItem: Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
}

/// Текущий список дел. Хранится в ~/Library/Application Support/VoiceCapture/todos.json.
/// Выполненные задачи удаляются полностью (архива нет).
final class TodoStore {
    static let shared = TodoStore()
    static let didChange = Notification.Name("TodoStoreDidChange")

    private(set) var items: [TodoItem] = []

    static var fileURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("todos.json")
    }

    private init() {
        load()
    }

    func add(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        items.append(TodoItem(text: clean))
        saveAndNotify()
    }

    func update(id: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if clean.isEmpty {
            items.remove(at: i)
        } else {
            guard items[i].text != clean else { return }
            items[i].text = clean
        }
        saveAndNotify()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        saveAndNotify()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
            let decoded = try? JSONDecoder().decode([TodoItem].self, from: data)
        else { return }
        items = decoded
    }

    private func saveAndNotify() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
