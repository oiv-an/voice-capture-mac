import Foundation

/// Общий протокол распознавателя речи.
protocol Recognizer {
    /// Принимает float-сэмплы (16kHz mono) и возвращает текст.
    func transcribe(samples: [Float]) throws -> String

    /// Предзагрузка/прогрев (опционально). Для локальной модели — загрузка в память заранее.
    func prewarm()
}

extension Recognizer {
    func prewarm() {}
}

enum RecognizerError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed
    case inferenceFailed
    case emptyAudio
    case network(String)
    case http(Int, String)
    case missingApiKey

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let p):
            return "Модель не найдена: \(p). Скачайте её (см. README / кнопку в настройках)."
        case .modelLoadFailed: return "Не удалось загрузить модель whisper."
        case .inferenceFailed: return "Ошибка распознавания (whisper)."
        case .emptyAudio: return "Пустая запись — нечего распознавать."
        case .network(let m): return "Сетевая ошибка: \(m)"
        case .http(let c, let m): return "Ошибка сервера (\(c)): \(m)"
        case .missingApiKey: return "Не задан Groq API-ключ в настройках."
        }
    }
}
