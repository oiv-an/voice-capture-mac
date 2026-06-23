import Foundation

/// Облачное распознавание через Groq Whisper API (multipart /audio/transcriptions).
final class GroqRecognizer: Recognizer {
    private let apiKey: String
    private let model: String
    private let language: String
    private let prompt: String

    private static let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    init(apiKey: String, model: String, language: String, prompt: String = "") {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.prompt = prompt
    }

    func transcribe(samples: [Float]) throws -> String {
        guard !samples.isEmpty else { throw RecognizerError.emptyAudio }
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RecognizerError.missingApiKey
        }

        let wav = AudioRecorder.wavData(from: samples, sampleRate: 16000)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: GroqRecognizer.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(
                using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)

        field("model", model)
        if language != "auto" && !language.isEmpty {
            field("language", language)
        }
        // prompt — задаёт контекст/стиль распознавания (как initial_prompt у whisper.cpp:
        // помогает с пунктуацией и терминами). Передаём тот же текст, что и локальной модели.
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            field("prompt", trimmedPrompt)
        }
        field("response_format", "json")

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Синхронный вызов (метод вызывается из фонового потока).
        let sem = DispatchSemaphore(value: 0)
        var resultText: String?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                resultError = RecognizerError.network(error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                resultError = RecognizerError.network("нет ответа")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                resultError = RecognizerError.http(http.statusCode, String(msg.prefix(200)))
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = obj["text"] as? String
            {
                resultText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                resultError = RecognizerError.network("не удалось разобрать ответ")
            }
        }
        task.resume()
        sem.wait()

        if let err = resultError { throw err }
        return resultText ?? ""
    }
}
