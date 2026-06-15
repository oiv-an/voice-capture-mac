import AppKit

let app = NSApplication.shared
// Меню-бар приложение без иконки в Dock (как accessory).
app.setActivationPolicy(.accessory)

// Защита от запуска второго экземпляра: если VoiceCapture уже работает —
// два процесса конкурировали бы за хоткей и оба слали бы Cmd+V (нестабильная вставка).
let bundleId = Bundle.main.bundleIdentifier ?? "com.ivol.voicecapture"
let myPID = ProcessInfo.processInfo.processIdentifier
let others = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == bundleId && $0.processIdentifier != myPID
}
if !others.isEmpty {
    NSLog("[App] VoiceCapture уже запущен — выходим, чтобы не дублировать.")
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
