import Foundation

enum TranscriptionServiceError: LocalizedError {
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

final class TranscriptionService {
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

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        guard let apiKey = apiKey else { throw TranscriptionServiceError.missingAPIKey }

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

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let description = (message?["message"] as? String) ?? "OpenAI request failed with status code \(http.statusCode)."
            throw TranscriptionServiceError.serverError(description)
        }
    }

    private func makeMultipartBody(audioURL: URL, boundary: String, language: String?) throws -> Data {
        let fileData = try Data(contentsOf: audioURL)
        var body = Data()
        let lineBreak = "\r\n"
        let fileName = audioURL.lastPathComponent
        let mimeType = mimeType(for: audioURL.pathExtension)

        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("gpt-4o-mini-transcribe\r\n")

        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append(lineBreak)

        append("--\(boundary)--\r\n")
        return body
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "m4a": return "audio/m4a"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}
