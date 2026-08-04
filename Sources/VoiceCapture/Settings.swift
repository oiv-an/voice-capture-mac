import Foundation

/// Backend распознавания речи.
enum RecognitionBackend: String, Codable, CaseIterable {
    case local  // whisper.cpp локально
    case fluidAudio  // Parakeet TDT v3 через FluidAudio/Core ML, live-preview
    case groq  // облачный Groq Whisper
    case both  // параллельно Local + Groq, кто первый — тот и победил

    var displayName: String {
        switch self {
        case .local: return "Локально (whisper.cpp)"
        case .fluidAudio: return "FluidAudio (Parakeet v3 — live)"
        case .groq: return "Groq (облако)"
        case .both: return "Совместно (Groq + Local — кто первый)"
        }
    }
}

/// Целевой язык локального Apple Translation (исходный текст всегда русский).
enum TranslationTargetLanguage: String, Codable, CaseIterable {
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case polish = "pl"
    case ukrainian = "uk"
    case turkish = "tr"
    case chineseSimplified = "zh"
    case japanese = "ja"
    case korean = "ko"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .polish: return "Polski"
        case .ukrainian: return "Українська"
        case .turkish: return "Türkçe"
        case .chineseSimplified: return "简体中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    /// Короткая подпись для логов и оверлея.
    var badge: String {
        String(rawValue.split(separator: "-").first ?? Substring(rawValue)).uppercased()
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
    var backend: RecognitionBackend = .both

    // --- Локальный whisper.cpp ---
    /// Имя файла модели в папке Models (например, ggml-large-v3-turbo.bin)
    var localModel: String = "ggml-large-v3-turbo.bin"
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

    /// UID выбранного микрофона (CoreAudio device UID). Пусто = системный по умолчанию.
    var microphoneUID: String = ""

    // --- Apple Translation (macOS 15+) ---
    /// Целевой язык. Исходный текст фиксированно русский.
    var translationTarget: TranslationTargetLanguage = .english

    // --- Хоткей (hold-to-talk) ---
    /// Требуемые модификаторы для записи. По умолчанию Cmd+Ctrl.
    var hotkeyRequiresCommand: Bool = true
    var hotkeyRequiresControl: Bool = true
    var hotkeyRequiresOption: Bool = false
    var hotkeyRequiresShift: Bool = false

    /// Человекочитаемое отображение текущего hold-to-talk сочетания.
    var hotkeyDisplayName: String {
        var symbols: [String] = []
        if hotkeyRequiresCommand { symbols.append("⌘") }
        if hotkeyRequiresControl { symbols.append("⌃") }
        if hotkeyRequiresOption { symbols.append("⌥") }
        if hotkeyRequiresShift { symbols.append("⇧") }
        return symbols.isEmpty ? "Не назначен" : symbols.joined(separator: " + ")
    }

    /// Возвращает хоткей к заводскому сочетанию Cmd+Ctrl.
    mutating func resetHotkeyToDefault() {
        hotkeyRequiresCommand = true
        hotkeyRequiresControl = true
        hotkeyRequiresOption = false
        hotkeyRequiresShift = false
    }

    static let appName = "VoiceCapture"

    // MARK: - Codable (устойчивое декодирование: отсутствующие ключи → дефолты)

    init() {}

    private enum CodingKeys: String, CodingKey {
        case backend, localModel, language, initialPrompt
        case groqApiKey, groqModel, autoPaste, localStartDelay, microphoneUID
        case translationTarget
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
        microphoneUID =
            (try? c.decodeIfPresent(String.self, forKey: .microphoneUID)) ?? d.microphoneUID
        translationTarget =
            (try? c.decodeIfPresent(TranslationTargetLanguage.self, forKey: .translationTarget))
            ?? d.translationTarget
        hotkeyRequiresCommand =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresCommand))
            ?? d.hotkeyRequiresCommand
        hotkeyRequiresControl =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresControl))
            ?? d.hotkeyRequiresControl
        // Option зарезервирован как дополнительный модификатор Apple Translation.
        // Старое сохранённое значение намеренно не восстанавливаем.
        hotkeyRequiresOption = false
        hotkeyRequiresShift =
            (try? c.decodeIfPresent(Bool.self, forKey: .hotkeyRequiresShift))
            ?? d.hotkeyRequiresShift
        // Миграция старой комбинации, состоявшей только из Option.
        if !hotkeyRequiresCommand && !hotkeyRequiresControl && !hotkeyRequiresShift {
            hotkeyRequiresCommand = true
            hotkeyRequiresControl = true
        }
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
