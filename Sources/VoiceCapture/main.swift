import AppKit
import FluidAudio
import Foundation

// Local file transcription / model installation, without microphone, clipboard or GUI lock.
if CommandLine.arguments.contains("--gigaam-download")
    || CommandLine.arguments.contains("--gigaam-file")
{
    let arguments = CommandLine.arguments
    Task {
        do {
            if arguments.contains("--gigaam-download") {
                try await GigaAMModelStore.installer.download { _, status in
                    NSLog("[GigaAM install] %@", status)
                }
            }
            if let index = arguments.firstIndex(of: "--gigaam-file") {
                guard index + 1 < arguments.count else {
                    throw GigaAMError.message("Укажите путь к аудиофайлу после --gigaam-file")
                }
                let samples = try AudioConverter().resampleAudioFile(
                    URL(fileURLWithPath: arguments[index + 1]))
                let recognizer = GigaAMRecognizer()
                let start = Date()
                let text = try await recognizer.transcribe(samples: samples)
                print(text)
                NSLog(
                    "[GigaAM] %.2f с аудио за %.2f с", Double(samples.count) / 16000,
                    Date().timeIntervalSince(start))
            }
            exit(0)
        } catch {
            NSLog("[GigaAM] %@", error.localizedDescription)
            exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
// Меню-бар приложение без иконки в Dock (как accessory).
app.setActivationPolicy(.accessory)

// Защита от запуска второго экземпляра через файловый замок (flock).
// Работает при ЛЮБОМ способе запуска (.app, прямой бинарь, swift run),
// в отличие от проверки по bundleIdentifier.
// Два процесса конкурировали бы за хоткей и слали бы Cmd+V дважды.
let lockPath = NSTemporaryDirectory() + "voicecapture.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD == -1 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    NSLog("[App] VoiceCapture уже запущен (lock занят) — выходим.")
    exit(0)
}
// lockFD держим открытым весь жизненный цикл процесса — замок снимется при выходе.

let delegate = AppDelegate()
app.delegate = delegate
app.run()
