import AppKit
import Foundation

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
