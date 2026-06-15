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

    /// Отправить Cmd+V через CGEvent. Флаг Command ставим ТОЛЬКО на события V
    /// (без отдельных нажатий клавиши Command — они вызывают «залипание» модификатора).
    /// Между keyDown и keyUp — микропауза, чтобы приложение успело обработать.
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
        usleep(20_000)  // 20 мс между down и up
        vUp.post(tap: loc)
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
