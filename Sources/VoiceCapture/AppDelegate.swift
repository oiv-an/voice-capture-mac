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
    // Параллельная очередь для гонки (Local + Groq одновременно на разных потоках).
    private let raceQueue = DispatchQueue(
        label: "voicecapture.race", qos: .userInitiated, attributes: .concurrent)

    // Кэш распознавателя, чтобы тяжёлая модель (large-v3 ~3 ГБ) грузилась один раз, а не на каждое нажатие.
    private var cachedRecognizer: Recognizer?
    private var cachedRecognizerKey: String?

    // Отдельный кэш локального распознавателя для параллельного режима
    // (чтобы large-v3 не перезагружалась на каждое нажатие).
    private var cachedLocalRecognizer: LocalWhisperRecognizer?
    private var cachedLocalKey: String?

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
        // Прогреваем локальную модель, если она используется напрямую ИЛИ в параллельном режиме.
        if s.parallelRaceApplicable {
            let r = makeLocalRecognizer(s)
            prewarmQueue.async {
                NSLog("[App] Прогрев модели (параллельный режим) в фоне…")
                r.prewarm()
                NSLog("[App] Модель готова к работе")
            }
            return
        }
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

        // Параллельный режим («гонка»): Groq + Local одновременно, кто первый — тот и победил.
        if currentSettings.parallelRaceApplicable {
            runParallel(samples: samples, settings: currentSettings, watchdog: watchdog)
            return
        }

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

    // MARK: - Совместный режим (Groq сразу, Local с задержкой как страховка)

    /// Стратегия: сразу шлём Groq (обычно мгновенный). Если за `localDelay` секунд
    /// Groq не вернул результат — параллельно запускаем локальный whisper, и дальше гонка.
    /// Побеждает первый успешный непустой результат. Так в большинстве случаев CPU не дёргаем.
    private func runParallel(samples: [Float], settings: AppSettings, watchdog: DispatchWorkItem) {
        let localDelay: TimeInterval = 2.0

        let groq = GroqRecognizer(
            apiKey: settings.groqApiKey, model: settings.groqModel, language: settings.language,
            prompt: settings.initialPrompt)

        let lock = NSLock()
        var settled = false  // победитель уже определён
        var groqDone = false  // Groq завершился (успех или провал)
        var localStarted = false  // локальный движок уже запущен
        var groqFailed = false  // Groq завершился без результата

        // Принимает результат от движка. Возвращает обработку победы/провала.
        func accept(_ text: String?, _ name: String) {
            lock.lock()
            let isWinner = !settled && (text?.isEmpty == false)
            if isWinner { settled = true }
            lock.unlock()

            if isWinner, let text = text {
                NSLog("[Race] Победил: \(name)")
                DispatchQueue.main.async {
                    watchdog.cancel()
                    self.handleResult(text, settings: settings, source: name)
                }
            }
        }

        // Запуск локального движка (страховка). Вызывается из таймера или при провале Groq.
        func startLocalIfNeeded(reason: String) {
            lock.lock()
            if settled || localStarted {
                lock.unlock()
                return
            }
            localStarted = true
            lock.unlock()

            NSLog("[Race] Запуск Local (\(reason))…")
            let local = self.makeLocalRecognizer(settings)
            self.raceQueue.async {
                let t = try? local.transcribe(samples: samples)
                accept(t, "Local")
                // Если оба отработали без результата — показываем ошибку.
                lock.lock()
                let bothFailed = self.boolAnd(!settled, groqDone, (t?.isEmpty != false))
                lock.unlock()
                if bothFailed {
                    NSLog("[Race] Оба движка не дали результата")
                    DispatchQueue.main.async {
                        watchdog.cancel()
                        self.isProcessing = false
                        self.statusUI.show(.error("Распознавание не дало результата"))
                    }
                }
            }
        }

        // 1) Groq — сразу.
        NSLog("[Race] Старт Groq…")
        raceQueue.async {
            let t = try? groq.transcribe(samples: samples)
            lock.lock()
            groqDone = true
            groqFailed = (t?.isEmpty != false)
            lock.unlock()
            accept(t, "Groq")
            // Groq провалился раньше таймера — сразу подключаем Local.
            if groqFailed {
                startLocalIfNeeded(reason: "Groq не дал результата")
            }
        }

        // 2) Таймер: через localDelay секунд, если Groq ещё не победил — запускаем Local.
        raceQueue.asyncAfter(deadline: .now() + localDelay) {
            startLocalIfNeeded(reason: "Groq тупит > \(Int(localDelay))с")
        }
    }

    /// Хелпер: логическое И трёх условий (для читаемости под локом).
    private func boolAnd(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool { a && b && c }

    /// Создаёт/переиспользует локальный распознаватель (отдельный кэш для параллельного режима).
    private func makeLocalRecognizer(_ s: AppSettings) -> LocalWhisperRecognizer {
        let key = "local|\(s.localModel)|\(s.language)|\(s.initialPrompt)"
        if let cached = cachedLocalRecognizer, cachedLocalKey == key {
            return cached
        }
        let r = LocalWhisperRecognizer(
            modelURL: s.localModelURL, language: s.language, initialPrompt: s.initialPrompt)
        cachedLocalRecognizer = r
        cachedLocalKey = key
        return r
    }

    private func handleResult(_ text: String, settings: AppSettings, source: String? = nil) {
        isProcessing = false
        guard !text.isEmpty else {
            NSLog("[App] Пустой результат распознавания")
            statusUI.show(.error("Пустой результат"))
            return
        }
        if let source = source {
            NSLog("[App] РЕЗУЛЬТАТ (\(source)): \(text)")
        } else {
            NSLog("[App] РЕЗУЛЬТАТ: \(text)")
        }
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

        // Небольшая пауза, чтобы фокус гарантированно вернулся в целевое поле
        // и буфер обмена успел обновиться.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.clipboard.paste()
        }
    }

    private func makeRecognizer(_ s: AppSettings) -> Recognizer {
        // Ключ кэша: backend + модель/язык/промпт. Если те же — переиспользуем загруженную модель.
        let key: String
        switch s.backend {
        case .local, .both: key = "local|\(s.localModel)|\(s.language)|\(s.initialPrompt)"
        case .groq: key = "groq|\(s.groqModel)|\(s.language)"
        }

        if let cached = cachedRecognizer, cachedRecognizerKey == key {
            return cached
        }

        let recognizer: Recognizer
        switch s.backend {
        case .local, .both:
            recognizer = LocalWhisperRecognizer(
                modelURL: s.localModelURL, language: s.language, initialPrompt: s.initialPrompt)
        case .groq:
            recognizer = GroqRecognizer(
                apiKey: s.groqApiKey, model: s.groqModel, language: s.language,
                prompt: s.initialPrompt)
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
            self.cachedLocalRecognizer = nil
            self.cachedLocalKey = nil
            // Перепрогреваем модель под новые настройки (актуально и для параллельного режима).
            self.prewarmRecognizer()
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
