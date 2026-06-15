import CWhisper
import Foundation

/// Локальное распознавание через whisper.cpp (CPU/Accelerate).
final class LocalWhisperRecognizer: Recognizer {
    private var ctx: OpaquePointer?
    private let modelURL: URL
    private let language: String
    private let initialPrompt: String
    private let lock = NSLock()

    init(modelURL: URL, language: String, initialPrompt: String = "") {
        self.modelURL = modelURL
        self.language = language
        self.initialPrompt = initialPrompt
    }

    deinit {
        if let ctx = ctx { whisper_free(ctx) }
    }

    /// Прогрев — загрузка модели в память заранее (вызывать в фоне при старте).
    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        try? ensureContext()
    }

    private func ensureContext() throws {
        if ctx != nil { return }

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RecognizerError.modelNotFound(modelURL.path)
        }

        var cparams = whisper_context_default_params()
        // CPU-сборка без Metal — GPU выключаем явно.
        cparams.use_gpu = false

        let loaded = modelURL.path.withCString { cpath in
            whisper_init_from_file_with_params(cpath, cparams)
        }

        guard let loaded = loaded else {
            throw RecognizerError.modelLoadFailed
        }
        self.ctx = loaded
        NSLog("[Whisper] Модель загружена: \(modelURL.lastPathComponent)")
    }

    func transcribe(samples: [Float]) throws -> String {
        guard samples.count > 0 else { throw RecognizerError.emptyAudio }

        lock.lock()
        defer { lock.unlock() }

        try ensureContext()
        guard let ctx = ctx else { throw RecognizerError.modelLoadFailed }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = true
        params.single_segment = false
        params.suppress_blank = true
        // suppress_nst (non-speech tokens) выключаем — иначе режутся знаки препинания.
        params.suppress_nst = false

        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        params.n_threads = Int32(threads)

        // initial_prompt с пунктуацией заставляет whisper ставить запятые/точки/!?.
        // Берём из настроек; если пусто — дефолт по языку.
        let promptText: String
        if !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptText = initialPrompt
        } else if language.hasPrefix("ru") {
            promptText =
                "Запиши текст грамотно, расставляя знаки препинания. Например: запятые, точки, тире и двоеточия. Нужно ли ставить вопросительные знаки? Да, конечно!"
        } else {
            promptText =
                "Write the text correctly, using punctuation. For example: commas, periods, dashes, and colons. Should we add question marks? Yes, of course!"
        }

        // Язык: "auto" -> nil (автоопределение)
        let langValue = (language == "auto" || language.isEmpty) ? nil : language

        let result: Int32 = promptText.withCString { promptPtr -> Int32 in
            params.initial_prompt = promptPtr
            if let langValue = langValue {
                return langValue.withCString { langPtr -> Int32 in
                    params.language = langPtr
                    return samples.withUnsafeBufferPointer { buf in
                        whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                    }
                }
            } else {
                params.language = nil
                params.detect_language = true
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }

        guard result == 0 else { throw RecognizerError.inferenceFailed }

        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
