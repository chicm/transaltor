import AVFoundation
import Accelerate

@MainActor
final class AudioRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case failedToCreateFile

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission is required."
            case .failedToCreateFile:
                return "Unable to create a recording file."
            }
        }
    }

    var onFinishRecording: ((URL?) -> Void)?
    var onDebug: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var tapInstalled = false
    private var shouldLoop = false

    private var recordingStartTime: CFTimeInterval = 0
    private var lastSpeechTime: CFTimeInterval?
    private var baselineEndTime: CFTimeInterval = 0
    private var baselineMaxPower: Float = -160
    private var dynamicActivationThreshold: Float?
    private var speechDetected = false
    private let minimumSpeechDuration: TimeInterval = 0.2

    private let baselineDuration: TimeInterval = 1.0
    private let trailingSilenceDuration: TimeInterval = 1.5
    private let maxInitialSilence: TimeInterval = 30.0
    private let activationMargin: Float = 15
    private let minimumActivation: Float = -40
    private let maxBaselineLevel: Float = -30

    func startRecording(language: String) async throws {
        try await ensureMicrophonePermission()
        try configureSession()
        shouldLoop = true
        try await beginCapture()
    }

    func stopRecording() {
        shouldLoop = false
        finishRecording(success: false)
    }

    private func ensureMicrophonePermission() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw RecorderError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
            if !granted { throw RecorderError.microphonePermissionDenied }
        @unknown default:
            throw RecorderError.microphonePermissionDenied
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func beginCapture() async throws {
        resetEngineState()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let filename = "utterance-\(UUID().uuidString).caf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        currentURL = url

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        } catch {
            logDebug("Failed creating audio file: \(error.localizedDescription)")
            throw RecorderError.failedToCreateFile
        }

        speechDetected = false
        lastSpeechTime = nil
        recordingStartTime = CACurrentMediaTime()
        baselineEndTime = recordingStartTime + baselineDuration
        baselineMaxPower = -160
        dynamicActivationThreshold = nil

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                self.logDebug("Failed writing audio buffer: \(error.localizedDescription)")
            }
            self.processAudioLevels(buffer: buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        logDebug("Audio engine started for raw capture.")
    }

    private func processAudioLevels(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))
        let epsilon: Float = 1e-7
        let avgPower = 20 * log10(max(rms, epsilon))
        let now = CACurrentMediaTime()

        if dynamicActivationThreshold == nil {
            baselineMaxPower = max(baselineMaxPower, avgPower)
            if now >= baselineEndTime || avgPower > minimumActivation + 5 {
                let baselineLevel = min(baselineMaxPower, maxBaselineLevel)
                dynamicActivationThreshold = max(baselineLevel + activationMargin, minimumActivation)
                logDebug("Calibrated activation threshold to \(Int(dynamicActivationThreshold ?? minimumActivation)) dB (baseline \(Int(baselineLevel)) dB).")
            } else {
                return
            }
        }

        guard let activationThreshold = dynamicActivationThreshold else { return }

        if avgPower > activationThreshold {
            if speechDetected {
                lastSpeechTime = now
            } else if let lastSpeechTime = lastSpeechTime {
                if now - lastSpeechTime >= minimumSpeechDuration {
                    speechDetected = true
                    logDebug("Speech detected (level \(Int(avgPower)) dB).")
                }
            } else {
                self.lastSpeechTime = now
            }
        } else if speechDetected {
            if let lastSpeechTime, now - lastSpeechTime >= trailingSilenceDuration {
                logDebug("Detected \(trailingSilenceDuration)s of trailing silence. Stopping recording.")
                finishRecording(success: true)
            }
        } else if now - recordingStartTime >= maxInitialSilence {
            logDebug("No speech detected for \(maxInitialSilence)s. Stopping recording.")
            finishRecording(success: false)
        }
    }

    private func finishRecording(success: Bool) {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let recordedURL = currentURL
        currentURL = nil
        audioFile = nil

        if !success, let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }

        onFinishRecording?(success ? recordedURL : nil)

        if shouldLoop {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.beginCapture()
                } catch {
                    self.logDebug("Failed to restart capture: \(error.localizedDescription)")
                    self.onFinishRecording?(nil)
                }
            }
        }
    }

    private func resetEngineState() {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioFile = nil
        currentURL = nil
    }

    private func logDebug(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onDebug?(message)
        }
    }
}
