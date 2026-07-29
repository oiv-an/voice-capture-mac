import AppKit

/// Окно настроек на AppKit: выбор backend, модель (со скачиванием), язык, Groq-ключ, авто-вставка.
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
    URLSessionDownloadDelegate
{
    private var settings: AppSettings
    private let onSave: (AppSettings) -> Void

    private let backendPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let groqKeyField = NSSecureTextField()
    private let groqModelField = NSTextField()
    private let promptTextView = NSTextView()
    private let promptScroll = NSScrollView()
    private let autoPasteCheck = NSButton(
        checkboxWithTitle: "Авто-вставка (Cmd+V) после распознавания", target: nil, action: nil)
    private let localDelayField = NSTextField()

    private let downloadButton = NSButton(title: "Скачать модель", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let modelStatusLabel = NSTextField(labelWithString: "")

    private var downloadTask: URLSessionDownloadTask?
    private var downloadingModel: WhisperModelInfo?
    private var pendingWhisperModelID: String

    init(settings: AppSettings, onSave: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.onSave = onSave
        self.pendingWhisperModelID = settings.localModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceCapture — Настройки"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        var y: CGFloat = 550

        func addRow(_ title: String, _ control: NSView, height: CGFloat = 26) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 20, y: y, width: 150, height: 24)
            label.alignment = .right
            content.addSubview(label)
            control.frame = NSRect(x: 180, y: y - 2, width: 300, height: height)
            content.addSubview(control)
            y -= 40
        }

        backendPopup.addItems(withTitles: RecognitionBackend.allCases.map { $0.displayName })
        if !isAppleSilicon {
            let fluidIndex = RecognitionBackend.allCases.firstIndex(of: .fluidAudio)!
            backendPopup.item(at: fluidIndex)?.isEnabled = false
        }
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)
        addRow("Распознавание:", backendPopup)

        // Содержимое списка зависит от backend: Whisper-каталог или Parakeet v3.
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        addRow("Локальная модель:", modelPopup)

        // Статус модели + кнопка скачать
        modelStatusLabel.frame = NSRect(x: 180, y: y, width: 200, height: 20)
        modelStatusLabel.font = NSFont.systemFont(ofSize: 11)
        modelStatusLabel.textColor = .secondaryLabelColor
        content.addSubview(modelStatusLabel)

        downloadButton.target = self
        downloadButton.action = #selector(downloadTapped)
        downloadButton.bezelStyle = .rounded
        downloadButton.frame = NSRect(x: 380, y: y - 4, width: 100, height: 28)
        content.addSubview(downloadButton)
        y -= 34

        progressBar.frame = NSRect(x: 180, y: y, width: 300, height: 16)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        content.addSubview(progressBar)
        y -= 36

        languagePopup.addItems(withTitles: ["ru", "en", "auto"])
        addRow("Язык:", languagePopup)

        // Многострочное поле для промпта (видно весь текст, можно редактировать).
        let promptLabel = NSTextField(labelWithString: "Initial prompt:")
        promptLabel.frame = NSRect(x: 20, y: y, width: 150, height: 24)
        promptLabel.alignment = .right
        content.addSubview(promptLabel)

        promptScroll.frame = NSRect(x: 180, y: y - 48, width: 300, height: 72)
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.autohidesScrollers = true

        promptTextView.frame = promptScroll.bounds
        promptTextView.minSize = NSSize(width: 0, height: 72)
        promptTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.autoresizingMask = [.width]
        promptTextView.textContainer?.containerSize = NSSize(
            width: 300, height: CGFloat.greatestFiniteMagnitude)
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.font = NSFont.systemFont(ofSize: 12)
        promptTextView.isRichText = false
        promptScroll.documentView = promptTextView
        content.addSubview(promptScroll)
        y -= 84

        addRow("Groq API key:", groqKeyField)
        addRow("Groq модель:", groqModelField)

        autoPasteCheck.frame = NSRect(x: 180, y: y, width: 300, height: 24)
        content.addSubview(autoPasteCheck)
        y -= 40

        addRow("Задержка Local (сек):", localDelayField, height: 24)
        let delayHint = NSTextField(
            labelWithString: "Через сколько секунд запускать локальную модель, если Groq молчит")
        delayHint.frame = NSRect(x: 180, y: y + 6, width: 320, height: 16)
        delayHint.font = NSFont.systemFont(ofSize: 10)
        delayHint.textColor = .secondaryLabelColor
        content.addSubview(delayHint)
        y -= 14

        let hint = NSTextField(
            wrappingLabelWithString:
                "Хоткей записи (hold-to-talk): зажмите ⌘⌃ и говорите, отпустите — текст вставится.")
        hint.frame = NSRect(x: 20, y: y - 16, width: 460, height: 34)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 380, y: 12, width: 100, height: 30)
        content.addSubview(saveButton)

        let modelsButton = NSButton(
            title: "Папка моделей", target: self, action: #selector(openModelsFolder))
        modelsButton.bezelStyle = .rounded
        modelsButton.frame = NSRect(x: 20, y: 12, width: 130, height: 30)
        content.addSubview(modelsButton)
    }

    // MARK: - Values

    private var selectedBackend: RecognitionBackend {
        let index = max(0, backendPopup.indexOfSelectedItem)
        return RecognitionBackend.allCases[min(index, RecognitionBackend.allCases.count - 1)]
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }

    private func selectedModel() -> WhisperModelInfo {
        let idx = max(0, modelPopup.indexOfSelectedItem)
        return WhisperModelInfo.catalog[min(idx, WhisperModelInfo.catalog.count - 1)]
    }

    private func loadValues() {
        if let idx = RecognitionBackend.allCases.firstIndex(of: settings.backend) {
            backendPopup.selectItem(at: idx)
        }
        rebuildModelPopup()
        languagePopup.selectItem(withTitle: settings.language)
        promptTextView.string = settings.initialPrompt
        groqKeyField.stringValue = settings.groqApiKey
        groqModelField.stringValue = settings.groqModel
        autoPasteCheck.state = settings.autoPaste ? .on : .off
        localDelayField.stringValue = String(format: "%g", settings.localStartDelay)
        updateEnabled()
        updateModelStatus()
    }

    @objc private func backendChanged() {
        // Запоминаем несохранённый выбор Whisper перед переключением на FluidAudio.
        if modelPopup.numberOfItems == WhisperModelInfo.catalog.count {
            pendingWhisperModelID = selectedModel().id
        }
        rebuildModelPopup()
        updateEnabled()
    }

    @objc private func modelChanged() {
        if selectedBackend != .fluidAudio {
            pendingWhisperModelID = selectedModel().id
        }
        updateModelStatus()
    }

    private func rebuildModelPopup() {
        modelPopup.removeAllItems()

        if selectedBackend == .fluidAudio {
            modelPopup.addItem(
                withTitle:
                    "Parakeet TDT v3 — multilingual live (\(FluidAudioRecognizer.approxDownloadSize))"
            )
            return
        }

        for model in WhisperModelInfo.catalog {
            modelPopup.addItem(withTitle: "\(model.title) (\(model.approxSize))")
        }
        if let index = WhisperModelInfo.catalog.firstIndex(where: { $0.id == pendingWhisperModelID }
        ) {
            modelPopup.selectItem(at: index)
        }
    }

    private func updateEnabled() {
        let backend = selectedBackend
        let whisperOn = backend == .local || backend == .both
        let fluidOn = backend == .fluidAudio
        let groqOn = backend == .groq || backend == .both

        modelPopup.isEnabled = whisperOn
        downloadButton.isEnabled = whisperOn || fluidOn
        languagePopup.isEnabled = !fluidOn
        promptTextView.isEditable = whisperOn
        promptTextView.isSelectable = whisperOn
        groqKeyField.isEnabled = groqOn
        groqModelField.isEnabled = groqOn
        localDelayField.isEnabled = backend == .both
        updateModelStatus()
    }

    private func updateModelStatus() {
        if selectedBackend == .fluidAudio {
            modelStatusLabel.stringValue =
                FluidAudioRecognizer.isModelDownloaded
                ? "✓ Parakeet v3 скачана" : "Parakeet v3 не скачана"
            modelStatusLabel.textColor =
                FluidAudioRecognizer.isModelDownloaded ? .systemGreen : .systemOrange
            downloadButton.title =
                FluidAudioRecognizer.isModelDownloaded ? "Перекачать" : "Скачать"
            return
        }

        let m = selectedModel()
        if m.isDownloaded() {
            modelStatusLabel.stringValue = "✓ Скачана"
            modelStatusLabel.textColor = .systemGreen
            downloadButton.title = "Перекачать"
        } else {
            modelStatusLabel.stringValue = "Не скачана"
            modelStatusLabel.textColor = .systemOrange
            downloadButton.title = "Скачать"
        }
    }

    // MARK: - Download

    @objc private func downloadTapped() {
        if selectedBackend == .fluidAudio {
            downloadFluidAudioModel()
            return
        }

        if downloadTask != nil {
            // Отмена
            downloadTask?.cancel()
            downloadTask = nil
            downloadingModel = nil
            progressBar.isHidden = true
            updateModelStatus()
            return
        }

        let model = selectedModel()
        downloadingModel = model
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        downloadButton.title = "Отмена"
        modelStatusLabel.stringValue = "Скачивание…"
        modelStatusLabel.textColor = .secondaryLabelColor

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: model.downloadURL)
        downloadTask = task
        task.resume()
    }

    private func downloadFluidAudioModel() {
        downloadButton.isEnabled = false
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        modelStatusLabel.stringValue = "Подготовка FluidAudio…"
        modelStatusLabel.textColor = .secondaryLabelColor

        let forceDownload = FluidAudioRecognizer.isModelDownloaded
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await FluidAudioRecognizer.downloadModel(force: forceDownload) {
                    [weak self] fraction, status in
                    DispatchQueue.main.async {
                        self?.progressBar.doubleValue = fraction
                        self?.modelStatusLabel.stringValue = status
                    }
                }
                await MainActor.run {
                    self.progressBar.isHidden = true
                    self.downloadButton.isEnabled = true
                    self.updateModelStatus()
                }
            } catch {
                await MainActor.run {
                    self.progressBar.isHidden = true
                    self.downloadButton.isEnabled = true
                    self.modelStatusLabel.stringValue = "Ошибка: \(error.localizedDescription)"
                    self.modelStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    // URLSessionDownloadDelegate
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.progressBar.doubleValue = progress
            let mb = Double(totalBytesWritten) / 1_048_576
            let total = Double(totalBytesExpectedToWrite) / 1_048_576
            self?.modelStatusLabel.stringValue = String(
                format: "Скачивание… %.0f / %.0f MB", mb, total)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let model = downloadingModel else { return }
        let dest = AppSettings.modelsDirectory.appendingPathComponent(model.fileName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.modelStatusLabel.stringValue = "Ошибка сохранения"
                self?.modelStatusLabel.textColor = .systemRed
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.downloadTask = nil
            self?.downloadingModel = nil
            self?.progressBar.isHidden = true
            self?.updateModelStatus()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            DispatchQueue.main.async { [weak self] in
                self?.downloadTask = nil
                self?.downloadingModel = nil
                self?.progressBar.isHidden = true
                self?.modelStatusLabel.stringValue = "Ошибка: \(error.localizedDescription)"
                self?.modelStatusLabel.textColor = .systemRed
                self?.downloadButton.title = "Скачать"
            }
        }
    }

    // MARK: - Actions

    @objc private func openModelsFolder() {
        let directory =
            selectedBackend == .fluidAudio
            ? FluidAudioRecognizer.modelDirectory
            : AppSettings.modelsDirectory
        NSWorkspace.shared.open(directory)
    }

    @objc private func saveTapped() {
        settings.backend = selectedBackend
        settings.localModel = pendingWhisperModelID
        settings.language = languagePopup.titleOfSelectedItem ?? settings.language
        settings.initialPrompt = promptTextView.string
        settings.groqApiKey = groqKeyField.stringValue
        settings.groqModel =
            groqModelField.stringValue.isEmpty ? "whisper-large-v3" : groqModelField.stringValue
        settings.autoPaste = autoPasteCheck.state == .on
        // Задержка: парсим число (поддержка запятой как разделителя), клампим в 0…10с.
        let raw = localDelayField.stringValue.replacingOccurrences(of: ",", with: ".")
        if let v = Double(raw) {
            settings.localStartDelay = min(max(v, 0), 10)
        }
        settings.save()
        onSave(settings)
        window?.close()
    }
}
