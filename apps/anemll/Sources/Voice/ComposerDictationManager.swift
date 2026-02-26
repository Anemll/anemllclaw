import AVFAudio
import Foundation
import Observation
import OpenClawChatUI
import OpenClawKit
import OSLog
import Speech

private let logger = Logger(subsystem: "ai.openclaw", category: "ComposerDictation")

/// Lightweight speech-to-text manager used by the chat composer's
/// microphone button.  Uses `SFSpeechRecognizer` + `AVAudioEngine`
/// following the same patterns as `VoiceWakeManager`.
@MainActor
@Observable
final class ComposerDictationManager: NSObject, ChatDictationProvider {

    // MARK: - ChatDictationProvider

    var isListening: Bool = false

    /// Optional reference to VoiceWakeManager so we can suspend it while
    /// dictating (both use the same audio input node).
    var voiceWake: VoiceWakeManager?

    func startDictation(onTranscript: @escaping @MainActor (String) -> Void) async {
        guard !self.isListening else { return }

        #if targetEnvironment(simulator)
        logger.warning("Speech recognition is unavailable on the simulator.")
        return
        #else

        let micOK = await self.requestMicrophonePermission()
        guard micOK else {
            logger.warning("Microphone permission denied.")
            return
        }

        let speechOK = await self.requestSpeechPermission()
        guard speechOK else {
            logger.warning("Speech recognition permission denied.")
            return
        }

        // Suspend voice wake so we don't fight over the audio input.
        if let vw = self.voiceWake, vw.isEnabled, vw.isListening {
            vw.suspendRecognitionOnly()
            self.didSuspendVoiceWake = true
        }

        self.onTranscript = onTranscript

        do {
            try await self.startRecognition()
            self.isListening = true
        } catch {
            logger.error("Failed to start dictation: \(error.localizedDescription)")
            self.isListening = false
            self.resumeVoiceWakeIfNeeded()
        }
        #endif
    }

    func stopDictation() {
        guard self.isListening else { return }
        self.tearDown()
    }

    // MARK: - Private state

    private var onTranscript: (@MainActor (String) -> Void)?
    private var didSuspendVoiceWake = false

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Lifecycle

    override init() {
        super.init()
        self.speechRecognizer = SFSpeechRecognizer()
    }

    // MARK: - Recognition pipeline

    /// Start the audio engine and speech recognition.
    ///
    /// The `SFSpeechRecognizer.recognitionTask(with:resultHandler:)` call
    /// and the audio-engine setup are dispatched to a background queue.
    /// Calling them from @MainActor triggers `_dispatch_assert_queue_fail`
    /// inside the Speech framework's internal `RealtimeMessage…mServiceQueue`.
    private func startRecognition() async throws {
        self.recognitionTask?.cancel()
        self.recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if self.speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        let engine = self.audioEngine
        let recognizer = self.speechRecognizer
        let handler = self.makeResultHandler()

        // Perform audio engine setup and recognition task creation on a
        // background thread to avoid triggering dispatch_assert_queue_fail
        // in the Speech framework's internal RealtimeMessage service queue.
        let task: SFSpeechRecognitionTask? = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let inputNode = engine.inputNode
                    inputNode.removeTap(onBus: 0)

                    let recordingFormat = inputNode.outputFormat(forBus: 0)
                    inputNode.installTap(
                        onBus: 0,
                        bufferSize: 1024,
                        format: recordingFormat
                    ) { [weak request] buffer, _ in
                        request?.append(buffer)
                    }

                    engine.prepare()
                    try engine.start()

                    let recTask = recognizer?.recognitionTask(
                        with: request,
                        resultHandler: handler)
                    cont.resume(returning: recTask)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        self.recognitionTask = task
    }

    private nonisolated func makeResultHandler() -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription

            Task { @MainActor in
                self?.handleResult(transcript: transcript, isFinal: isFinal, errorText: errorText)
            }
        }
    }

    private func handleResult(transcript: String?, isFinal: Bool, errorText: String?) {
        if let errorText {
            logger.error("Recognition error: \(errorText)")
            self.tearDown()
            return
        }

        if let transcript {
            self.onTranscript?(transcript)
        }

        if isFinal {
            self.tearDown()
        }
    }

    private func tearDown() {
        self.isListening = false

        self.recognitionRequest?.endAudio()
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest = nil

        if self.audioEngine.isRunning {
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
        }

        self.onTranscript = nil
        self.resumeVoiceWakeIfNeeded()
    }

    private func resumeVoiceWakeIfNeeded() {
        if self.didSuspendVoiceWake {
            self.voiceWake?.resumeAfterExternalAudioCapture(wasSuspended: true)
            self.didSuspendVoiceWake = false
        }
    }

    // MARK: - Permissions (MainActor-isolated)

    private func requestMicrophonePermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                cont.resume(returning: authStatus == .authorized)
            }
        }
    }
}
