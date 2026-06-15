import AppKit
import CoreGraphics
import Foundation

/// Работа с буфером обмена и авто-вставка (Cmd+V) во внешнее приложение.
final class ClipboardManager {

    /// Скопировать текст в буфер обмена.
    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Эмулировать Cmd+V для вставки в активное приложение.
    /// Основной путь — AppleScript (System Events): надёжнее для accessory-приложений.
    /// Требует разрешения Accessibility.
    func paste() {
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        var error: NSDictionary?
        if let apple = NSAppleScript(source: script) {
            apple.executeAndReturnError(&error)
            if let error = error {
                NSLog("[Clipboard] AppleScript-вставка не удалась: \(error) — пробую CGEvent")
                pasteViaCGEvent()
            } else {
                NSLog("[Clipboard] Cmd+V отправлен (AppleScript)")
            }
        } else {
            pasteViaCGEvent()
        }
    }

    /// Запасной механизм через CGEvent (если AppleScript недоступен).
    private func pasteViaCGEvent() {
        let vKey: CGKeyCode = 9  // "v"
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else {
            NSLog("[Clipboard] Не удалось создать CGEvent для вставки")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        NSLog("[Clipboard] Cmd+V отправлен (CGEvent)")
    }
}
