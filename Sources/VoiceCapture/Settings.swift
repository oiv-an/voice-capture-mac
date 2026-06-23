import Foundation

/// Backend распознавания речи.
enum RecognitionBackend: String, Codable, CaseIterable {
    case local  // whisper.cpp локально (по умолчанию)
    case groq  // облачный Groq Whisper
    case both  // параллельно Local + Groq, кто первый — тот и победил

    var displayName: String {
        switch self {
        case .local: return "Локально (whisper.cpp)"
        case .groq: return "Groq (облако)"
        case .both: return "Совместно (Groq + Local — кто первый)"
        }
    }
}

/// Каталог доступных ggml-моделей whisper для скачивания.
struct WhisperModelInfo {
    let id: String  // имя файла: ggml-large-v3.bin
    let title: String  // отображаемое имя
    let approxSize: String  // примерный размер

    var fileName: String { id }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(id)")!
    }

    static let catalog: [WhisperModelInfo] = [
        WhisperModelInfo(id: "ggml-tiny.bin", title: "Tiny — самая быстрая", approxSize: "75 MB"),
        WhisperModelInfo(id: "ggml-base.bin", title: "Base — базовая", approxSize: "142 MB"),
        WhisperModelInfo(id: "ggml-small.bin", title: "Small — баланс", approxSize: "466 MB"),
        WhisperModelInfo(id: "ggml-medium.bin", title: "Medium — точная", approxSize: "1.5 GB"),
        WhisperModelInfo(
            id: "ggml-large-v3.bin", title: "Large-v3 — максимум", approxSize: "3.1 GB"),
        WhisperModelInfo(
            id: "ggml-large-v3-turbo.bin", title: "Large-v3 Turbo — быстрая+точная",
            approxSize: "1.6 GB"),
    ]

    /// Скачана ли модель?
    func isDownloaded() -> Bool {
        FileManager.default.fileExists(
            atPath: AppSettings.modelsDirectory.appendingPathComponent(id).path)
    }
}

/// Настройки приложения. Хранятся в JSON в ~/Library/Application Support/VoiceCapture/settings.json
struct AppSettings: Codable {
    // Какой backend использовать
    var backend: RecognitionBackend = .local

    // --- Локальный whisper.cpp ---
    /// Имя файла модели в папке Models (например, ggml-large-v3.bin)
    var localModel: String = "ggml-large-v3.bin"
    /// Язык распознавания (ru, en, auto)
    var language: String = "ru"

    /// Initial prompt для whisper — задаёт стиль и заставляет ставить знаки препинания.
    /// Пустая строка = использовать дефолтный по языку.
    var initialPrompt: String =
        "Запиши текст грамотно, расставляя знаки препинания. Например: запятые, точки, тире и двоеточия. Нужно ли ставить вопросительные знаки? Да, конечно!"

    // --- Groq ---
    var groqApiKey: String = ""
    var groqModel: String = "whisper-large-v3"

    // --- Поведение ---
    /// Автоматически вставлять распознанный текст (Cmd+V) после копирования
    var autoPaste: Bool = true

    /// Совместный режим: задержка (сек) перед запуском локального whisper.
    /// Если Groq не ответил за это время — параллельно стартует Local. Дефолт 2.0.
    var localStartDelay: Double = 2.0

    // --- Хоткей (hold-to-talk) ---
    /// Требуемые модификаторы для записи. По умолчанию Cmd+Ctrl.
    var hotkeyRequiresCommand: Bool = true
    var hotkeyRequiresControl: Bool = true
    var hotkeyRequiresOption: Bool = false
    var hotkeyRequiresShift: Bool = false

    static let appName = "VoiceCapture"

    // MARK: - Codable (устойчивое декодирование: отсутствующие ключи → дефолты)

    init() {}

    private enum CodingKeys: String, CodingKey {
        case backend, localModel, language, initialPrompt
        case groqApiKey, groqModel, autoPaste, localStartDelay
        case hotkeyRequiresCommand, hotkeyRequiresControl
        case hotkeyRequiresOption, hotkeyRequiresShift
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        backend = (try? c.decodeIfPresent(RecognitionBackend.self, forKey: .backend)) ?? d.backend
        localModel = (try? c.decodeIfPresent(String.self, forKey: .localModel)) ?? d.localModel
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? d.language
        initialPrompt =
            (try? c.decodeIfPresent(String.self, forKey: .initialPrompt)) ?? d.initialPrompt
        groqApiKey = (try? c.decodeIfPresent(String.self, forKey: .groqApiKey)) ?? d.groqApiKey
        groqModel = (try? c.decodeIfPresent(String.self, forKey: .groqModel)) ?? d.groqModel
        autoPaste = (try? c.decodeIfPresent(Bool.self, forKey: .autoPaste)) ?? d.autoPaste
        localStartDelay =
            (try? c.decodeIfPresent(Double.self, forKey: .localStartDelay)) ?? d.localStartDelay
        hotkeyRequiresCommand =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresCommand))
            ?? d.hotkeyRequiresCommand
        hotkeyRequiresControl =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresControl))
            ?? d.hotkeyRequiresControl
        hotkeyRequiresOption =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresOption))
            ?? d.hotkeyRequiresOption
        hotkeyRequiresShift =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresShift))
            ?? d.hotkeyRequiresShift
    }

    // MARK: - Persistence

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var modelsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var settingsURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            let fresh = AppSettings()
            fresh.save()
            return fresh
        }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: AppSettings.settingsURL)
        }
    }

    /// Полный путь к выбранной локальной модели.
    var localModelURL: URL {
        AppSettings.modelsDirectory.appendingPathComponent(localModel)
    }

    /// Применим ли совместный режим: выбран backend `.both` И есть Groq-ключ И скачана локальная модель.
    var parallelRaceApplicable: Bool {
        guard backend == .both else { return false }
        let hasKey = !groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = FileManager.default.fileExists(atPath: localModelURL.path)
        return hasKey && hasModel
    }
}
