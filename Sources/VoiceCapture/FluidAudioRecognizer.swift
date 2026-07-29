import FluidAudio
import Foundation

/// Локальный многоязычный Parakeet TDT v3 через FluidAudio/Core ML.
///
/// Модель работает на Apple Neural Engine и сама определяет язык, включая русский.
/// FluidAudio хранит модель в своём стандартном кэше Application Support/FluidAudio.
final class FluidAudioRecognizer {
    typealias UIProgressHandler = @Sendable (_ fraction: Double, _ status: String) -> Void

    static let displayName = "FluidAudio — Parakeet TDT v3 (live)"
    static let approxDownloadSize = "~500 MB"

    private let engine = Engine()

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
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        private var manager: AsrManager?
        private var preparationTask: Task<AsrManager, Error>?

        func prepare(progress: UIProgressHandler?) async throws {
            if manager != nil { return }

            if let preparationTask {
                manager = try await preparationTask.value
                return
            }

            let task = Task<AsrManager, Error> {
                let models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    progressHandler: FluidAudioRecognizer.fluidProgressHandler(progress)
                )
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            preparationTask = task

            do {
                let loadedManager = try await task.value
                manager = loadedManager
                preparationTask = nil
                NSLog("[FluidAudio] Parakeet TDT v3 загружен")
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
