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
    private var pendingSegments: [QueuedSegment] = []
    private var isProcessingQueue = false
    private let maxConcurrentUploads = 3
    private let maxRetryCount = 2

    init(audioRecorder: AudioRecorder? = nil, transcriptionService: TranscriptionService = TranscriptionService()) {
        self.transcriptionService = transcriptionService
        self.audioRecorder = audioRecorder ?? AudioRecorder()

        self.audioRecorder.onFinishRecording = { [weak self] url in
            Task { await self?.handleCapturedSegment(url: url) }
        }
        self.audioRecorder.onDebug = { [weak self] message in
            self?.logDebug("Recorder: \(message)")
        }
    }

    func toggleVoiceInteraction() {
        switch state {
        case .idle:
            startSession()
        case .listening:
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
        pendingSegments.forEach { try? FileManager.default.removeItem(at: $0.url) }
        pendingSegments.removeAll()
        isProcessingQueue = false
        state = .idle
        logDebug("Session stopped.")
    }

    func clearDebugLogs() {
        debugMessages.removeAll()
    }

    private func handleCapturedSegment(url: URL?) async {
        guard isSessionActive else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }

        guard let url else {
            logDebug("No speech captured; continuing to listen.")
            return
        }

        pendingSegments.append(QueuedSegment(url: url, retryCount: 0))
        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        Task { await processQueue() }
    }

    private func processQueue() async {
        defer {
            isProcessingQueue = false
            if isSessionActive && !pendingSegments.isEmpty {
                processQueueIfNeeded()
            }
        }

        let service = transcriptionService

        while isSessionActive {
            guard !pendingSegments.isEmpty else { return }

            let batch = pendingSegments.prefix(maxConcurrentUploads)
            pendingSegments.removeFirst(batch.count)

            await withTaskGroup(of: SegmentProcessingResult.self) { group in
                for segment in batch {
                    group.addTask {
                        await SegmentProcessingWorker(
                            segment: segment,
                            transcriptionService: service
                        ).run()
                    }
                }

                for await result in group {
                    await self.applyProcessingResult(result)
                }
            }
        }

        isProcessingQueue = false
    }

    private func applyProcessingResult(_ result: SegmentProcessingResult) async {
        result.logs.forEach { logDebug($0) }

        if let transcript = result.transcript {
            transcripts.append(RecognizedUtterance(text: transcript))
            try? FileManager.default.removeItem(at: result.segment.url)
            return
        }

        if result.shouldDiscardOriginal {
            try? FileManager.default.removeItem(at: result.segment.url)
        }

        if let failure = result.failure {
            if !result.shouldDiscardOriginal, result.segment.retryCount < maxRetryCount {
                var retrySegment = result.segment
                retrySegment.retryCount += 1
                pendingSegments.insert(retrySegment, at: 0)
            } else {
                try? FileManager.default.removeItem(at: result.segment.url)
                await handle(error: failure)
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
    }

    private func logDebug(_ message: String) {
        let timestamp = debugFormatter.string(from: Date())
        debugMessages.append("[\(timestamp)] \(message)")
        if debugMessages.count > 80 {
            debugMessages.removeFirst(debugMessages.count - 80)
        }
    }

}

enum VoiceSessionState {
    case idle
    case listening
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

private struct QueuedSegment: Sendable {
    let id = UUID()
    let url: URL
    var retryCount: Int
}

private struct SegmentProcessingResult: Sendable {
    let segment: QueuedSegment
    let transcript: String?
    let failure: SegmentProcessingFailure?
    let shouldDiscardOriginal: Bool
    let logs: [String]
}

private struct SegmentProcessingFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private struct SegmentProcessingWorker {
    let segment: QueuedSegment
    let transcriptionService: TranscriptionService

    func run() async -> SegmentProcessingResult {
        var logs: [String] = []

        do {
            let uploadURL = try await AudioConverter.convertToM4AIfNeeded(url: segment.url)
            defer { try? FileManager.default.removeItem(at: uploadURL) }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: uploadURL.path),
               let size = attrs[.size] as? NSNumber {
                logs.append("Processing segment \(segment.id) (\(size.intValue) bytes, retry \(segment.retryCount)).")
            } else {
                logs.append("Processing segment \(segment.id) (size unavailable, retry \(segment.retryCount)).")
            }

            let text = try await transcriptionService.transcribe(audioURL: uploadURL, language: nil)
            let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            logs.append("Transcript for segment \(segment.id): \"\(sanitized)\"")

            guard !sanitized.isEmpty else {
                logs.append("Segment \(segment.id) produced empty transcript; ignoring.")
                return SegmentProcessingResult(
                    segment: segment,
                    transcript: nil,
                    failure: nil,
                    shouldDiscardOriginal: true,
                    logs: logs
                )
            }

            return SegmentProcessingResult(
                segment: segment,
                transcript: sanitized,
                failure: nil,
                shouldDiscardOriginal: true,
                logs: logs
            )
        } catch {
            logs.append("Segment \(segment.id) failed: \(error.localizedDescription)")
            return SegmentProcessingResult(
                segment: segment,
                transcript: nil,
                failure: SegmentProcessingFailure(message: error.localizedDescription),
                shouldDiscardOriginal: false,
                logs: logs
            )
        }
    }
}

enum AudioConverter {
    static func convertToM4AIfNeeded(url: URL) async throws -> URL {
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
}
