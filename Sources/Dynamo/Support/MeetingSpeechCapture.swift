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
    private var restartCount = 0
    private let maxRestarts = 12

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
            objectWillChange.send()
            return
        }

        stopEngineOnly(commitPartial: false)

        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognition unavailable"
            objectWillChange.send()
            return
        }
        self.recognizer = recognizer
        prefersOnDevice = recognizer.supportsOnDeviceRecognition

        let engine = AVAudioEngine()
        self.audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // macOS can report 0 channels before hardware is ready.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            statusMessage = "No mic input format — try again"
            objectWillChange.send()
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            statusMessage = "Mic start failed"
            stopEngineOnly(commitPartial: false)
            objectWillChange.send()
            return
        }

        lastCommitted = ""
        partialText = ""
        restartCount = 0
        beginRecognitionTask()

        isListening = true
        statusMessage = prefersOnDevice ? "Listening · on-device" : "Listening"
        objectWillChange.send()
    }

    func stop() {
        let was = isListening
        isListening = false
        stopEngineOnly(commitPartial: was)
        statusMessage = ""
        partialText = ""
        objectWillChange.send()
    }

    private func beginRecognitionTask() {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

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
                if let error {
                    // Common: no-speech / canceled — commit and optionally restart.
                    if !self.partialText.isEmpty {
                        self.commitSpeech(self.partialText)
                    }
                    let ns = error as NSError
                    // Don't spin forever on hard failures.
                    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
                        // No speech detected — quiet restart.
                    }
                    self.scheduleRestart()
                }
            }
        }
    }

    private func scheduleRestart() {
        guard isListening else { return }
        guard restartCount < maxRestarts else {
            statusMessage = "Listen paused — tap to resume"
            isListening = false
            stopEngineOnly(commitPartial: false)
            objectWillChange.send()
            return
        }
        restartCount += 1
        // End current request, keep engine + tap running, new request.
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isListening, self.audioEngine?.isRunning == true else { return }
            self.beginRecognitionTask()
        }
    }

    private func commitSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == lastCommitted { return }
        var toStore = trimmed
        if !lastCommitted.isEmpty,
           trimmed.hasPrefix(lastCommitted),
           trimmed.count > lastCommitted.count {
            toStore = String(trimmed.dropFirst(lastCommitted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lastCommitted = trimmed
        if !toStore.isEmpty {
            _ = MeetingNotesStore.shared.addBullet(toStore, source: .speech)
        }
        partialText = ""
    }

    private func stopEngineOnly(commitPartial: Bool) {
        if commitPartial, !partialText.isEmpty {
            commitSpeech(partialText)
        }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
        recognizer = nil
    }
}
