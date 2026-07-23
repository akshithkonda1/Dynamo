import AVFoundation
import Foundation
import Speech

/// Free Apple Speech package for Meeting notetaker (L1).
/// Prefer on-device recognition; mic only while Listen is active.
@MainActor
final class MeetingSpeechCapture: ObservableObject {
    static let shared = MeetingSpeechCapture()

    enum AuthState: Equatable {
        case unknown
        case denied
        case authorized
    }

    @Published private(set) var isListening = false
    @Published private(set) var speechAuth: AuthState = .unknown
    @Published private(set) var micAuth: AuthState = .unknown
    @Published private(set) var partialText: String = ""
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var prefersOnDevice = false

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var lastCommitted: String = ""

    private init() {
        refreshAuth()
    }

    func refreshAuth() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechAuth = .authorized
        case .denied, .restricted: speechAuth = .denied
        case .notDetermined: speechAuth = .unknown
        @unknown default: speechAuth = .unknown
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micAuth = .authorized
        case .denied, .restricted: micAuth = .denied
        case .notDetermined: micAuth = .unknown
        @unknown default: micAuth = .unknown
        }
    }

    func requestPermissions() async {
        let speech: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        speechAuth = speech ? .authorized : .denied

        let mic: Bool = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        micAuth = mic ? .authorized : .denied
    }

    func toggleListen() {
        if isListening {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        refreshAuth()
        if speechAuth != .authorized || micAuth != .authorized {
            await requestPermissions()
        }
        guard speechAuth == .authorized, micAuth == .authorized else {
            statusMessage = "Allow Speech & Microphone for Listen"
            return
        }

        stopEngineOnly()

        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognition unavailable"
            return
        }
        self.recognizer = recognizer
        prefersOnDevice = recognizer.supportsOnDeviceRecognition

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let engine = AVAudioEngine()
        self.audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            statusMessage = "Mic start failed"
            stop()
            return
        }

        lastCommitted = ""
        partialText = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialText = text
                    if result.isFinal {
                        self.commitSpeech(text)
                    }
                }
                if error != nil {
                    // End of utterance often; commit partial and keep going if still listening.
                    if !self.partialText.isEmpty {
                        self.commitSpeech(self.partialText)
                    }
                    if self.isListening {
                        // Restart recognition task for continuous dictation.
                        self.restartTask()
                    }
                }
            }
        }

        isListening = true
        statusMessage = prefersOnDevice ? "Listening · on-device" : "Listening"
        objectWillChange.send()
    }

    func stop() {
        isListening = false
        if !partialText.isEmpty {
            commitSpeech(partialText)
        }
        stopEngineOnly()
        statusMessage = ""
        partialText = ""
        objectWillChange.send()
    }

    private func restartTask() {
        guard isListening, let recognizer, let request else { return }
        task?.cancel()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialText = text
                    if result.isFinal {
                        self.commitSpeech(text)
                    }
                }
                if error != nil, !self.partialText.isEmpty {
                    self.commitSpeech(self.partialText)
                    self.restartTask()
                }
            }
        }
    }

    private func commitSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Avoid duplicating the same final string.
        if trimmed == lastCommitted { return }
        // If this is an extension of last committed, store only the delta when possible.
        var toStore = trimmed
        if trimmed.hasPrefix(lastCommitted), trimmed.count > lastCommitted.count {
            toStore = String(trimmed.dropFirst(lastCommitted.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lastCommitted = trimmed
        if !toStore.isEmpty {
            _ = MeetingNotesStore.shared.addBullet(toStore, source: .speech)
        }
        partialText = ""
    }

    private func stopEngineOnly() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        recognizer = nil
    }
}
