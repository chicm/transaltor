import Foundation

enum OpenAIServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing OpenAI API key. Set the OPENAI_API_KEY environment variable."
        case .invalidResponse:
            return "Failed to parse response from OpenAI."
        case let .serverError(message):
            return message
        }
    }
}

final class OpenAIService {
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let baseURL = URL(string: "https://api.openai.com/v1")!

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    init(session: URLSession = .shared) {
        self.session = session
        self.jsonDecoder = JSONDecoder()
    }

    func translate(text: String, mode: TranslationMode) async throws -> TranslationResult {
        guard let apiKey else { throw OpenAIServiceError.missingAPIKey }

        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try makeChatCompletionsRequest(text: sanitized, mode: mode, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try jsonDecoder.decode(ChatCompletionResponse.self, from: data)
        guard let message = decoded.choices.first?.message.combinedText else {
            throw OpenAIServiceError.invalidResponse
        }

        return TranslationResult(sourceText: sanitized, translatedText: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func transcribeAndTranslate(audioURL: URL, mode: TranslationMode) async throws -> TranslationResult {
        guard let apiKey else { throw OpenAIServiceError.missingAPIKey }

        let transcription = try await transcribe(audioURL: audioURL, language: mode.speechRecognitionLocale, apiKey: apiKey)
        return try await translate(text: transcription, mode: mode)
    }

    private func transcribe(audioURL: URL, language: String, apiKey: String) async throws -> String {
        let url = baseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(audioURL: audioURL, boundary: boundary, language: language)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let transcription = try jsonDecoder.decode(TranscriptionResponse.self, from: data)
        return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeChatCompletionsRequest(text: String, mode: TranslationMode, apiKey: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ChatCompletionRequest(model: "gpt-4o-mini", messages: [
            .init(role: "system", content: [.init(type: "text", text: mode.systemPrompt)]),
            .init(role: "user", content: [.init(type: "text", text: text)])
        ], temperature: 0)

        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                ["error"] as? [String: Any]
            let description = (message?["message"] as? String) ?? "OpenAI request failed with status code \(http.statusCode)."
            throw OpenAIServiceError.serverError(description)
        }
    }

    private func makeMultipartBody(audioURL: URL, boundary: String, language: String) throws -> Data {
        let fileData = try Data(contentsOf: audioURL)
        var body = Data()
        let lineBreak = "\r\n"

        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("gpt-4o-mini-transcribe\r\n")

        if !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(fileData)
        append(lineBreak)

        append("--\(boundary)--\r\n")
        return body
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        struct Content: Encodable {
            let type: String
            let text: String
        }

        let role: String
        let content: [Content]
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String
            }

            let role: String
            let content: [Content]?
            let fallbackText: String?

            enum CodingKeys: String, CodingKey {
                case role
                case content
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try container.decode(String.self, forKey: .role)
                content = try? container.decode([Content].self, forKey: .content)

                if let single = try? container.decode(String.self, forKey: .content) {
                    fallbackText = single
                } else {
                    fallbackText = nil
                }
            }

            var combinedText: String? {
                if let content, !content.isEmpty {
                    return content.compactMap { $0.text }.joined(separator: "\n")
                }
                return fallbackText
            }
        }

        let index: Int
        let message: Message
    }

    let choices: [Choice]
}

private struct TranscriptionResponse: Decodable {
    let text: String
}
