import FluidAudio
import Foundation

/// Локальный многоязычный Parakeet TDT v3 через FluidAudio/Core ML.
///
/// Модель работает на Apple Neural Engine и сама определяет язык, включая русский.
/// FluidAudio хранит модель в своём стандартном кэше Application Support/FluidAudio.
final class FluidAudioRecognizer {
    typealias UIProgressHandler = @Sendable (_ fraction: Double, _ status: String) -> Void

    /// Which Parakeet-family weights to run through the same FluidAudio TDT pipeline.
    enum Variant: Sendable {
        case parakeetV3
        case fluidSpeechPro
    }

    static let displayName = "FluidAudio — Parakeet TDT v3 (live)"
    static let approxDownloadSize = "~500 MB"

    private let engine: Engine

    init(variant: Variant = .parakeetV3) {
        engine = Engine(variant: variant)
    }

    static var modelDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    static var isModelDownloaded: Bool {
        AsrModels.modelsExist(at: modelDirectory, version: .v3)
    }

    static func deleteModel() throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelDirectory)
    }

    /// Скачивает и компилирует Core ML-модель, не удерживая её в памяти после завершения.
    static func downloadModel(
        force: Bool = false,
        progress: UIProgressHandler? = nil
    ) async throws {
        _ = try await AsrModels.download(
            force: force,
            version: .v3,
            progressHandler: fluidProgressHandler(progress)
        )
    }

    /// Загружает модель в память. Повторные вызовы переиспользуют одну задачу подготовки.
    func prepare(progress: UIProgressHandler? = nil) async throws {
        try await engine.prepare(progress: progress)
    }

    /// Распознаёт полный snapshot записи. Используется и для live-preview, и для финального текста.
    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw RecognizerError.emptyAudio }
        let result = try await engine.transcribe(samples: samples)
        return Self.fixUnknownTokens(result.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// В словаре Parakeet v3 нет «ё»/«Ё» — модель выдаёт вместо них `<unk>`.
    /// Возвращаем букву: «Ё» в начале предложения или перед заглавной, иначе «ё».
    static func fixUnknownTokens(_ text: String) -> String {
        guard text.contains("<unk>") else { return text }
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: "<unk>") {
            out += rest[..<range.lowerBound]
            let prev = out.last(where: { !$0.isWhitespace })
            let sentenceStart = prev == nil || ".!?…".contains(prev!)
            let nextUpper = rest[range.upperBound...].first?.isUppercase ?? false
            out += (sentenceStart || nextUpper) ? "Ё" : "ё"
            rest = rest[range.upperBound...]
        }
        out += rest
        return out
    }

    private static func fluidProgressHandler(
        _ progress: UIProgressHandler?
    ) -> ProgressHandler? {
        guard let progress else { return nil }

        return { update in
            let status: String
            switch update.phase {
            case .listing:
                status = "Подготовка загрузки…"
            case .downloading:
                status = "Скачивание FluidAudio…"
            case .compiling:
                status = "Оптимизация Core ML…"
            }
            progress(update.fractionCompleted, status)
        }
    }

    private actor Engine {
        private let variant: Variant
        private var manager: AsrManager?
        private var preparationTask: Task<AsrManager, Error>?

        init(variant: Variant) {
            self.variant = variant
        }

        func prepare(progress: UIProgressHandler?) async throws {
            if manager != nil { return }

            if let preparationTask {
                manager = try await preparationTask.value
                return
            }

            let variant = self.variant
            let task = Task<AsrManager, Error> {
                let models: AsrModels
                switch variant {
                case .parakeetV3:
                    models = try await AsrModels.downloadAndLoad(
                        version: .v3,
                        progressHandler: FluidAudioRecognizer.fluidProgressHandler(progress)
                    )
                case .fluidSpeechPro:
                    models = try await FluidSpeechProStore.loadModels()
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            preparationTask = task

            do {
                let loadedManager = try await task.value
                manager = loadedManager
                preparationTask = nil
                NSLog(
                    "[FluidAudio] %@ загружен",
                    variant == .parakeetV3 ? "Parakeet TDT v3" : "Fluid Speech Pro")
            } catch {
                preparationTask = nil
                throw error
            }
        }

        func transcribe(samples: [Float]) async throws -> ASRResult {
            try await prepare(progress: nil)
            guard let manager else {
                throw RecognizerError.modelLoadFailed
            }

            // Каждый preview распознаёт полный snapshot независимо: не переносим
            // decoder state из предыдущего прохода, иначе текст начинает дублироваться.
            var decoderState = TdtDecoderState.make()
            return try await manager.transcribe(samples, decoderState: &decoderState)
        }
    }
}
