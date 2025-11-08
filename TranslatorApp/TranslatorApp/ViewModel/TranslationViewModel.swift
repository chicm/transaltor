import AVFoundation
import Foundation
import SwiftUI


@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var state: VoiceSessionState = .idle
    @Published var transcripts: [RecognizedUtterance] = []
    @Published var errorMessage: String?
    @Published var debugMessages: [String] = []

    private let transcriptionService: TranscriptionService
    private let audioRecorder: AudioRecorder
    private let debugFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let recorderLocale: String = Locale.preferredLanguages.first ?? "en-US"
    private var isSessionActive = false

    init(audioRecorder: AudioRecorder? = nil, transcriptionService: TranscriptionService = TranscriptionService()) {
        self.transcriptionService = transcriptionService
        self.audioRecorder = audioRecorder ?? AudioRecorder()

        self.audioRecorder.onFinishRecording = { [weak self] url in
            guard let self else { return }
            Task { await self.processCapturedSegment(url: url) }
        }
        self.audioRecorder.onDebug = { [weak self] message in
            self?.logDebug("Recorder: \(message)")
        }
    }

    func toggleVoiceInteraction() {
        switch state {
        case .idle:
            startSession()
        case .listening, .processing:
            stopSession()
        }
    }

    private func startSession() {
        errorMessage = nil
        transcripts.removeAll()
        debugMessages.removeAll()
        isSessionActive = true
        state = .listening
        logDebug("Session started. Waiting for single utterance.")

        Task {
            do {
                try await audioRecorder.startRecording(language: recorderLocale)
                logDebug("Recorder running. Speak now.")
            } catch {
                await handle(error: error, shouldExit: true)
            }
        }
    }

    private func stopSession() {
        isSessionActive = false
        audioRecorder.stopRecording()
        state = .idle
        logDebug("Session stopped.")
    }

    func clearDebugLogs() {
        debugMessages.removeAll()
    }

    private func processCapturedSegment(url: URL?) async {
        guard isSessionActive else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }

        guard let url else {
            logDebug("No speech captured; continuing to listen.")
            await restartListening()
            return
        }

        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let uploadURL = try await convertToM4AIfNeeded(url: url)
            defer { try? FileManager.default.removeItem(at: uploadURL) }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: uploadURL.path),
               let size = attrs[.size] as? NSNumber {
                logDebug("Processing audio segment (\(size.intValue) bytes).")
            } else {
                logDebug("Processing audio segment (size unavailable).")
            }

            state = .processing
            let text = try await transcribe(audioURL: uploadURL)
            let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            logDebug("Transcript: \"\(sanitized)\"")

            if sanitized.isEmpty {
                logDebug("Transcript empty; returning to idle.")
                await restartListening()
                return
            }

            transcripts.append(RecognizedUtterance(text: sanitized))
            await restartListening()
        } catch {
            await handle(error: error)
        }
    }

    private func transcribe(audioURL: URL) async throws -> String {
        try await transcriptionService.transcribe(audioURL: audioURL, language: nil)
    }

    private func convertToM4AIfNeeded(url: URL) async throws -> URL {
        if url.pathExtension.lowercased() == "m4a" {
            return url
        }

        let asset = AVAsset(url: url)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecognitionError.conversionFailed("Unable to create export session.")
        }

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("converted-\(UUID().uuidString).m4a")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        let box = ExportSessionBox(session: exportSession)

        return try await withCheckedThrowingContinuation { continuation in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    let message = box.session.error?.localizedDescription ?? "Unknown conversion error."
                    continuation.resume(throwing: RecognitionError.conversionFailed(message))
                default:
                    let message = box.session.error?.localizedDescription ?? "Unknown export session state."
                    continuation.resume(throwing: RecognitionError.conversionFailed(message))
                }
            }
        }
    }

    private func handle(error: Error, shouldExit: Bool = false) async {
        logDebug("Session error: \(error.localizedDescription)")
        withAnimation {
            errorMessage = error.localizedDescription
        }

        if shouldExit || !isSessionActive {
            isSessionActive = false
            audioRecorder.stopRecording()
            state = .idle
            return
        }

        await restartListening()
    }

    private func logDebug(_ message: String) {
        let timestamp = debugFormatter.string(from: Date())
        debugMessages.append("[\(timestamp)] \(message)")
        if debugMessages.count > 80 {
            debugMessages.removeFirst(debugMessages.count - 80)
        }
    }

    private func restartListening() async {
        guard isSessionActive else {
            state = .idle
            return
        }

        state = .listening
        logDebug("Ready for the next utterance. Speak when ready.")

        Task {
            do {
                try await audioRecorder.startRecording(language: recorderLocale)
                logDebug("Recorder re-armed. Speak now.")
            } catch {
                await handle(error: error, shouldExit: true)
            }
        }
    }
}

enum VoiceSessionState {
    case idle
    case listening
    case processing
}

struct RecognizedUtterance: Identifiable {
    let id = UUID()
    let text: String
}

enum RecognitionError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .conversionFailed(message):
            return "Failed to convert audio: \(message)"
        }
    }
}

private struct ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
}

struct TranslationResult {
    let sourceText: String
    let translatedText: String
}
