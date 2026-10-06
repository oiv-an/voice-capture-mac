import AppKit
import Foundation

// Minimal type needed by the unchanged production AppleTranslationService.
enum TranslationTargetLanguage: String { case en }

struct Corpus: Decodable {
    struct Item: Decodable {
        let id: String
        let source: String
        let category: String
    }
    let warmup: [String]
    let cases: [Item]
}

final class ScreeningDelegate: NSObject, NSApplicationDelegate {
    struct Job {
        let id: String
        let source: String
        let phase: String
        let repetition: Int
    }
    private var service: AppleTranslationService?
    private var jobs: [Job] = []
    private var position = 0
    private var file: FileHandle?
    private let processStarted = ProcessInfo.processInfo.systemUptime
    private var activeJob = -1
    private var timeout: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = CommandLine.arguments
            guard args.count == 3 else {
                throw NSError(
                    domain: "Screening", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Usage: AppleScreening corpus.json output.jsonl"
                    ])
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            let corpus = try JSONDecoder().decode(Corpus.self, from: data)
            guard !FileManager.default.fileExists(atPath: args[2]) else {
                throw NSError(
                    domain: "Screening", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Refusing to overwrite an existing result"
                    ])
            }
            FileManager.default.createFile(atPath: args[2], contents: nil)
            file = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
            append([
                "type": "metadata", "model": "apple",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "started": ISO8601DateFormatter().string(from: Date()),
                "timing":
                    "unchanged VoiceCapture service: availability check + SwiftUI session + prepare + translate callback",
                "note":
                    "system translation service memory is outside this process; RSS is not total model memory",
            ])
            jobs = corpus.warmup.enumerated().map {
                Job(id: "warmup-\($0.offset)", source: $0.element, phase: "warmup", repetition: 0)
            }
            for repetition in 1...3 {
                // Same deterministic rotation in all runners; varied predecessor avoids exact request-cache advantage.
                let offset = (repetition - 1) * 17 % corpus.cases.count
                let ordered = Array(corpus.cases[offset...]) + Array(corpus.cases[..<offset])
                jobs += ordered.map {
                    Job(id: $0.id, source: $0.source, phase: "measured", repetition: repetition)
                }
            }
            service = AppleTranslationService()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.next() }
        } catch {
            NSLog("[Screening] fatal: %@", error.localizedDescription)
            exit(1)
        }
    }

    private func append(_ row: [String: Any]) {
        do {
            var data = try JSONSerialization.data(
                withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            try file?.write(contentsOf: data)
            try file?.synchronize()
        } catch {
            NSLog("[Screening] write failed: %@", error.localizedDescription)
            exit(1)
        }
    }

    private func next() {
        guard position < jobs.count else {
            append([
                "type": "summary", "model": "apple", "jobs": jobs.count,
                "process_elapsed_s": ProcessInfo.processInfo.systemUptime - processStarted,
            ])
            try? file?.close()
            NSApp.terminate(nil)
            return
        }
        let index = position
        let job = jobs[index]
        activeJob = index
        let start = ProcessInfo.processInfo.systemUptime
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.activeJob == index else { return }
            self.append([
                "type": "result", "model": "apple", "id": job.id, "phase": job.phase,
                "repetition": job.repetition, "error": "timeout after 120 seconds; run stopped",
                "seconds": ProcessInfo.processInfo.systemUptime - start,
            ])
            exit(2)
        }
        timeout = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: watchdog)
        service?.translate(job.source, target: .en) { [weak self] result in
            guard let self, self.activeJob == index else { return }
            self.timeout?.cancel()
            let seconds = ProcessInfo.processInfo.systemUptime - start
            var row: [String: Any] = [
                "type": "result", "model": "apple", "id": job.id,
                "phase": job.phase, "repetition": job.repetition, "seconds": seconds,
            ]
            switch result {
            case .success(let text): row["output"] = text
            case .failure(let error): row["error"] = error.localizedDescription
            }
            self.append(row)
            NSLog("[Screening] %@ pass=%d %.3fs", job.id, job.repetition, seconds)
            self.position += 1
            self.activeJob = -1
            // Not included in latency. Allow SwiftUI to observe session completion before the next request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.next() }
        }
    }
}

let application = NSApplication.shared
let delegate = ScreeningDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
