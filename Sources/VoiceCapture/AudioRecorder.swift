import AVFoundation
import Foundation

/// Устройство ввода (микрофон) в системе.
struct AudioInputDevice {
    let uid: String
    let name: String
}

/// Записывает аудио с микрофона и возвращает массив Float (16kHz, mono),
/// готовый для whisper.cpp и для упаковки в WAV для Groq.
///
/// Реализация на `AVCaptureSession`, а НЕ на `AVAudioEngine`. Причина:
/// `AVAudioEngine.inputNode` жёстко привязан к системному устройству по умолчанию.
/// Любая попытка сменить его (`auAudioUnit.setDeviceID` или `AudioUnitSetProperty`
/// с `kAudioOutputUnitProperty_CurrentDevice`) валит граф с ошибкой -10868
/// (`AUGraphParser::InitializeActiveNodesInInputChain`). Дополнительно, когда
/// системный вход — Bluetooth-гарнитура, macOS подставляет агрегатное устройство
/// `CADefaultDeviceAggregate-*`, и tap вообще не получает буферов.
///
/// `AVCaptureSession` + `AVCaptureDeviceInput` работает с любым устройством явно
/// и сам конвертирует поток в нужный формат (16 kHz mono Float32),
/// поэтому `AVAudioConverter` больше не нужен.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var capturedSamples: [Float] = []
    private let sampleQueue = DispatchQueue(label: "audio.recorder.samples")
    private let captureQueue = DispatchQueue(label: "audio.recorder.capture")
    private(set) var isRecording = false

    /// UID выбранного микрофона. Пусто = системный по умолчанию.
    var microphoneUID: String = ""

    /// Счётчик полученных буферов — если 0, значит устройство не отдало данных.
    private var bufferCount = 0

    static let targetSampleRate: Double = 16000

    /// Служебные агрегатные устройства macOS — в UI не показываем.
    private static func isSystemAggregate(_ uid: String) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate")
    }

    /// Запросить доступ к микрофону (вызывать заранее).
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Устройства ввода

    private static func discoverDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.filter { !isSystemAggregate($0.uniqueID) }
    }

    /// Список доступных микрофонов для UI.
    static func availableInputDevices() -> [AudioInputDevice] {
        discoverDevices().map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Имя системного микрофона по умолчанию (для подписи в UI).
    static func defaultInputDeviceName() -> String? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        // Если система отдала агрегат (обычно при Bluetooth-гарнитуре),
        // показываем его реальное имя не получится — отдаём nil, подпись будет общей.
        if isSystemAggregate(device.uniqueID) { return nil }
        return device.localizedName
    }

    /// Устройство, с которого будем писать: выбранное в настройках либо системное.
    private func resolveDevice() -> AVCaptureDevice? {
        if !microphoneUID.isEmpty {
            if let device = AudioRecorder.discoverDevices().first(where: {
                $0.uniqueID == microphoneUID
            }) {
                return device
            }
            NSLog(
                "[Audio] Микрофон с UID \(microphoneUID) не найден — используем системный по умолчанию"
            )
        }
        // Фолбэк: системный по умолчанию. Если это агрегат, берём первый реальный вход,
        // т.к. агрегатное устройство macOS часто не отдаёт буферов.
        if let device = AVCaptureDevice.default(for: .audio),
            !AudioRecorder.isSystemAggregate(device.uniqueID)
        {
            return device
        }
        return AudioRecorder.discoverDevices().first
    }

    // MARK: - Запись

    func start() -> Bool {
        guard !isRecording else { return false }

        sampleQueue.sync { capturedSamples.removeAll(keepingCapacity: true) }
        bufferCount = 0

        guard let device = resolveDevice() else {
            NSLog("[Audio] Не найдено ни одного устройства ввода")
            return false
        }

        let session = AVCaptureSession()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                NSLog("[Audio] Нельзя добавить вход \(device.localizedName)")
                return false
            }
            session.addInput(input)
        } catch {
            NSLog("[Audio] Ошибка входа \(device.localizedName): \(error.localizedDescription)")
            return false
        }

        // AVCaptureAudioDataOutput сам ресемплит в нужный формат.
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            NSLog("[Audio] Нельзя добавить аудио-выход")
            return false
        }
        session.addOutput(output)

        session.startRunning()
        guard session.isRunning else {
            NSLog("[Audio] Сессия захвата не запустилась")
            return false
        }

        self.session = session
        isRecording = true
        NSLog("[Audio] Запись началась. Микрофон: \(device.localizedName)")
        return true
    }

    /// Останавливает запись и возвращает накопленные сэмплы (16kHz mono float).
    /// Сэмплы нормализуются по громкости (auto-gain), т.к. тихий вход заставляет whisper галлюцинировать.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        session?.stopRunning()
        session = nil
        isRecording = false

        var result = sampleQueue.sync { capturedSamples }
        let (rms, peak) = AudioRecorder.levels(result)
        result = AudioRecorder.normalize(result, peak: peak)
        NSLog(
            "[Audio] Запись остановлена, сэмплов: \(result.count) (~\(String(format: "%.1f", Double(result.count) / AudioRecorder.targetSampleRate)) c) RMS=\(String(format: "%.4f", rms)) Peak=\(String(format: "%.3f", peak)) буферов=\(bufferCount)"
        )
        if bufferCount == 0 {
            NSLog(
                "[Audio] ВНИМАНИЕ: устройство не отдало ни одного буфера. Проверь доступ: Системные настройки → Конфиденциальность и безопасность → Микрофон."
            )
        } else if peak < 0.0005 {
            NSLog(
                "[Audio] ВНИМАНИЕ: буферы приходят, но сигнал пустой (peak=\(peak)). Проверь выбранный микрофон и уровень входа."
            )
        }
        return result
    }

    func cancel() {
        guard isRecording else { return }
        session?.stopRunning()
        session = nil
        isRecording = false
        sampleQueue.sync { capturedSamples.removeAll() }
    }

    /// Потокобезопасный snapshot текущей записи для FluidAudio live-preview.
    func currentSamples() -> [Float] {
        sampleQueue.sync { capturedSamples }
    }

    // MARK: - Приём буферов

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard
            CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
            let raw = pointer, length >= 4
        else { return }

        let count = length / 4  // Float32
        let chunk = raw.withMemoryRebound(to: Float.self, capacity: count) { floats in
            Array(UnsafeBufferPointer(start: floats, count: count))
        }

        sampleQueue.async { [weak self] in
            guard let self = self else { return }
            self.bufferCount += 1
            self.capturedSamples.append(contentsOf: chunk)
        }
    }

    // MARK: - Уровни сигнала

    /// RMS и пиковая амплитуда сигнала.
    static func levels(_ samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var sum: Float = 0
        var peak: Float = 0
        for s in samples {
            sum += s * s
            let a = abs(s)
            if a > peak { peak = a }
        }
        return (sqrt(sum / Float(samples.count)), peak)
    }

    /// Усиливает тихий сигнал до целевого пика (~0.7), чтобы whisper не галлюцинировал.
    /// Сигнал на уровне шума не трогаем.
    ///
    /// Лимит усиления 60x (а не 20x): встроенный микрофон MacBook через
    /// AVCaptureSession отдаёт очень тихий поток (сырой peak порядка 0.003),
    /// и при 20x запись не проходила фильтр тишины в AppDelegate.
    static func normalize(_ samples: [Float], peak: Float, targetPeak: Float = 0.7) -> [Float] {
        guard peak > 0.0002, peak < targetPeak else { return samples }
        let gain = min(targetPeak / peak, 60.0)  // ограничиваем усиление, чтобы не раздувать шум
        return samples.map { $0 * gain }
    }

    // MARK: - WAV

    /// Упаковать float-сэмплы (16kHz mono) в WAV (PCM16) — для отправки в Groq.
    static func wavData(from samples: [Float], sampleRate: Int = 16000) -> Data {
        var data = Data()
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)

        func appendStr(_ s: String) { data.append(s.data(using: .ascii)!) }
        func appendU32(_ v: UInt32) {
            var x = v.littleEndian
            data.append(Data(bytes: &x, count: 4))
        }
        func appendU16(_ v: UInt16) {
            var x = v.littleEndian
            data.append(Data(bytes: &x, count: 2))
        }

        appendStr("RIFF")
        appendU32(36 + dataSize)
        appendStr("WAVE")
        appendStr("fmt ")
        appendU32(16)
        appendU16(1)  // PCM
        appendU16(numChannels)
        appendU32(UInt32(sampleRate))
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendStr("data")
        appendU32(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            var le = intSample.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        return data
    }
}
