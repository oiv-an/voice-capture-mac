import AppKit

/// Маленькое плавающее окно-индикатор: показывает состояние (запись / обработка / результат).
final class StatusController {
    enum State {
        case idle
        case recording
        case liveText(String)
        case processing
        case translating(String)
        case done(String)
        case error(String)
    }

    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "")
    private let liveTextView = NSTextView(frame: .zero)
    private let dot = NSView()
    private let languageBadge = NSTextField(labelWithString: "")
    private var translationBadge: String?
    private var currentState: State = .idle
    private var hideTimer: Timer?

    func show(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.render(state)
        }
    }

    /// Показывает/скрывает целевой язык вместо красной точки во время записи.
    func setTranslationBadge(_ badge: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.translationBadge = badge
            self.updateRecordingIndicator()
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let container = NSView(frame: w.contentView!.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 14
        container.autoresizingMask = [.width, .height]

        dot.frame = NSRect(x: 18, y: 26, width: 12, height: 12)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        container.addSubview(dot)

        languageBadge.frame = NSRect(x: 10, y: 21, width: 30, height: 22)
        languageBadge.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        languageBadge.textColor = .white
        languageBadge.alignment = .center
        languageBadge.wantsLayer = true
        languageBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        languageBadge.layer?.cornerRadius = 6
        languageBadge.isHidden = true
        container.addSubview(languageBadge)

        label.frame = NSRect(x: 42, y: 22, width: 262, height: 20)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        container.addSubview(label)

        liveTextView.isEditable = false
        liveTextView.isSelectable = false
        liveTextView.drawsBackground = false
        liveTextView.textColor = .white
        liveTextView.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        liveTextView.textContainerInset = .zero
        liveTextView.textContainer?.lineFragmentPadding = 0
        liveTextView.textContainer?.lineBreakMode = .byWordWrapping
        liveTextView.textContainer?.widthTracksTextView = true
        liveTextView.isHorizontallyResizable = false
        liveTextView.isVerticallyResizable = true
        liveTextView.isHidden = true
        container.addSubview(liveTextView)

        w.contentView?.addSubview(container)
        self.window = w
    }

    private func position() {
        guard let w = window, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - w.frame.width / 2
        let y = frame.minY + 80
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func setWindowSize(width: CGFloat, height: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    private func applyCompactLayout() {
        liveTextView.isHidden = true
        label.isHidden = false

        setWindowSize(width: 320, height: 64)
        label.frame = NSRect(x: 42, y: 22, width: 262, height: 20)
        dot.frame.origin.y = 26
    }

    private func applyLiveTextLayout(_ text: String) {
        let windowWidth: CGFloat = 620
        let horizontalTextInset: CGFloat = 42
        let rightInset: CGFloat = 16
        let verticalInset: CGFloat = 14
        let minimumWindowHeight: CGFloat = 64
        let textWidth = windowWidth - horizontalTextInset - rightInset
        let displayedText = text.isEmpty ? "Слушаю…" : text

        label.isHidden = true
        liveTextView.isHidden = false
        liveTextView.string = displayedText
        liveTextView.frame = NSRect(
            x: horizontalTextInset,
            y: verticalInset,
            width: textWidth,
            height: 20
        )

        guard let textContainer = liveTextView.textContainer,
            let layoutManager = liveTextView.layoutManager
        else { return }

        textContainer.containerSize = NSSize(
            width: textWidth,
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let measuredTextHeight = max(
            ceil(layoutManager.usedRect(for: textContainer).height),
            20
        )

        // Ограничения по высоте нет: окно всегда вмещает весь распознанный текст.
        let windowHeight = max(
            minimumWindowHeight,
            measuredTextHeight + verticalInset * 2
        )
        let textHeight = measuredTextHeight

        setWindowSize(width: windowWidth, height: windowHeight)
        liveTextView.frame = NSRect(
            x: horizontalTextInset,
            y: windowHeight - verticalInset - textHeight,
            width: textWidth,
            height: textHeight
        )

        // Точка остаётся у первой строки, когда окно становится многострочным.
        dot.frame.origin.y = liveTextView.frame.maxY - 16
    }

    private func updateRecordingIndicator() {
        ensureWindow()
        let recordingLike: Bool
        switch currentState {
        case .recording, .liveText:
            recordingLike = true
        default:
            recordingLike = false
        }

        guard recordingLike, let badge = translationBadge else {
            languageBadge.isHidden = true
            dot.isHidden = false
            return
        }

        dot.isHidden = true
        languageBadge.stringValue = badge
        languageBadge.isHidden = false
        if case .liveText = currentState {
            languageBadge.frame.origin.y = dot.frame.origin.y - 5
        } else {
            languageBadge.frame.origin.y = 21
        }
    }

    private func render(_ state: State) {
        ensureWindow()
        currentState = state
        hideTimer?.invalidate()

        switch state {
        case .idle:
            window?.orderOut(nil)
            return
        case .recording:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            label.stringValue = "Запись… (отпустите клавиши)"
        case .liveText:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .processing:
            dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            label.stringValue = "Распознавание…"
        case .translating(let language):
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            label.stringValue = "Перевод на \(language)…"
        case .done(let text):
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
            label.stringValue = preview.isEmpty ? "Готово (пусто)" : preview
            scheduleHide(after: 2.0)
        case .error(let msg):
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            label.stringValue = msg
            scheduleHide(after: 4.0)
        }

        if case .liveText(let text) = state {
            applyLiveTextLayout(text)
        } else {
            applyCompactLayout()
        }

        updateRecordingIndicator()
        position()
        window?.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
            [weak self] _ in
            self?.window?.orderOut(nil)
        }
    }
}
