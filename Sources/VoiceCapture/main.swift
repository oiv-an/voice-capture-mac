import AppKit

let app = NSApplication.shared
// Меню-бар приложение без иконки в Dock (как accessory).
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
