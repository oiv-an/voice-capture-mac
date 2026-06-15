import AVFoundation
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = AppSettings.load()

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let clipboard = ClipboardManager()
    private let statusUI = StatusController()
    private var hotkeys: GlobalHotkeyMonitor!
    private var settingsWC: SettingsWindowController?

    private var isProcessing = false
    private let workQueue = DispatchQueue(label: "voicecapture.work", qos: .userInitiated)
    private let prewarmQueue = DispatchQueue(label: "voicecapture.prewarm", qos: .utility)

    // Кэш распознавателя, чтобы тяжёлая модель (large-v3 ~3 ГБ) грузилась один раз, а не на каждое нажатие.
    private var cachedRecognizer: Recognizer?
    private var cachedRecognizerKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotkeys()

        // Запрос разрешений при старте.
        AudioRecorder.requestPermission { granted in
            if !granted {
                NSLog("[App] Доступ к микрофону не предоставлен")
            }
        }
        // Проверяем доступ ТИХО (prompt: false), чтобы системное окно не выскакивало каждый запуск.
        // Если доступа нет — покажем свою подсказку один раз.
        if !GlobalHotkeyMonitor.ensureAccessibilityPermission(prompt: false) {
            showAccessibilityHint()
        }

        // Прогрев модели в фоне, чтобы первое распознавание не ждало загрузки 3 ГБ.
        prewarmRecognizer()
    }

    private func prewarmRecognizer() {
        let s = settings
        guard s.backend == .local else { return }
        // Создаём recognizer СИНХРОННО на главном потоке (запись в кэш без гонки),
        // а тяжёлую загрузку модели делаем в отдельной фоновой очереди.
        let r = makeRecognizer(s)
        prewarmQueue.async {
            NSLog("[App] Прогрев модели в фоне…")
            r.prewarm()
            NSLog("[App] Модель готова к работе")
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill", accessibilityDescription: "VoiceCapture")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VoiceCapture 3.0", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let info = NSMenuItem(
            title: "Запись: зажмите ⌘⌃ и говорите", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(
            NSMenuItem(title: "Папка моделей…", action: #selector(openModels), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: "Проверить доступ (Accessibility)", action: #selector(checkAccessibility),
                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeys = GlobalHotkeyMonitor(settings: settings)
        hotkeys.onPress = { [weak self] in self?.startRecording() }
        hotkeys.onRelease = { [weak self] in self?.stopRecordingAndProcess() }
        hotkeys.start()
    }

    // MARK: - Recording flow

    private func startRecording() {
        guard !isProcessing else { return }
        guard !recorder.isRecording else { return }
        if recorder.start() {
            statusUI.show(.recording)
        } else {
            statusUI.show(.error("Не удалось начать запись"))
        }
    }

    private func stopRecordingAndProcess() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()

        guard samples.count > 1600 else {  // < 0.1с — игнор
            NSLog("[App] Слишком коротко (\(samples.count) сэмплов) — держите ⌘⌃ дольше")
            statusUI.show(.error("Слишком коротко — держите ⌘⌃ дольше"))
            return
        }

        // Фильтр тишины — иначе whisper галлюцинирует на пустом сигнале.
        let (rms, _) = AudioRecorder.levels(samples)
        NSLog("[App] К распознаванию: \(samples.count) сэмплов, RMS=\(String(format: "%.4f", rms))")
        guard rms > 0.003 else {
            NSLog("[App] Тишина (RMS=\(rms)) — пропуск")
            statusUI.show(.error("Тишина — ничего не сказано"))
            return
        }

        isProcessing = true
        statusUI.show(.processing)

        // Watchdog: если распознавание подвисло — сбрасываем состояние, чтобы app не залип.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.isProcessing else { return }
            NSLog("[App] WATCHDOG: распознавание висит >90с — сброс")
            self.isProcessing = false
            self.statusUI.show(.error("Распознавание зависло — попробуйте снова"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: watchdog)

        let currentSettings = settings
        // recognizer берём здесь, на главном потоке (без гонки за кэш).
        let recognizer = makeRecognizer(currentSettings)
        workQueue.async { [weak self] in
            guard let self = self else { return }
            NSLog("[App] Старт transcribe…")
            do {
                let text = try recognizer.transcribe(samples: samples)
                DispatchQueue.main.async {
                    watchdog.cancel()
                    self.handleResult(text, settings: currentSettings)
                }
            } catch {
                DispatchQueue.main.async {
                    watchdog.cancel()
                    self.isProcessing = false
                    self.statusUI.show(.error(error.localizedDescription))
                }
            }
        }
    }

    private func handleResult(_ text: String, settings: AppSettings) {
        isProcessing = false
        guard !text.isEmpty else {
            NSLog("[App] Пустой результат распознавания")
            statusUI.show(.error("Пустой результат"))
            return
        }
        NSLog("[App] РЕЗУЛЬТАТ: \(text)")
        clipboard.copy(text)
        statusUI.show(.done(text))
        if settings.autoPaste {
            // Ждём, пока пользователь реально отпустит все модификаторы (⌘⌃),
            // иначе Cmd+V «смешается» с залипшими клавишами и вставка не сработает.
            waitForModifiersReleasedThenPaste()
        }
    }

    /// Ждёт отпускания всех модификаторов, затем шлёт Cmd+V. Не блокирует главный поток.
    private func waitForModifiersReleasedThenPaste(attempt: Int = 0) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let anyHeld =
            flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate) || flags.contains(.maskShift)

        // Максимум ~1.5 сек ожидания (30 попыток по 50 мс), потом вставляем как есть.
        if anyHeld && attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForModifiersReleasedThenPaste(attempt: attempt + 1)
            }
            return
        }

        // Небольшая пауза, чтобы фокус гарантированно вернулся в целевое поле.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.clipboard.paste()
        }
    }

    private func makeRecognizer(_ s: AppSettings) -> Recognizer {
        // Ключ кэша: backend + модель/язык/промпт. Если те же — переиспользуем загруженную модель.
        let key: String
        switch s.backend {
        case .local: key = "local|\(s.localModel)|\(s.language)|\(s.initialPrompt)"
        case .groq: key = "groq|\(s.groqModel)|\(s.language)"
        }

        if let cached = cachedRecognizer, cachedRecognizerKey == key {
            return cached
        }

        let recognizer: Recognizer
        switch s.backend {
        case .local:
            recognizer = LocalWhisperRecognizer(
                modelURL: s.localModelURL, language: s.language, initialPrompt: s.initialPrompt)
        case .groq:
            recognizer = GroqRecognizer(
                apiKey: s.groqApiKey, model: s.groqModel, language: s.language)
        }
        cachedRecognizer = recognizer
        cachedRecognizerKey = key
        return recognizer
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let wc = SettingsWindowController(settings: settings) { [weak self] updated in
            guard let self = self else { return }
            self.settings = updated
            self.hotkeys.updateSettings(updated)
            // Настройки изменились — сбрасываем кэш распознавателя (модель/язык могли поменяться).
            self.cachedRecognizer = nil
            self.cachedRecognizerKey = nil
        }
        self.settingsWC = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openModels() {
        NSWorkspace.shared.open(AppSettings.modelsDirectory)
    }

    @objc private func checkAccessibility() {
        let ok = GlobalHotkeyMonitor.ensureAccessibilityPermission(prompt: true)
        let alert = NSAlert()
        alert.messageText = ok ? "Доступ Accessibility предоставлен" : "Нужен доступ Accessibility"
        alert.informativeText =
            ok
            ? "Горячие клавиши и авто-вставка будут работать."
            : "Откройте Системные настройки → Конфиденциальность и безопасность → Универсальный доступ и включите VoiceCapture, затем перезапустите приложение."
        alert.runModal()
    }

    private func showAccessibilityHint() {
        let alert = NSAlert()
        alert.messageText = "Требуется доступ Accessibility"
        alert.informativeText =
            "Для глобальных горячих клавиш и авто-вставки разрешите VoiceCapture в Системные настройки → Конфиденциальность и безопасность → Универсальный доступ, затем перезапустите приложение."
        alert.runModal()
    }

    @objc private func quit() {
        hotkeys.stop()
        NSApp.terminate(nil)
    }
}
