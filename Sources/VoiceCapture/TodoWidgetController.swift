import AppKit

/// Панель, которая может принимать ввод (редактирование задач), не активируя приложение.
final class TodoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Круглая «шайба»: перетаскивается мышью, позиция запоминается.
final class PuckView: NSView {
    var onDragEnded: () -> Void = {}
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, let o = windowStart else { return }
        let p = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: o.x + p.x - s.x, y: o.y + p.y - s.y))
    }

    override func mouseUp(with event: NSEvent) {
        // Сохраняем позицию только при реальном перемещении, а не при простом клике.
        if let o = windowStart, let cur = window?.frame.origin,
            hypot(cur.x - o.x, cur.y - o.y) > 1
        {
            onDragEnded()
        }
        dragStart = nil
        windowStart = nil
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Плавающий виджет «Текущие дела»: полупрозрачная шайба поверх всех окон,
/// при наведении разворачивается в список. Галочка → задача зачёркнута, через 5 с удаляется
/// (снятие галочки в эти 5 с — отмена). Клик по тексту — редактирование, Enter — сохранить.
/// Отрисовка списка — в TodoWidgetController+List.swift.
final class TodoWidgetController: NSObject, NSTextFieldDelegate {
    let store = TodoStore.shared
    let puckSize: CGFloat = 40
    let panelWidth: CGFloat = 360
    let completeDelay: TimeInterval = 5

    var panel: TodoPanel!
    let root = NSView()
    let puck = PuckView()
    let countLabel = NSTextField(labelWithString: "0")
    /// Фон развёрнутого списка тоже перетаскиваемый (шайба в развёрнутом виде скрыта).
    let listContainer = PuckView()
    let scrollView = NSScrollView()
    let docView = FlippedView()

    var expanded = false
    var collapseWork: DispatchWorkItem?
    /// Задачи, отмеченные галочкой и ожидающие удаления.
    var pending: [UUID: DispatchWorkItem] = [:]
    var editingID: UUID?
    /// Смещение сохранённой позиции шайбы относительно origin развёрнутой панели.
    var puckOffsetInPanel: NSPoint = .zero

    static let originKey = "TodoWidgetOrigin"

    func show() {
        if panel == nil {
            build()
            startHoverPolling()
            NotificationCenter.default.addObserver(
                self, selector: #selector(storeChanged), name: TodoStore.didChange, object: nil)
        }
        refresh()
        panel.orderFrontRegardless()
    }

    func hide() {
        expanded = false
        collapseWork?.cancel()
        collapseWork = nil
        panel?.orderOut(nil)
    }

    @objc func storeChanged() {
        // Не пересобираем строки посреди редактирования — иначе пропадёт поле ввода.
        guard editingID == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func build() {
        let p = TodoPanel(
            contentRect: NSRect(
                origin: savedOrigin(), size: NSSize(width: puckSize, height: puckSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel = p

        root.frame = p.contentView!.bounds
        root.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(root)

        puck.frame = NSRect(x: 0, y: 0, width: puckSize, height: puckSize)
        puck.wantsLayer = true
        puck.layer?.cornerRadius = puckSize / 2
        puck.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.55).cgColor
        puck.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
        puck.layer?.borderWidth = 1
        puck.onDragEnded = { [weak self] in self?.saveOrigin() }
        countLabel.frame = NSRect(x: 0, y: 11, width: puckSize, height: 18)
        countLabel.alignment = .center
        countLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        countLabel.textColor = .white
        puck.addSubview(countLabel)
        root.addSubview(puck)

        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        listContainer.layer?.cornerRadius = 14
        listContainer.isHidden = true
        listContainer.onDragEnded = { [weak self] in self?.saveOrigin() }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = docView
        listContainer.addSubview(scrollView)
        root.addSubview(listContainer)

        root.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    // MARK: - Position

    func savedOrigin() -> NSPoint {
        let fallbackScreen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        guard let s = UserDefaults.standard.string(forKey: Self.originKey) else {
            let f = NSScreen.main?.visibleFrame ?? fallbackScreen
            return NSPoint(x: f.maxX - puckSize - 16, y: f.maxY - puckSize - 16)
        }
        let p = NSPointFromString(s)
        // Если шайбу затащили частично за край — не сбрасываем, а прижимаем к краю экрана.
        let center = NSPoint(x: p.x + puckSize / 2, y: p.y + puckSize / 2)
        let screen =
            NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
            ?? NSScreen.screens.min(by: {
                hypot($0.frame.midX - center.x, $0.frame.midY - center.y)
                    < hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
            })?.frame ?? fallbackScreen
        return NSPoint(
            x: min(max(p.x, screen.minX), screen.maxX - puckSize),
            y: min(max(p.y, screen.minY), screen.maxY - puckSize))
    }

    /// Сохраняет позицию шайбы. В развёрнутом виде позиция шайбы = origin панели + смещение,
    /// запомненное в момент раскрытия (панель может раскрыться в любую сторону).
    func saveOrigin() {
        let f = panel.frame
        let p =
            expanded
            ? NSPoint(x: f.origin.x + puckOffsetInPanel.x, y: f.origin.y + puckOffsetInPanel.y)
            : f.origin
        UserDefaults.standard.set(NSStringFromPoint(p), forKey: Self.originKey)
    }

    /// Точка шайбы (левый нижний угол в свёрнутом виде) — якорь для развёрнутого окна.
    var puckOrigin: NSPoint { savedOrigin() }

    // MARK: - Hover

    // Явные ObjC-селекторы: без них Swift генерирует `mouseEnteredWith:`,
    // а AppKit шлёт владельцу NSTrackingArea именно `mouseEntered:`.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        expandIfNeeded()
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        scheduleCollapse()
    }

    func expandIfNeeded() {
        guard panel?.isVisible == true else { return }
        collapseWork?.cancel()
        collapseWork = nil
        guard !expanded else { return }
        if UserDefaults.standard.string(forKey: Self.originKey) == nil { saveOrigin() }
        expanded = true
        refresh()
    }

    /// Резервный опрос мыши (tracking area у неактивного accessory-приложения бывает капризной).
    func startHoverPolling() {
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            if NSEvent.pressedMouseButtons != 0 { return }  // не мешаем перетаскиванию
            let inside = panel.frame.contains(NSEvent.mouseLocation)
            if inside && !self.expanded {
                self.expandIfNeeded()
            } else if !inside && self.expanded && self.collapseWork == nil {
                self.scheduleCollapse()
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.collapseWork = nil
            guard self.expanded else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            if self.editingID != nil { return }  // не сворачиваем посреди редактирования
            self.expanded = false
            self.refresh()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
