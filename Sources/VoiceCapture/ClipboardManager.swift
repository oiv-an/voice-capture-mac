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

    /// Отправить Cmd+V через CGEvent ПОЛНОЙ последовательностью клавиш:
    /// Cmd↓ → V↓ → V↑ → Cmd↑.
    ///
    /// Почему так: браузеры (Chrome/Safari/Electron) часто игнорируют
    /// «V с выставленным flag .maskCommand», если перед этим не было
    /// реального keyDown самой клавиши Command. Нативные Cocoa-поля
    /// (редакторы) принимают и упрощённый вариант, поэтому раньше «через раз»
    /// падало именно в браузере. Полная последовательность с явными
    /// нажатием/отпусканием Command делает вставку стабильной везде.
    ///
    /// Все паузы — асинхронные (не блокируем главный поток).
    private func postCmdV() {
        let vKey: CGKeyCode = 9  // "v"
        let cmdKey: CGKeyCode = 55  // left Command

        guard let src = CGEventSource(stateID: .combinedSessionState),
            let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false)
        else {
            NSLog("[Clipboard] Не удалось создать CGEvent — пробую AppleScript")
            pasteViaAppleScript()
            return
        }

        // Флаг Command держим выставленным на всех событиях, пока Command «нажат».
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = .maskCommand

        let loc: CGEventTapLocation = .cghidEventTap

        // Cmd↓
        cmdDown.post(tap: loc)
        // V↓ через короткий зазор, чтобы цель успела «увидеть» зажатый Command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            vDown.post(tap: loc)
            // V↑
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                vUp.post(tap: loc)
                // Cmd↑ — отпускаем модификатор в самом конце.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
                    cmdUp.post(tap: loc)
                }
            }
        }
        NSLog("[Clipboard] Cmd+V отправлен (CGEvent: Cmd↓ V↓ V↑ Cmd↑)")
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
