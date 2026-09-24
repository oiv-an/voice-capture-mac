import AppKit

/// Отрисовка и логика строк списка дел.
extension TodoWidgetController {
    private var rowFont: NSFont { NSFont.systemFont(ofSize: 14, weight: .medium) }

    func refresh() {
        guard panel != nil else { return }
        let items = store.items
        let active = items.filter { pending[$0.id] == nil }.count
        countLabel.stringValue = active > 0 ? "\(active)" : "✓"
        countLabel.textColor = active > 0 ? .white : NSColor(calibratedWhite: 1, alpha: 0.6)

        guard expanded else {
            listContainer.isHidden = true
            puck.isHidden = false
            // Возвращаем шайбу ровно туда, где пользователь её оставил.
            let o = savedOrigin()
            panel.setFrame(
                NSRect(x: o.x, y: o.y, width: puckSize, height: puckSize), display: true)
            puck.frame = NSRect(x: 0, y: 0, width: puckSize, height: puckSize)
            return
        }

        // --- Строки ---
        docView.subviews.forEach { $0.removeFromSuperview() }
        let pad: CGFloat = 14
        let checkWidth: CGFloat = 22
        let textX = pad + checkWidth + 6
        let textWidth = panelWidth - textX - pad
        var y: CGFloat = 0

        let header = NSTextField(labelWithString: "Текущие дела · \(active)")
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = NSColor(calibratedWhite: 1, alpha: 0.6)
        header.frame = NSRect(x: pad, y: y, width: panelWidth - pad * 2, height: 18)
        docView.addSubview(header)
        y += 26

        if items.isEmpty {
            let empty = NSTextField(
                labelWithString: "Пусто. Зажми хоткей + ⇧ и продиктуй задачу.")
            empty.font = rowFont
            empty.textColor = NSColor(calibratedWhite: 1, alpha: 0.7)
            empty.frame = NSRect(x: pad, y: y, width: panelWidth - pad * 2, height: 20)
            docView.addSubview(empty)
            y += 28
        }

        for item in items {
            let isPending = pending[item.id] != nil
            let field = NSTextField(string: item.text)
            field.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            field.font = rowFont
            field.textColor = .white
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.isEditable = !isPending
            field.isSelectable = !isPending
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
            field.delegate = self
            if isPending {
                field.attributedStringValue = NSAttributedString(
                    string: item.text,
                    attributes: [
                        .font: rowFont,
                        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.4),
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: NSColor(calibratedWhite: 1, alpha: 0.6),
                    ])
            }
            let measured =
                field.cell?.cellSize(
                    forBounds: NSRect(
                        x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
                ).height ?? 20
            let h = max(20, ceil(measured))
            field.frame = NSRect(x: textX, y: y, width: textWidth, height: h)
            docView.addSubview(field)

            let check = NSButton(
                checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            check.state = isPending ? .on : .off
            check.frame = NSRect(x: pad, y: y + 1, width: checkWidth, height: 18)
            docView.addSubview(check)

            y += h + 10
        }

        // --- Размер окна: раскрываемся в сторону центра экрана от шайбы ---
        let contentHeight = y + 4
        let o = savedOrigin()
        let center = NSPoint(x: o.x + puckSize / 2, y: o.y + puckSize / 2)
        let screen =
            NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let maxHeight = min(520, vis.height - 20)
        let height = min(contentHeight + pad * 2, maxHeight)

        // Шайба в левой половине → раскрываемся вправо, в правой → влево.
        // Шайба в верхней половине → вниз, в нижней → вверх.
        let x = center.x < vis.midX ? o.x : o.x + puckSize - panelWidth
        let yOrigin = center.y > vis.midY ? o.y + puckSize - height : o.y
        var frame = NSRect(x: x, y: yOrigin, width: panelWidth, height: height)
        frame.origin.x = min(max(frame.origin.x, vis.minX + 4), vis.maxX - panelWidth - 4)
        frame.origin.y = min(max(frame.origin.y, vis.minY + 4), vis.maxY - height - 4)
        panel.setFrame(frame, display: true)
        // Запоминаем, где шайба относительно панели: перетаскивание развёрнутой панели
        // сдвигает шайбу на тот же вектор, а просто hover/сворачивание её не трогает.
        puckOffsetInPanel = NSPoint(x: o.x - frame.origin.x, y: o.y - frame.origin.y)

        puck.isHidden = true
        listContainer.isHidden = false
        listContainer.frame = root.bounds
        scrollView.frame = NSRect(
            x: 0, y: pad, width: panelWidth, height: height - pad * 2)
        docView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: contentHeight)
    }

    // MARK: - Галочка: 5 секунд на отмену

    @objc func checkToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if sender.state == .on {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pending[id] = nil
                self.store.remove(id: id)
            }
            pending[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + completeDelay, execute: work)
        } else {
            pending[id]?.cancel()
            pending[id] = nil
        }
        refresh()
    }

    // MARK: - Редактирование

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let raw = f.identifier?.rawValue else { return }
        editingID = UUID(uuidString: raw)
        collapseWork?.cancel()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let raw = f.identifier?.rawValue,
            let id = UUID(uuidString: raw)
        else { return }
        editingID = nil
        store.update(id: id, text: f.stringValue)
        panel.makeFirstResponder(nil)
        refresh()
        scheduleCollapse()
    }

    /// Enter — сохранить, Esc — отменить правку.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            panel.makeFirstResponder(nil)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if let raw = control.identifier?.rawValue, let id = UUID(uuidString: raw),
                let item = store.items.first(where: { $0.id == id })
            {
                control.stringValue = item.text
            }
            panel.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
