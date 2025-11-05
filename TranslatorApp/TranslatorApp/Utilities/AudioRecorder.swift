import AVFoundation

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case failedToCreateRecorder

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission is required."
            case .failedToCreateRecorder:
                return "Unable to start recording."
            }
        }
    }

    var onFinishRecording: ((URL?) -> Void)?

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func startRecording(language: String) async throws {
        _ = language // reserved for future locale-specific optimizations
        try await requestPermission()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let filename = "recording-\(UUID().uuidString).m4a"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            recorder = try AVAudioRecorder(url: url, settings: settings)
            guard let recorder else { throw RecorderError.failedToCreateRecorder }
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record()
            currentURL = url
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            recorder = nil
            currentURL = nil
            throw error
        }
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let url = flag ? self.currentURL : nil
            self.onFinishRecording?(url)
            self.cleanup()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onFinishRecording?(nil)
            self.cleanup()
        }
    }

    private func cleanup() {
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async throws {
        let session = AVAudioSession.sharedInstance()
        return try await withCheckedThrowingContinuation { continuation in
            session.requestRecordPermission { granted in
                if granted {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RecorderError.permissionDenied)
                }
            }
        }
    }
}
