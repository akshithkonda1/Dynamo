import Foundation

/// Launches the standalone `DynamoMediaRemoteHelper` binary and streams
/// parsed now-playing payloads from its stdout.
///
/// This is purely additive: `isAvailable` is `false` whenever the helper
/// binary isn't sitting next to the main executable (e.g. a plain `swift
/// build` debug run, or a build where the embed step hasn't been verified
/// yet), in which case `start()` simply does nothing and the caller's
/// existing fallback chain is unaffected.
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

    /// Locates the helper binary next to the running executable. The Xcode
    /// target (`project.yml`) embeds it into `Contents/MacOS/` alongside the
    /// main binary; `scripts/package-app.sh` copies it there too for the
    /// ad-hoc-packaged `.app`.
    private var helperURL: URL? {
        guard let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = exeDir.appendingPathComponent("DynamoMediaRemoteHelper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Whether the helper binary is actually present in this build.
    var isAvailable: Bool { helperURL != nil }

    func start() {
        guard process == nil, let helperURL else { return }
        let task = Process()
        task.executableURL = helperURL
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe() // discard; don't inherit the parent's stderr
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.consume(chunk)
            }
        }
        do {
            try task.run()
            process = task
            stdoutPipe = outPipe
        } catch {
            process = nil
            stdoutPipe = nil
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        buffer.removeAll()
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
