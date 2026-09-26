import CoreML
import FluidAudio
import Foundation

/// Native, local GigaAM E2E RNNT. No Python and no punctuation postprocessor.
actor GigaAMRecognizer {
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var frontend: GigaAMFeatures?
    private var pieces: [String] = []
    private var vad: VadManager?

    func prepare() throws {
        guard GigaAMModelStore.supported else {
            throw GigaAMError.message("GigaAM требует Apple Silicon и macOS 15+")
        }
        guard GigaAMModelStore.isDownloaded else {
            throw GigaAMError.message("Скачайте GigaAM в настройках распознавания")
        }
        if encoder != nil { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let models = try GigaAMModelStore.names.map {
            try MLModel(
                contentsOf: GigaAMModelStore.directory.appendingPathComponent($0 + ".mlmodelc"),
                configuration: config)
        }
        let vocabulary = try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: GigaAMModelStore.directory.appendingPathComponent("tokens.json"))
        )
        guard vocabulary.count == 1024 else { throw GigaAMError.message("Неверный словарь GigaAM") }
        frontend = try GigaAMFeatures()
        pieces = vocabulary
        encoder = models[0]
        decoder = models[1]
        joint = models[2]
        NSLog("[GigaAM] Core ML CPU+GPU готов")
    }

    func transcribe(samples: [Float], preview: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard samples.count >= 320 else { return "" }
        try prepare()
        // VAD guides cuts only. Never discard samples based on VAD confidence.
        var pauses: [Int] = []
        if samples.count > 24 * 16000 && !preview {
            do {
                if vad == nil { vad = try await VadManager() }
                if let vad {
                    var config = VadSegmentationConfig.default
                    config.maxSpeechDuration = 22
                    config.minSilenceDuration = 0.25
                    let segments = try await vad.segmentSpeech(samples, config: config)
                    for pair in zip(segments, segments.dropFirst()) {
                        let left = Int(pair.0.endTime * 16000)
                        let right = Int(pair.1.startTime * 16000)
                        if right - left >= 1600 { pauses.append((left + right) / 2) }
                    }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                NSLog("[GigaAM] VAD недоступен, деление по энергии: \(error.localizedDescription)")
            }
        }
        var start = 0
        var texts: [String] = []
        while start < samples.count {
            try Task.checkCancellation()
            let end: Int
            if samples.count - start <= 24 * 16000 {
                end = samples.count
            } else {
                let low = start + 15 * 16000
                let high = start + 22 * 16000
                if let pause = pauses.last(where: { $0 >= low && $0 <= high }) {
                    end = pause
                } else {
                    // Quietest 100 ms in the preferred range; works offline even without VAD.
                    var best = high
                    var energy = Float.greatestFiniteMagnitude
                    for point in stride(from: low, through: high, by: 800) {
                        var sum: Float = 0
                        for i in (point - 800)..<(point + 800) { sum += samples[i] * samples[i] }
                        if sum < energy {
                            energy = sum
                            best = point
                        }
                    }
                    end = best
                }
            }
            // Context around cuts; timestamp ownership avoids text-overlap heuristics deleting repetitions.
            let contextStart = max(0, start - 8000)
            let contextEnd = min(samples.count, end + 8000)
            let clip = Array(samples[contextStart..<contextEnd])
            let emissions = try decode(clip)
            // Keep complete SentencePiece words across cuts, not individual subword tokens.
            var words: [[Emission]] = []
            for emission in emissions {
                if words.isEmpty || pieces[emission.token].hasPrefix("▁") {
                    words.append([emission])
                } else {
                    words[words.count - 1].append(emission)
                }
            }
            let owned = words.filter { word in
                let centerFrame = (word.first!.frame + word.last!.frame) / 2
                let position = contextStart + centerFrame * 640
                return position >= start && position < end
            }.flatMap { $0 }
            let text = detokenize(owned.map { $0.token })
            if !text.isEmpty { texts.append(text) }
            NSLog(
                "[GigaAM] Фрагмент %.2f–%.2f с, %d токенов", Double(start) / 16000,
                Double(end) / 16000, owned.count)
            start = end
        }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Emission {
        let token: Int
        let frame: Int
    }

    private func decode(_ samples: [Float]) throws -> [Emission] {
        guard samples.count <= 480_000, let encoder, let decoder, let joint, let frontend else {
            throw GigaAMError.message("Неверное состояние GigaAM")
        }
        let mel = frontend.compute(samples)
        let features = try array([1, 64, 2999], mel.values)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: mel.frames)
        let encodedResult = try encoder.prediction(
            from: provider(["features": features, "length": length]))
        guard let encoded = encodedResult.featureValue(for: "encoded")?.multiArrayValue,
            let count = encodedResult.featureValue(for: "encoded_len")?.multiArrayValue
        else {
            throw GigaAMError.message("Неверный выход encoder GigaAM")
        }
        let frames = count[0].intValue
        guard frames > 0, frames <= 750 else { throw GigaAMError.message("Неверная длина GigaAM") }
        var h = try array([1, 1, 320])
        var c = try array([1, 1, 320])
        let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        token[0] = 1024
        let encFrame = try array([1, 768])
        var result: [Emission] = []
        var prediction: MLFeatureProvider?
        for frame in 0..<frames {
            try Task.checkCancellation()
            for channel in 0..<768 {
                encFrame[channel] = encoded[[0, NSNumber(value: channel), NSNumber(value: frame)]]
            }
            for _ in 0..<10 {
                if prediction == nil {
                    prediction = try decoder.prediction(
                        from: provider(["token": token, "h_in": h, "c_in": c]))
                }
                guard let d = prediction,
                    let dec = d.featureValue(for: "dec_out")?.multiArrayValue
                else {
                    throw GigaAMError.message("Неверный выход decoder GigaAM")
                }
                let output = try joint.prediction(
                    from: provider(["enc_t": encFrame, "dec_t": dec]))
                guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
                    logits.count == 1025
                else {
                    throw GigaAMError.message("Неверный выход joint GigaAM")
                }
                var best = 0
                var score = logits[0].floatValue
                for i in 1..<1025 where logits[i].floatValue > score {
                    score = logits[i].floatValue
                    best = i
                }
                if best == 1024 { break }
                guard let nextH = d.featureValue(for: "h_out")?.multiArrayValue,
                    let nextC = d.featureValue(for: "c_out")?.multiArrayValue
                else {
                    throw GigaAMError.message("Неверное состояние decoder GigaAM")
                }
                result.append(Emission(token: best, frame: frame))
                h = nextH
                c = nextC
                token[0] = NSNumber(value: best)
                prediction = nil
            }
        }
        return result
    }

    private func array(_ shape: [NSNumber], _ values: [Float]? = nil) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        if let values {
            values.withUnsafeBufferPointer {
                pointer.update(from: $0.baseAddress!, count: values.count)
            }
        } else {
            pointer.initialize(repeating: 0, count: array.count)
        }
        return array
    }

    private func provider(_ values: [String: MLMultiArray]) throws -> MLDictionaryFeatureProvider {
        try MLDictionaryFeatureProvider(dictionary: values)
    }

    private func detokenize(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        var text = ""
        func flush() {
            text += String(decoding: bytes, as: UTF8.self)
            bytes.removeAll(keepingCapacity: true)
        }
        for id in ids {
            let piece = pieces[id]
            if piece.hasPrefix("<0x"), piece.hasSuffix(">"),
                let byte = UInt8(piece.dropFirst(3).dropLast(), radix: 16)
            {
                bytes.append(byte)
            } else {
                flush()
                if piece != "<s>" && piece != "</s>" {
                    text += piece.replacingOccurrences(of: "▁", with: " ")
                }
            }
        }
        flush()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
