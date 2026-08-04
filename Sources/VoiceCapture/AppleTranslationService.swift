import AppKit
import Foundation
import SwiftUI

#if canImport(Translation)
    import Translation
#endif

/// Ошибки системного Apple Translation.
enum AppleTranslationError: LocalizedError {
    case requiresMacOS15
    case unavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .requiresMacOS15:
            return "Apple Translation требует macOS 15 или новее"
        case .unavailable:
            return "Apple Translation недоступен для выбранной пары языков"
        case .emptyResult:
            return "Apple Translation вернул пустой результат"
        }
    }
}

/// AppKit-обёртка над системным Apple Translation.
///
/// Публичный API Apple выдаёт `TranslationSession` только через SwiftUI
/// `translationTask`. Поэтому сервис держит невидимый NSHostingView, прикреплённый
/// к крошечному прозрачному окну. Окно нужно держать в view hierarchy, иначе
/// translationTask не запускается и системный диалог загрузки языка не появляется.
///
/// Если языковой пакет ещё не скачан (`status != .installed`), окно временно
/// становится видимым и приложение активируется — иначе системный диалог
/// «Загрузить язык?» не смог бы показаться у accessory-приложения.
final class AppleTranslationService {
    typealias Completion = (Result<String, Error>) -> Void

    @MainActor private var hostWindow: NSWindow?

    init() {
        if #available(macOS 15.0, *) {
            Task { @MainActor [weak self] in
                self?.installTranslationHost()
            }
        }
    }

    var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Переводит русский текст на выбранный язык. Completion всегда приходит на main queue.
    func translate(
        _ text: String,
        target: TranslationTargetLanguage,
        completion: @escaping Completion
    ) {
        guard #available(macOS 15.0, *) else {
            DispatchQueue.main.async {
                completion(.failure(AppleTranslationError.requiresMacOS15))
            }
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(AppleTranslationError.emptyResult))
            }
            return
        }

        Task {
            let sourceLanguage = Locale.Language(identifier: "ru")
            let targetLanguage = Locale.Language(identifier: target.rawValue)
            let status = await LanguageAvailability().status(
                from: sourceLanguage, to: targetLanguage)

            guard status != .unsupported else {
                NSLog("[Translation] пара ru → \(target.rawValue) не поддерживается")
                await MainActor.run {
                    completion(.failure(AppleTranslationError.unavailable))
                }
                return
            }

            // .supported означает «доступен, но пакет не скачан» — нужен видимый
            // системный диалог загрузки.
            let requiresDownload = status != .installed
            if requiresDownload {
                NSLog(
                    "[Translation] языковой пакет ru → \(target.rawValue) не установлен, "
                        + "показываем диалог загрузки")
            }

            await MainActor.run {
                AppleTranslationBridgeModel.shared.enqueue(
                    text: text,
                    targetIdentifier: target.rawValue,
                    requiresDownload: requiresDownload,
                    completion: completion
                )
            }
        }
    }

    @available(macOS 15.0, *)
    @MainActor
    private func installTranslationHost() {
        let host = NSHostingView(rootView: AppleTranslationBridgeView())
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        host.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: Self.hiddenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = host
        // translationTask выполняется только у view, реально прикреплённого к окну.
        window.orderFrontRegardless()
        hostWindow = window

        AppleTranslationBridgeModel.shared.presenter = { [weak self] visible in
            self?.setHostVisible(visible)
        }
    }

    private static let hiddenFrame = NSRect(x: -10_000, y: -10_000, width: 1, height: 1)
    private static let downloadFrame = NSSize(width: 330, height: 130)

    @MainActor
    private func setHostVisible(_ visible: Bool) {
        guard let window = hostWindow else { return }

        guard visible else {
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.level = .normal
            window.setFrame(Self.hiddenFrame, display: false)
            window.orderFrontRegardless()
            return
        }

        let size = Self.downloadFrame
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrame(
                NSRect(
                    x: area.midX - size.width / 2,
                    y: area.midY - size.height / 2,
                    width: size.width,
                    height: size.height),
                display: true)
        }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.hasShadow = true
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        // Без активации системный диалог загрузки языка не выйдет на передний план.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI Translation bridge (macOS 15+)

@available(macOS 15.0, *)
@MainActor
private final class AppleTranslationBridgeModel: ObservableObject {
    struct Request {
        let id: UUID
        let text: String
        let targetIdentifier: String
        let requiresDownload: Bool
        let completion: AppleTranslationService.Completion
    }

    static let shared = AppleTranslationBridgeModel()

    /// Вызывается, когда нужно показать/скрыть окно-хост (загрузка языкового пакета).
    var presenter: ((Bool) -> Void)?

    @Published private(set) var current: Request?
    private var queue: [Request] = []

    func enqueue(
        text: String,
        targetIdentifier: String,
        requiresDownload: Bool,
        completion: @escaping AppleTranslationService.Completion
    ) {
        queue.append(
            Request(
                id: UUID(), text: text, targetIdentifier: targetIdentifier,
                requiresDownload: requiresDownload, completion: completion)
        )
        startNextIfNeeded()
    }

    func finish(_ result: Result<String, Error>, requestID: UUID) {
        guard let request = current, request.id == requestID else { return }
        current = nil
        if request.requiresDownload { presenter?(false) }
        request.completion(result)
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard current == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        current = request
        if request.requiresDownload { presenter?(true) }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationBridgeView: View {
    @ObservedObject private var model = AppleTranslationBridgeModel.shared
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        content
            .onChange(of: model.current?.id) { _, _ in
                guard let request = model.current else { return }
                let source = Locale.Language(identifier: "ru")
                let target = Locale.Language(identifier: request.targetIdentifier)

                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: source, target: target)
                } else {
                    // invalidate() заставляет translationTask выдать новую сессию
                    // даже при повторном переводе на тот же язык.
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { session in
                guard let request = await MainActor.run(body: { model.current }) else { return }

                do {
                    // Если языковой пакет ещё не установлен, macOS покажет системный
                    // диалог загрузки. После подтверждения выполнение продолжится.
                    try await session.prepareTranslation()
                    let response = try await session.translate(request.text)
                    let translated = response.targetText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    guard !translated.isEmpty else {
                        throw AppleTranslationError.emptyResult
                    }
                    await MainActor.run {
                        model.finish(.success(translated), requestID: request.id)
                    }
                } catch {
                    await MainActor.run {
                        model.finish(.failure(error), requestID: request.id)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.current?.requiresDownload == true {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Подготовка языка перевода")
                    .font(.system(size: 13, weight: .semibold))
                Text("Подтвердите загрузку языкового пакета в системном окне.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
