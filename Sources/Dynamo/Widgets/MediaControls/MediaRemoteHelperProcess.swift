import Foundation

/// Launches the standalone `DynamoMediaRemoteHelper` binary and streams
/// parsed now-playing payloads from its stdout.
///
/// This is purely additive: `isAvailable` is `false` whenever the helper
/// binary isn't findable; `start()` then no-ops and the caller's fallback
/// chain is unaffected.
@MainActor
final class MediaRemoteHelperProcess {
    struct Payload: Decodable {
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var artworkBase64: String?
    }

    var onPayload: ((Payload) -> Void)?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var buffer = Data()
    private var restartWorkItem: DispatchWorkItem?
    private var lastStartAt: Date?
    /// Consecutive crashes that happened almost immediately after launch.
    /// Without this, a helper that crashes on every launch (e.g. missing a
    /// dependency, a bad build) would relaunch every 2s forever — the
    /// existing MediaRemote/AppleScript fallback tiers already cover
    /// functionality without it, so give up rather than spin indefinitely.
    private var consecutiveQuickFailures = 0
    private static let maxConsecutiveQuickFailures = 5

    /// Locates the helper binary next to the running executable, then falls
    /// back to common SPM / dev layouts so local `swift build` runs can use it
    /// without a full `.app` package.
    private var helperURL: URL? {
        var candidates: [URL] = []

        if let exe = Bundle.main.executableURL {
            candidates.append(
                exe.deletingLastPathComponent().appendingPathComponent("DynamoMediaRemoteHelper")
            )
        }
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "DynamoMediaRemoteHelper") {
            candidates.append(aux)
        }

        // Path of the running process (works for bare SPM executables).
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(
            argv0.deletingLastPathComponent().appendingPathComponent("DynamoMediaRemoteHelper")
        )

        // Dev: `.build/debug|release` next to cwd or relative to argv0's package root.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for config in ["debug", "release"] {
            candidates.append(cwd.appendingPathComponent(".build/\(config)/DynamoMediaRemoteHelper"))
        }
        // Walk up from argv0 looking for Package.swift + .build
        var dir = argv0.deletingLastPathComponent()
        for _ in 0..<6 {
            for config in ["debug", "release"] {
                candidates.append(dir.appendingPathComponent(".build/\(config)/DynamoMediaRemoteHelper"))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Whether the helper binary is actually present in this build.
    var isAvailable: Bool { helperURL != nil }

    /// Resolved path (for Settings / diagnostics).
    var resolvedPath: String? { helperURL?.path }

    func start() {
        guard process == nil, let helperURL else { return }
        let task = Process()
        task.executableURL = helperURL
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.consume(chunk)
            }
        }
        task.terminationHandler = { [weak self] finishedTask in
            Task { @MainActor in
                guard let self, self.process === finishedTask else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.stdoutPipe = nil

                let ranBriefly = self.lastStartAt.map { Date().timeIntervalSince($0) < 3 } ?? true
                self.consecutiveQuickFailures = ranBriefly ? self.consecutiveQuickFailures + 1 : 0
                guard self.consecutiveQuickFailures < Self.maxConsecutiveQuickFailures else {
                    NSLog("Dynamo: MediaRemote helper crashed repeatedly on launch — giving up for this session")
                    return
                }
                // Auto-restart after a crash (rate-limited) so media stays alive.
                self.scheduleRestart()
            }
        }
        do {
            try task.run()
            process = task
            stdoutPipe = outPipe
            lastStartAt = Date()
            NSLog("Dynamo: MediaRemote helper started at %@", helperURL.path)
        } catch {
            process = nil
            stdoutPipe = nil
            NSLog("Dynamo: failed to start MediaRemote helper: %@", error.localizedDescription)
        }
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        buffer.removeAll()
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.start()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newlineRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
            guard !lineData.isEmpty,
                  let payload = try? JSONDecoder().decode(Payload.self, from: lineData)
            else { continue }
            onPayload?(payload)
        }
    }
}
