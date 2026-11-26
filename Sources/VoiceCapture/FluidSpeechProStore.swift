@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Fluid Speech Pro (FluidVoice Labs, CC BY 4.0) — Core ML build of a Parakeet TDT v3 fine-tune.
///
/// Same I/O as Parakeet TDT v3 (15 s windows, 8192-token vocab, blank 8192), but its joint has no
/// top-K outputs, so it is loaded manually into stock FluidAudio `AsrModels` (version `.v3`) and
/// never passed a `language:` hint. Files are pinned to a revision and installed via a staging dir.
enum FluidSpeechProStore {
    static let repo = "FluidVoice-Labs/fluid-speech-pro-coreml"
    static let revision = "3b9d38a93d606f84011e5a0a669b7ea146375a22"
    static let approxDownloadSize = "~652 MB"
    static let modelNames = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
    static let vocabularyFile = "parakeet_vocab.json"
    static let directory = AppSettings.modelsDirectory.appendingPathComponent("fluid-speech-pro")

    /// Approximate byte sizes, only for the progress bar.
    private static let files: [(path: String, size: Int64)] = {
        var list: [(String, Int64)] = []
        let weights: [String: Int64] = [
            "Preprocessor": 2_150_580, "Encoder": 613_088_448,
            "Decoder": 23_604_992, "JointDecision": 12_642_764,
        ]
        for name in modelNames {
            let base = "\(name).mlmodelc/"
            list.append((base + "analytics/coremldata.bin", 1_000))
            list.append((base + "coremldata.bin", 1_000))
            list.append((base + "metadata.json", 4_000))
            list.append((base + "model.mil", name == "Encoder" ? 622_000 : 12_000))
            list.append((base + "weights/weight.bin", weights[name] ?? 1_000))
        }
        list.append((vocabularyFile, 151_122))
        list.append(("config.json", 646))
        list.append(("LICENSE", 18_657))
        list.append(("NOTICE", 451))
        return list
    }()

    static var supported: Bool {
        #if arch(arm64)
            if #available(macOS 15, *) { return true }
        #endif
        return false
    }

    static var isDownloaded: Bool {
        let marker = try? String(
            contentsOf: directory.appendingPathComponent("revision.txt"), encoding: .utf8)
        let fm = FileManager.default
        return marker == revision
            && modelNames.allSatisfy {
                fm.fileExists(
                    atPath: directory.appendingPathComponent("\($0).mlmodelc/weights/weight.bin")
                        .path)
            }
            && fm.fileExists(atPath: directory.appendingPathComponent(vocabularyFile).path)
    }

    static func deleteModel() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Loads the compiled models into a FluidAudio `AsrModels` bundle.
    static func loadModels() async throws -> AsrModels {
        guard supported else {
            throw GigaAMError.message("Fluid Speech Pro требует Apple Silicon и macOS 15+")
        }
        guard isDownloaded else {
            throw GigaAMError.message("Сначала скачайте Fluid Speech Pro в настройках")
        }
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let ane = AsrModels.defaultConfiguration()

        func url(_ name: String) -> URL {
            directory.appendingPathComponent("\(name).mlmodelc")
        }
        let preprocessor = try await MLModel.load(
            contentsOf: url("Preprocessor"), configuration: cpu)
        let encoder = try await MLModel.load(contentsOf: url("Encoder"), configuration: ane)
        let decoder = try await MLModel.load(contentsOf: url("Decoder"), configuration: ane)
        let joint = try await MLModel.load(contentsOf: url("JointDecision"), configuration: ane)

        let data = try Data(contentsOf: directory.appendingPathComponent(vocabularyFile))
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw GigaAMError.message("Некорректный словарь Fluid Speech Pro")
        }
        var vocabulary: [Int: String] = [:]
        for (key, value) in dict {
            if let id = Int(key) { vocabulary[id] = value }
        }
        guard vocabulary.count == 8192 else {
            throw GigaAMError.message("Некорректный словарь Fluid Speech Pro (\(vocabulary.count))")
        }

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: ane,
            vocabulary: vocabulary,
            version: .v3
        )
    }

    static let installer = Installer()

    actor Installer {
        private var running = false

        func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
            guard supported else {
                throw GigaAMError.message("Fluid Speech Pro требует Apple Silicon и macOS 15+")
            }
            guard !running else { throw GigaAMError.message("Fluid Speech Pro уже скачивается") }
            running = true
            defer { running = false }

            let fm = FileManager.default
            let stage = directory.deletingLastPathComponent().appendingPathComponent(
                "fluid-speech-pro-install-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            let total = Double(files.reduce(0) { $0 + $1.size })
            var done: Int64 = 0
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let label = "Fluid Speech Pro: файл \(index + 1)/\(files.count)"
                let remote = URL(
                    string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
                let destination = stage.appendingPathComponent(file.path)
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                try await Self.fetch(remote, to: destination, session: session) { received in
                    let fraction = min(0.97, Double(base + received) / total)
                    let mb = Double(base + received) / 1_000_000
                    progress(fraction, String(format: "%@ · %.0f MB", label, mb))
                }
                done += file.size
            }

            // Sanity: compiled models must load before the old install is replaced.
            progress(0.98, "Проверка модели…")
            let check = MLModelConfiguration()
            check.computeUnits = .cpuOnly
            for name in modelNames {
                _ = try MLModel(
                    contentsOf: stage.appendingPathComponent("\(name).mlmodelc"),
                    configuration: check)
            }
            try revision.write(
                to: stage.appendingPathComponent("revision.txt"), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: directory.path) {
                _ = try fm.replaceItemAt(directory, withItemAt: stage)
            } else {
                try fm.moveItem(at: stage, to: directory)
            }
            progress(1, "Fluid Speech Pro готова")
        }

        /// Download with byte-level progress (one Encoder weight file is ~613 MB).
        private static func fetch(
            _ url: URL, to destination: URL, session: URLSession,
            onBytes: @escaping @Sendable (Int64) -> Void
        ) async throws {
            final class Box: @unchecked Sendable { var task: URLSessionDownloadTask? }
            let box = Box()
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if let received = box.task?.countOfBytesReceived { onBytes(received) }
                }
            }
            defer { poller.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    let task = session.downloadTask(with: url) { temporary, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let temporary,
                            let http = response as? HTTPURLResponse, http.statusCode == 200
                        else {
                            continuation.resume(
                                throwing: GigaAMError.message(
                                    "Не удалось скачать \(url.lastPathComponent)"))
                            return
                        }
                        do {
                            try? FileManager.default.removeItem(at: destination)
                            try FileManager.default.moveItem(at: temporary, to: destination)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    box.task = task
                    task.resume()
                }
            } onCancel: {
                box.task?.cancel()
            }
        }
    }
}
