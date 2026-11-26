import AppKit
import Foundation

/// Self-updater backed by GitHub Releases.
///
/// - Checks `releases/latest` once a day (and on demand from the menu).
/// - Shows a window with the release notes («Что нового»).
/// - «Обновить и перезапустить»: downloads the ZIP asset, unpacks it, verifies the bundle,
///   then a detached shell script waits for this process to exit, swaps the .app in place
///   and launches the new version. No dragging, no «application is running» dialog.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let tag: String
        let notes: String
        let assetURL: URL
        let pageURL: URL
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    private static let apiURL = URL(
        string: "https://api.github.com/repos/oiv-an/voice-capture-mac/releases/latest")!
    private static let bundleID = "com.ivol.voicecapture"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "UpdaterLastCheck"
    private static let skippedKey = "UpdaterSkippedVersion"
    private static let announcedKey = "UpdaterAnnouncedVersion"

    /// Newer release found by the last check; the menu shows an item for it.
    private(set) var available: Release?
    private var timer: Timer?
    private var window: UpdateWindowController?
    private var checking = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Scheduling

    func start() {
        NSLog("[Updater] Автопроверка включена (версия %@)", Self.currentVersion)
        // First check shortly after launch, then hourly ticks that respect the 24 h interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkIfDue()
        }
        let t = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.checkInterval else {
            NSLog("[Updater] Проверка не нужна: прошло меньше суток")
            return
        }
        check(userInitiated: false)
    }

    /// `userInitiated`: from the menu — always shows a result, ignores «skip this version».
    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        NSLog("[Updater] Проверка обновлений…")
        Task {
            defer { checking = false }
            do {
                let release = try await Self.fetchLatest()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                guard Self.isNewer(release.version, than: Self.currentVersion) else {
                    NSLog("[Updater] Обновлений нет (последняя %@)", release.version)
                    available = nil
                    if userInitiated { showUpToDate() }
                    return
                }
                available = release
                NSLog(
                    "[Updater] Доступна версия %@ (установлена %@)", release.version,
                    Self.currentVersion)
                let defaults = UserDefaults.standard
                if userInitiated {
                    showWindow(for: release)
                } else if defaults.string(forKey: Self.skippedKey) != release.version,
                    defaults.string(forKey: Self.announcedKey) != release.version
                {
                    // Pop up once per version automatically; afterwards the menu item stays.
                    defaults.set(release.version, forKey: Self.announcedKey)
                    showWindow(for: release)
                }
            } catch {
                NSLog("[Updater] Проверка: %@", error.localizedDescription)
                if userInitiated { showError(error) }
            }
        }
    }

    func showAvailable() {
        if let available { showWindow(for: available) } else { check(userInitiated: true) }
    }

    // MARK: - GitHub

    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceCapture/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message(
                "GitHub ответил кодом \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
            let assets = json["assets"] as? [[String: Any]]
        else { throw UpdateError.message("Не удалось разобрать ответ GitHub") }

        let asset = assets.first {
            ($0["name"] as? String)?.hasSuffix("-macOS-arm64.zip") == true
        }
        guard let urlString = asset?["browser_download_url"] as? String,
            let assetURL = URL(string: urlString)
        else { throw UpdateError.message("В релизе \(tag) нет архива приложения") }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(
            version: version, tag: tag, notes: json["body"] as? String ?? "",
            assetURL: assetURL, pageURL: page)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a)
        let y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Install

    /// Downloads, unpacks and verifies the new bundle, then hands over to the swap script.
    /// Returns only on failure; on success the app terminates.
    func install(_ release: Release, progress: @escaping (String) -> Void) async throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw UpdateError.message("Приложение запущено не из .app — обновите вручную")
        }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.message(
                "Нет прав на запись в \(parent.path). Скачайте релиз вручную.")
        }

        progress("Скачивание \(release.version)…")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCaptureUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, response) = try await URLSession.shared.download(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message(
                "Скачивание не удалось (код \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        progress("Распаковка…")
        let unpacked = work.appendingPathComponent("unpacked")
        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent("VoiceCapture.app")
        guard
            let info = NSDictionary(
                contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
            info["CFBundleIdentifier"] as? String == Self.bundleID,
            info["CFBundleShortVersionString"] as? String == release.version
        else { throw UpdateError.message("Архив не прошёл проверку (bundle id / версия)") }
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        progress("Перезапуск…")
        try Self.launchSwapScript(newApp: newApp, target: target, work: work)
        NotificationCenter.default.post(name: Self.willRelaunch, object: nil)
        if NSApplication.shared.isRunning { NSApp.terminate(nil) } else { exit(0) }
    }

    static let willRelaunch = Notification.Name("VoiceCaptureUpdaterWillRelaunch")

    /// Detached script: waits for our PID to exit, swaps bundles (rolls back on failure), relaunches.
    private static func launchSwapScript(newApp: URL, target: URL, work: URL) throws {
        let script = """
            #!/bin/sh
            PID=\(ProcessInfo.processInfo.processIdentifier)
            NEW=\(shellQuote(newApp.path))
            DEST=\(shellQuote(target.path))
            WORK=\(shellQuote(work.path))
            i=0
            while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
            kill -9 "$PID" 2>/dev/null
            rm -rf "$DEST.old"
            if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then
              rm -rf "$DEST.old"
            else
              rm -rf "$DEST"; mv "$DEST.old" "$DEST"
            fi
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            /usr/bin/open "$DEST"
            rm -rf "$WORK"
            """
        let scriptURL = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // nohup + background: the script is reparented to launchd and survives our exit.
        try run("/bin/sh", ["-c", "nohup /bin/sh \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &"])
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.message("\(tool) завершился с кодом \(p.terminationStatus)")
        }
        return p.terminationStatus
    }

    // MARK: - UI

    private func showWindow(for release: Release) {
        if window == nil {
            window = UpdateWindowController()
        }
        window?.present(
            release: release, current: Self.currentVersion,
            onInstall: { [weak self] in self?.startInstall(release) },
            onSkip: { [weak self] in
                UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
                self?.window?.close()
            },
            onLater: { [weak self] in self?.window?.close() })
    }

    private func startInstall(_ release: Release) {
        window?.setBusy(true, status: "Подготовка…")
        Task {
            do {
                try await install(release) { [weak self] status in
                    self?.window?.setBusy(true, status: status)
                }
            } catch {
                window?.setBusy(false, status: "Ошибка: \(error.localizedDescription)")
            }
        }
    }

    private func showUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Установлена последняя версия"
        alert.informativeText = "VoiceCapture \(Self.currentVersion) — обновлений нет."
        alert.runModal()
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Не удалось проверить обновления"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// «Доступно обновление»: version line, release notes, install / later / skip.
@MainActor
final class UpdateWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let notesView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let installButton = NSButton(
        title: "Обновить и перезапустить", target: nil, action: nil)
    private let laterButton = NSButton(title: "Позже", target: nil, action: nil)
    private let skipButton = NSButton(title: "Пропустить версию", target: nil, action: nil)
    private var onInstall: (() -> Void)?
    private var onSkip: (() -> Void)?
    private var onLater: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Обновление VoiceCapture"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        build(in: window.contentView!)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(in content: NSView) {
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 412, width: 520, height: 26)
        content.addSubview(titleLabel)

        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 20, y: 390, width: 520, height: 18)
        content.addSubview(subtitleLabel)

        let whatsNew = NSTextField(labelWithString: "Что нового:")
        whatsNew.font = .systemFont(ofSize: 13, weight: .medium)
        whatsNew.frame = NSRect(x: 20, y: 362, width: 520, height: 18)
        content.addSubview(whatsNew)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 80, width: 520, height: 276))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesView.autoresizingMask = [.width]
        notesView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = notesView
        content.addSubview(scroll)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 20, y: 52, width: 16, height: 16)
        content.addSubview(spinner)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 42, y: 51, width: 498, height: 18)
        content.addSubview(statusLabel)

        skipButton.frame = NSRect(x: 14, y: 12, width: 170, height: 32)
        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        content.addSubview(skipButton)

        laterButton.frame = NSRect(x: 254, y: 12, width: 90, height: 32)
        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(laterTapped)
        content.addSubview(laterButton)

        installButton.frame = NSRect(x: 346, y: 12, width: 200, height: 32)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.target = self
        installButton.action = #selector(installTapped)
        content.addSubview(installButton)
    }

    func present(
        release: Updater.Release, current: String,
        onInstall: @escaping () -> Void, onSkip: @escaping () -> Void, onLater: @escaping () -> Void
    ) {
        self.onInstall = onInstall
        self.onSkip = onSkip
        self.onLater = onLater
        titleLabel.stringValue = "Доступна новая версия VoiceCapture \(release.version)"
        subtitleLabel.stringValue = "У вас установлена версия \(current)."
        notesView.textStorage?.setAttributedString(Self.render(release.notes))
        notesView.scrollToBeginningOfDocument(nil)
        setBusy(false, status: "")
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func setBusy(_ busy: Bool, status: String) {
        statusLabel.stringValue = status
        installButton.isEnabled = !busy
        laterButton.isEnabled = !busy
        skipButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Release notes are Markdown: render inline syntax, keep line structure, drop heading marks.
    private static func render(_ markdown: String) -> NSAttributedString {
        let body = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13)
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine
            var font = baseFont
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(match)
                font = .systemFont(ofSize: 14, weight: .semibold)
            } else if let match = line.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
                line.replaceSubrange(match, with: "•  ")
            }
            let rendered: NSMutableAttributedString
            if let attributed = try? AttributedString(
                markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            {
                rendered = NSMutableAttributedString(attributed)
            } else {
                rendered = NSMutableAttributedString(string: line)
            }
            let range = NSRange(location: 0, length: rendered.length)
            rendered.addAttribute(.font, value: font, range: range)
            rendered.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            body.append(rendered)
            body.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
        }
        return body
    }

    @objc private func installTapped() { onInstall?() }
    @objc private func laterTapped() { onLater?() }
    @objc private func skipTapped() { onSkip?() }
}
