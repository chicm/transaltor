import Foundation
import SwiftUI

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var mode: TranslationMode = .englishToChinese
    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var isRecording: Bool = false
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?

    private let openAIService: OpenAIService
    private let audioRecorder: AudioRecorder

    init(openAIService: OpenAIService? = nil, audioRecorder: AudioRecorder? = nil) {
        self.openAIService = openAIService ?? OpenAIService()
        self.audioRecorder = audioRecorder ?? AudioRecorder()

        self.audioRecorder.onFinishRecording = { [weak self] url in
            Task { await self?.handleRecordingFinished(url: url) }
        }
    }

    func translateCurrentText() async {
        let sanitized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }
        await performTranslation(for: sanitized)
    }

    func toggleRecording() async {
        if isRecording {
            audioRecorder.stopRecording()
            isRecording = false
            return
        }

        errorMessage = nil
        translatedText = ""

        do {
            try await audioRecorder.startRecording(language: mode.speechRecognitionLocale)
            isRecording = true
        } catch {
            updateError(message: error.localizedDescription)
        }
    }

    private func handleRecordingFinished(url: URL?) async {
        isRecording = false

        guard let url else {
            updateError(message: "Recording failed.")
            return
        }

        defer { try? FileManager.default.removeItem(at: url) }

        do {
            isProcessing = true
            translatedText = ""
            let result = try await openAIService.transcribeAndTranslate(audioURL: url, mode: mode)
            sourceText = result.sourceText
            translatedText = result.translatedText
        } catch {
            updateError(message: error.localizedDescription)
        }

        isProcessing = false
    }

    private func performTranslation(for text: String) async {
        isProcessing = true
        errorMessage = nil
        translatedText = ""

        do {
            let result = try await openAIService.translate(text: text, mode: mode)
            sourceText = result.sourceText
            translatedText = result.translatedText
        } catch {
            updateError(message: error.localizedDescription)
        }

        isProcessing = false
    }

    private func updateError(message: String) {
        withAnimation {
            errorMessage = message
        }
    }
}

enum TranslationMode: CaseIterable, Identifiable {
    case englishToChinese
    case chineseToEnglish

    var id: Self { self }

    var title: String {
        switch self {
        case .englishToChinese:
            return "EN → 中文"
        case .chineseToEnglish:
            return "中文 → EN"
        }
    }

    var sourceLanguageName: String {
        switch self {
        case .englishToChinese:
            return "English"
        case .chineseToEnglish:
            return "中文"
        }
    }

    var targetLanguageName: String {
        switch self {
        case .englishToChinese:
            return "中文"
        case .chineseToEnglish:
            return "English"
        }
    }

    var speechRecognitionLocale: String {
        switch self {
        case .englishToChinese:
            return "en"
        case .chineseToEnglish:
            return "zh"
        }
    }

    var systemPrompt: String {
        switch self {
        case .englishToChinese:
            return "You are a precise yet natural translator. Translate from English to Simplified Chinese and respond with translation only."
        case .chineseToEnglish:
            return "You are a precise yet natural translator. Translate from Simplified Chinese to English with natural phrasing and respond with translation only."
        }
    }
}

struct TranslationResult {
    let sourceText: String
    let translatedText: String
}
