import AppKit
import CoreGraphics
import Foundation

/// Глобальный монитор горячих клавиш в стиле "hold-to-talk".
///
/// Логика: пользователь зажимает комбинацию модификаторов (по умолчанию Cmd+Ctrl).
/// Как только ВСЕ требуемые модификаторы зажаты одновременно — onPress().
/// Как только хотя бы один из требуемых модификаторов отпущен — onRelease().
///
/// Реализация через ОПРОС состояния модификаторов (CGEventSource.flagsState) по таймеру.
/// Это надёжнее CGEventTap: работает даже когда приложение неактивно (accessory-меню-бар),
/// и НЕ требует клика по иконке для «пробуждения». Требует разрешения Accessibility.
final class GlobalHotkeyMonitor {
    var onPress: () -> Void = {}
    /// Bool = нужно ли переводить финальный результат (Option удерживался до отпускания хоткея).
    var onRelease: (Bool) -> Void = { _ in }
    /// Включает/выключает языковой бейдж в оверлее прямо во время записи.
    var onTranslationModifierChanged: (Bool) -> Void = { _ in }

    private var settings: AppSettings
    private var timer: Timer?
    private var isActive = false  // основная комбинация сейчас "нажата"
    private var translationModifierActive = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func updateSettings(_ s: AppSettings) {
        self.settings = s
    }

    // MARK: - Accessibility

    /// Проверка/запрос разрешения Accessibility (нужно для чтения состояния клавиш).
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let opts =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Start/Stop

    func start() {
        guard timer == nil else { return }
        // Опрос каждые 30 мс — достаточно отзывчиво для hold-to-talk, нагрузка минимальна.
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
    }

    // MARK: - Polling

    private func poll() {
        // Читаем текущее состояние модификаторов независимо от фокуса приложения.
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let allPressed = comboSatisfied(flags)
        // Option зарезервирован как дополнительный модификатор перевода.
        // Если он уже входит в основной хоткей старой настройки, опциональный
        // режим перевода отключён, чтобы обычная запись не переводилась всегда.
        let optionHeld =
            !settings.hotkeyRequiresOption && flags.contains(.maskAlternate)

        if allPressed && !isActive {
            isActive = true
            translationModifierActive = optionHeld
            onPress()
            onTranslationModifierChanged(translationModifierActive)
            return
        }

        guard isActive else { return }

        if allPressed {
            // Пока основная комбинация зажата, отпускание Option сразу отменяет
            // перевод и убирает бейдж. Повторное нажатие снова включает перевод.
            if optionHeld != translationModifierActive {
                translationModifierActive = optionHeld
                onTranslationModifierChanged(optionHeld)
            }
            return
        }

        // Основной хоткей отпущен. Используем ПРЕДЫДУЩЕЕ состояние Option:
        // это позволяет отпустить все три клавиши одновременно между двумя poll.
        let shouldTranslate = translationModifierActive
        isActive = false
        translationModifierActive = false
        onTranslationModifierChanged(false)
        onRelease(shouldTranslate)
    }

    /// Все требуемые модификаторы зажаты одновременно?
    private func comboSatisfied(_ flags: CGEventFlags) -> Bool {
        // Нет ни одного требования — комбинация невозможна.
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
