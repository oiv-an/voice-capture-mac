import AppKit

/// Маленькое плавающее окно-индикатор: показывает состояние (запись / обработка / результат).
final class StatusController {
    enum State {
        case idle
        case recording
        case liveText(String)
        case processing
        case done(String)
        case error(String)
    }

    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var hideTimer: Timer?

    func show(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.render(state)
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 64),
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

        // Точка-индикатор: вертикальный центр окна (64/2=32, минус половина высоты точки=6).
        dot.frame = NSRect(x: 18, y: 26, width: 12, height: 12)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        container.addSubview(dot)

        // Текст: одна строка по центру окна по вертикали. Ширины хватает для live-транскрипта.
        label.frame = NSRect(x: 42, y: 22, width: 562, height: 20)
        label.autoresizingMask = [.width]
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        container.addSubview(label)

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

    private func setWindowWidth(_ width: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        label.frame.size.width = width - 58
    }

    private func render(_ state: State) {
        ensureWindow()
        hideTimer?.invalidate()

        // Широкая плашка нужна только для FluidAudio live-текста.
        // Обычные Recording/Processing/Error остаются компактными, как раньше.
        switch state {
        case .liveText:
            setWindowWidth(620)
        default:
            setWindowWidth(320)
        }

        switch state {
        case .idle:
            window?.orderOut(nil)
            return
        case .recording:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            label.stringValue = "Запись… (отпустите клавиши)"
        case .liveText(let text):
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            label.stringValue = text.isEmpty ? "Слушаю…" : text
        case .processing:
            dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            label.stringValue = "Распознавание…"
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
