import AVFoundation
import Foundation

/// Записывает аудио с микрофона и возвращает массив Float (16kHz, mono),
/// готовый для whisper.cpp и для упаковки в WAV для Groq.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private var capturedSamples: [Float] = []
    private let sampleQueue = DispatchQueue(label: "audio.recorder.samples")
    private(set) var isRecording = false

    static let targetSampleRate: Double = 16000

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        )
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

    func start() -> Bool {
        guard !isRecording else { return false }

        sampleQueue.sync { capturedSamples.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            NSLog("[Audio] Некорректный формат входа (нет микрофона?)")
            return false
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, inputFormat: inputFormat)
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
            NSLog("[Audio] Запись началась (вход %.0f Hz)", inputFormat.sampleRate)
            return true
        } catch {
            NSLog("[Audio] Не удалось запустить engine: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    /// Останавливает запись и возвращает накопленные сэмплы (16kHz mono float).
    /// Сэмплы нормализуются по громкости (auto-gain), т.к. тихий вход заставляет whisper галлюцинировать.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        var result = sampleQueue.sync { capturedSamples }
        let (rms, peak) = AudioRecorder.levels(result)
        result = AudioRecorder.normalize(result, peak: peak)
        NSLog(
            "[Audio] Запись остановлена, сэмплов: \(result.count) (~\(String(format: "%.1f", Double(result.count) / AudioRecorder.targetSampleRate)) c) RMS=\(String(format: "%.4f", rms)) Peak=\(String(format: "%.3f", peak))"
        )
        return result
    }

    /// Потокобезопасный snapshot текущей записи для FluidAudio live-preview.
    /// Копирование происходит только по таймеру preview, а не на каждом audio callback.
    func currentSamples() -> [Float] {
        sampleQueue.sync { capturedSamples }
    }

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
    static func normalize(_ samples: [Float], peak: Float, targetPeak: Float = 0.7) -> [Float] {
        guard peak > 0.001, peak < targetPeak else { return samples }
        let gain = min(targetPeak / peak, 20.0)  // ограничиваем усиление, чтобы не раздувать шум
        return samples.map { $0 * gain }
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        sampleQueue.sync { capturedSamples.removeAll() }
    }

    // MARK: - Conversion

    private func process(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter = converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let convError = convError { NSLog("[Audio] Ошибка конвертации: \(convError)") }
            return
        }

        guard let channelData = outBuffer.floatChannelData else { return }
        let frames = Int(outBuffer.frameLength)
        guard frames > 0 else { return }
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: frames))
        sampleQueue.async { [weak self] in
            self?.capturedSamples.append(contentsOf: chunk)
        }
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
