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
    /// Требует разрешения Accessibility.
    func paste() {
        postCmdV()
    }

    /// Отправить Cmd+V через CGEvent. Флаг Command ставим на события V.
    /// keyDown и keyUp шлём подряд без блокирующих пауз на главном потоке.
    private func postCmdV() {
        let vKey: CGKeyCode = 9  // "v"
        guard let src = CGEventSource(stateID: .combinedSessionState),
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else {
            NSLog("[Clipboard] Не удалось создать CGEvent — пробую AppleScript")
            pasteViaAppleScript()
            return
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        let loc: CGEventTapLocation = .cghidEventTap
        vDown.post(tap: loc)
        // keyUp с небольшой асинхронной задержкой (не блокируем главный поток),
        // чтобы целевое приложение успело принять keyDown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            vUp.post(tap: loc)
        }
        NSLog("[Clipboard] Cmd+V отправлен (CGEvent)")
    }

    /// Запасной механизм вставки через System Events (если CGEvent недоступен).
    private func pasteViaAppleScript() {
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        var error: NSDictionary?
        if let apple = NSAppleScript(source: script) {
            apple.executeAndReturnError(&error)
            if let error = error {
                NSLog("[Clipboard] AppleScript-вставка не удалась: \(error)")
            } else {
                NSLog("[Clipboard] Cmd+V отправлен (AppleScript)")
            }
        }
    }
}
