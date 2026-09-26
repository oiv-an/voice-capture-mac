import CoreML
import Foundation

enum GigaAMError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Pinned public MIT model; installation is staged so failed downloads never replace a working model.
enum GigaAMModelStore {
    static let revision = "846833ef075fde2a8e50521d093ddb9ed7b7fd45"
    static let names = ["GigaAMv3Encoder", "GigaAMv3DecoderStep", "GigaAMv3JointStep"]
    static let directory = AppSettings.modelsDirectory.appendingPathComponent("gigaam-v3-e2e-rnnt")
    static var supported: Bool {
        #if arch(arm64)
            if #available(macOS 15, *) { return true }
        #endif
        return false
    }
    static var isDownloaded: Bool {
        let marker = try? String(
            contentsOf: directory.appendingPathComponent("revision.txt"), encoding: .utf8)
        return marker == revision
            && names.allSatisfy {
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0 + ".mlmodelc").path)
            }
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("tokens.json").path)
    }
    static let installer = Installer()

    actor Installer {
        private var running = false
        func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
            guard supported else {
                throw GigaAMError.message("GigaAM требует Apple Silicon и macOS 15+")
            }
            guard !running else { throw GigaAMError.message("GigaAM уже скачивается") }
            running = true
            defer { running = false }
            let fm = FileManager.default
            let stage = directory.deletingLastPathComponent().appendingPathComponent(
                "gigaam-install-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            let files =
                names.flatMap { name in
                    [
                        "\(name).mlpackage/Manifest.json",
                        "\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel",
                        "\(name).mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    ]
                } + ["tokens.json", "LICENSE", "model_info.json"]
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                progress(
                    Double(index) / Double(files.count + 3),
                    "GigaAM: файл \(index + 1)/\(files.count)…")
                let url = URL(
                    string:
                        "https://huggingface.co/smkrv/gigaam-v3-e2e-rnnt-coreml/resolve/\(revision)/\(file)"
                )!
                let (temporary, response) = try await session.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw GigaAMError.message("Не удалось скачать \(file)")
                }
                let destination = stage.appendingPathComponent(file)
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: temporary, to: destination)
            }
            for (index, name) in names.enumerated() {
                progress(
                    Double(files.count + index) / Double(files.count + 3),
                    "Компиляция GigaAM \(index + 1)/3…")
                let compiled = try await MLModel.compileModel(
                    at: stage.appendingPathComponent(name + ".mlpackage"))
                try fm.moveItem(at: compiled, to: stage.appendingPathComponent(name + ".mlmodelc"))
                try fm.removeItem(at: stage.appendingPathComponent(name + ".mlpackage"))
            }
            let pieces = try JSONDecoder().decode(
                [String].self, from: Data(contentsOf: stage.appendingPathComponent("tokens.json")))
            guard pieces.count == 1024 else {
                throw GigaAMError.message("Некорректный словарь GigaAM")
            }
            try revision.write(
                to: stage.appendingPathComponent("revision.txt"), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: directory.path) {
                _ = try fm.replaceItemAt(directory, withItemAt: stage)
            } else {
                try fm.moveItem(at: stage, to: directory)
            }
            progress(1, "GigaAM готова")
        }
    }
}
