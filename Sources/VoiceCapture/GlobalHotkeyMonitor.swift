import AppKit
import CoreGraphics
import Foundation

/// Глобальный монитор горячих клавиш в стиле "hold-to-talk".
///
/// Логика: пользователь зажимает комбинацию модификаторов (по умолчанию Cmd+Ctrl).
/// Как только ВСЕ требуемые модификаторы зажаты одновременно — onPress().
/// Как только хотя бы один из требуемых модификаторов отпущен — onRelease().
///
/// Дополнительные модификаторы (удерживаются вместе с основной комбинацией):
/// - ⌥ Option — перевести результат (Apple Translation);
/// - ⇧ Shift  — не вставлять, а добавить результат задачей в список дел.
///
/// Реализация через ОПРОС состояния модификаторов (CGEventSource.flagsState) по таймеру.
final class GlobalHotkeyMonitor {
    var onPress: () -> Void = {}
    /// (shouldTranslate, asTodo) — состояние доп. модификаторов на момент отпускания.
    var onRelease: (Bool, Bool) -> Void = { _, _ in }
    /// Включает/выключает языковой бейдж в оверлее прямо во время записи.
    var onTranslationModifierChanged: (Bool) -> Void = { _ in }
    /// Включает/выключает бейдж «задача» в оверлее во время записи.
    var onTodoModifierChanged: (Bool) -> Void = { _ in }

    private var settings: AppSettings
    private var timer: Timer?
    private var isActive = false  // основная комбинация сейчас "нажата"
    private var translationModifierActive = false
    private var todoModifierActive = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func updateSettings(_ s: AppSettings) {
        self.settings = s
    }

    // MARK: - Accessibility

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let opts =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Start/Stop

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        NSLog("[Hotkey] Монитор модификаторов запущен (polling)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        if translationModifierActive {
            translationModifierActive = false
            onTranslationModifierChanged(false)
        }
        if todoModifierActive {
            todoModifierActive = false
            onTodoModifierChanged(false)
        }
    }

    // MARK: - Polling

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let allPressed = comboSatisfied(flags)
        let optionHeld =
            !settings.hotkeyRequiresOption && flags.contains(.maskAlternate)
        let shiftHeld =
            !settings.hotkeyRequiresShift && flags.contains(.maskShift)

        if allPressed && !isActive {
            isActive = true
            translationModifierActive = optionHeld
            todoModifierActive = shiftHeld
            onPress()
            onTranslationModifierChanged(translationModifierActive)
            onTodoModifierChanged(todoModifierActive)
            return
        }

        guard isActive else { return }

        if allPressed {
            if optionHeld != translationModifierActive {
                translationModifierActive = optionHeld
                onTranslationModifierChanged(optionHeld)
            }
            if shiftHeld != todoModifierActive {
                todoModifierActive = shiftHeld
                onTodoModifierChanged(shiftHeld)
            }
            return
        }

        // Основной хоткей отпущен. Используем ПРЕДЫДУЩЕЕ состояние доп. модификаторов:
        // это позволяет отпустить все клавиши одновременно между двумя poll.
        let shouldTranslate = translationModifierActive
        let asTodo = todoModifierActive
        isActive = false
        translationModifierActive = false
        todoModifierActive = false
        onTranslationModifierChanged(false)
        onTodoModifierChanged(false)
        onRelease(shouldTranslate, asTodo)
    }

    private func comboSatisfied(_ flags: CGEventFlags) -> Bool {
        let requires = [
            settings.hotkeyRequiresCommand,
            settings.hotkeyRequiresControl,
            settings.hotkeyRequiresOption,
            settings.hotkeyRequiresShift,
        ]
        guard requires.contains(true) else { return false }

        if settings.hotkeyRequiresCommand && !flags.contains(.maskCommand) { return false }
        if settings.hotkeyRequiresControl && !flags.contains(.maskControl) { return false }
        if settings.hotkeyRequiresOption && !flags.contains(.maskAlternate) { return false }
        if settings.hotkeyRequiresShift && !flags.contains(.maskShift) { return false }
        return true
    }
}
