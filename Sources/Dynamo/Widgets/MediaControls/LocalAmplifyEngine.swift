import Accelerate
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Real-time local multi-band EQ amplifier — **Atmos / Spatial Audio compatible**.
///
/// Design for Dolby Atmos & Apple Spatial Audio:
/// - Taps the **post-render** player mix (after Atmos → Spatial headphone/speaker render)
/// - Mutes only the tapped process while we re-output the **EQ’d multi-channel feed**
/// - Applies the **same linear EQ per channel** (no mono fold, no mid/side collapse)
/// - Preserves channel count / layout from the tap (stereo, 5.1, 7.1, etc.)
/// - Does not change device sample rate, Spatial settings, or force stereo-only I/O
///
/// Curves match `Tools/DynamoEQ/dynamo_eq.py` (pure local DSP, no network APIs).
@available(macOS 14.2, *)
final class LocalAmplifyEngine: @unchecked Sendable {
    static let shared = LocalAmplifyEngine()

    private let queue = DispatchQueue(label: "com.akshithkonda.Dynamo.localAmplify", qos: .userInteractive)

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()

    /// One filter chain per channel (identical coefficients, independent state).
    private var channelFilters: [[Biquad]] = []
    private var makeup: Float = 1.0
    /// Mid-side width 0…0.4 — immersive stage for headphones/speakers (stereo only).
    private var stereoWidth: Float = 0.0
    private var profileRaw: String = "symphony"
    private var deviceRaw: String = "auto"
    private var preferredBundleID: String?

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var statusLine: String = "Off"
    private(set) var spatialCompatible = true
    private(set) var channelCount: Int = 2
    private(set) var spatialHint: String = ""
    private(set) var deviceHint: String = ""

    private init() {}

    func start(
        profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        preferredBundleID: String?
    ) {
        queue.async {
            self.preferredBundleID = preferredBundleID
            self.profileRaw = profile.rawValue
            self.deviceRaw = device.rawValue
            self.applyProfileLocked(profile, device: device, sampleRate: 48_000, channels: 2)
            do {
                try self.startLocked()
                self.isRunning = true
                self.lastError = nil
                self.statusLine = self.makeStatus(profile: profile)
            } catch {
                self.isRunning = false
                self.lastError = error.localizedDescription
                self.statusLine = "\(profile.title) · EQ error"
                self.teardownLocked()
            }
        }
    }

    func setProfile(_ profile: MediaAmplifyProfile, device: AmplifyOutputDevice) {
        queue.async {
            self.profileRaw = profile.rawValue
            self.deviceRaw = device.rawValue
            let sr = self.format.mSampleRate > 0 ? self.format.mSampleRate : 48_000
            let ch = max(2, self.channelCount)
            self.applyProfileLocked(profile, device: device, sampleRate: sr, channels: ch)
            if self.isRunning {
                self.statusLine = self.makeStatus(profile: profile)
            }
        }
    }

    func stop() {
        queue.async {
            self.teardownLocked()
            self.isRunning = false
            self.statusLine = "Off"
            self.lastError = nil
            self.spatialHint = ""
        }
    }

    private func makeStatus(profile: MediaAmplifyProfile) -> String {
        var parts = ["\(profile.title)", "Symphony EQ"]
        if !deviceHint.isEmpty {
            parts.append(deviceHint)
        }
        if !spatialHint.isEmpty {
            parts.append(spatialHint)
        }
        if channelCount > 2 {
            parts.append("\(channelCount)ch")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Profile / DSP

    private func applyProfileLocked(
        _ profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        sampleRate: Double,
        channels: Int
    ) {
        let ch = max(1, channels)
        deviceHint = device.statusLabel
        if let fromPy = DynamoEQPython.coeffs(
            profile: profile.rawValue,
            device: device.rawValue,
            sampleRate: sampleRate
        ) {
            makeup = fromPy.makeup
            stereoWidth = fromPy.width
            channelFilters = (0..<ch).map { _ in fromPy.filters.map { $0.clone() } }
        } else {
            let built = DynamoEQCurves.filters(for: profile, device: device, sampleRate: sampleRate)
            makeup = built.makeup
            stereoWidth = built.width
            channelFilters = (0..<ch).map { _ in built.filters.map { $0.clone() } }
        }
        channelCount = ch
    }

    // MARK: - Audio graph

    private func startLocked() throws {
        teardownLocked()

        let processIDs = resolveProcessObjectIDs(preferredBundleID: preferredBundleID)
        let description: CATapDescription
        if !processIDs.isEmpty {
            // Stereo mixdown of the *rendered* player output — post Atmos→Spatial
            // virtualization when the player already spatialized to the device.
            description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        } else {
            var exclude: [AudioObjectID] = []
            if let selfObj = audioProcessObjectID(forPID: pid_t(ProcessInfo.processInfo.processIdentifier)) {
                exclude.append(selfObj)
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        }
        description.uuid = UUID()
        description.name = "Dynamo Amplify EQ (Spatial-safe)"
        description.isPrivate = true
        // Mute only while tapped so the user hears our EQ’d feed once (no double path).
        description.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        guard err == noErr, newTap != kAudioObjectUnknown else {
            throw AmplifyError.failed("Process tap failed (\(err)) — allow audio capture for Dynamo")
        }
        tapID = newTap
        format = try readTapStreamDescription(tapID: tapID)

        let sr = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let ch = max(1, Int(format.mChannelsPerFrame != 0 ? format.mChannelsPerFrame : 2))
        channelCount = ch
        spatialHint = Self.detectSpatialHint(channels: ch, sampleRate: sr)
        spatialCompatible = true

        let device = AmplifyOutputDevice(rawValue: deviceRaw) ?? .auto
        if let profile = MediaAmplifyProfile(rawValue: profileRaw) {
            applyProfileLocked(profile, device: device, sampleRate: sr, channels: ch)
        }

        let outputUID = try defaultOutputDeviceUID()
        // Private aggregate: default output + process tap. Does not steal Spatial
        // configuration from the system device — we only ride its mix.
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamoAmplifyEQ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard err == noErr else {
            throw AmplifyError.failed("Aggregate device failed (\(err))")
        }
        aggregateID = agg

        // Signature matches Core Audio IO proc block (same as MusicAudioSampler).
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, outOutputData, _ in
            self?.render(input: inInputData, output: outOutputData)
        }
        guard err == noErr else {
            throw AmplifyError.failed("IO proc failed (\(err))")
        }
        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            throw AmplifyError.failed("Device start failed (\(err))")
        }
    }

    /// Soft Spatial / Atmos awareness for status (does not disable Spatial Audio).
    private static func detectSpatialHint(channels: Int, sampleRate: Double) -> String {
        // Multi-channel bed often accompanies Atmos / surround output paths.
        if channels >= 6 { return "Atmos/surround bed" }
        if channels > 2 { return "Multi-channel" }
        // High-rate stereo is common after Spatial headphone render.
        if sampleRate >= 48_000 { return "Spatial-ready" }
        return "Stereo"
    }

    private func teardownLocked() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        for chain in channelFilters {
            chain.forEach { $0.reset() }
        }
    }

    /// Process every channel with the same EQ curve (preserves spatial image / bed).
    private func render(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>?) {
        guard let input, let output else { return }
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        guard let inBuf = inABL.first, let inRaw = inBuf.mData, inBuf.mDataByteSize > 0 else {
            silence(outABL)
            return
        }

        let channels = max(1, Int(format.mChannelsPerFrame != 0 ? format.mChannelsPerFrame : inBuf.mNumberChannels))
        ensureChannelFilters(count: max(channels, inABL.count))

        let isFloat = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytes = Int(inBuf.mDataByteSize)
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat {
            if nonInterleaved, inABL.count >= 1 {
                let frames = bytes / MemoryLayout<Float>.size
                let nCh = min(inABL.count, outABL.count, channelFilters.count)
                for c in 0..<nCh {
                    guard let iPtr = inABL[c].mData?.assumingMemoryBound(to: Float.self),
                          let oPtr = outABL[c].mData?.assumingMemoryBound(to: Float.self)
                    else { continue }
                    let filters = channelFilters[c]
                    for f in 0..<frames {
                        oPtr[f] = process(iPtr[f], filters: filters)
                    }
                    outABL[c].mDataByteSize = inABL[c].mDataByteSize
                }
                return
            }

            // Interleaved float — stereo path uses mid-side width for “symphony” stage.
            if let outRaw = outABL.first?.mData?.assumingMemoryBound(to: Float.self) {
                let inSamples = inRaw.assumingMemoryBound(to: Float.self)
                let frameCount = bytes / (MemoryLayout<Float>.size * channels)
                let w = stereoWidth
                for f in 0..<frameCount {
                    if channels >= 2, w > 0.001 {
                        let li = f * channels
                        let ri = li + 1
                        var l = inSamples[li]
                        var r = inSamples[ri]
                        // Mid-side encode → widen → decode (preserves mono bass)
                        let mid = 0.5 * (l + r)
                        var side = 0.5 * (l - r)
                        side *= (1.0 + w)
                        l = mid + side
                        r = mid - side
                        let fl = channelFilters[0]
                        let fr = channelFilters[min(1, channelFilters.count - 1)]
                        outRaw[li] = process(l, filters: fl)
                        outRaw[ri] = process(r, filters: fr)
                        for c in 2..<channels {
                            let idx = f * channels + c
                            let chain = channelFilters[min(c, channelFilters.count - 1)]
                            outRaw[idx] = process(inSamples[idx], filters: chain)
                        }
                    } else {
                        for c in 0..<channels {
                            let idx = f * channels + c
                            let chain = channelFilters[min(c, channelFilters.count - 1)]
                            outRaw[idx] = process(inSamples[idx], filters: chain)
                        }
                    }
                }
                outABL[0].mDataByteSize = inBuf.mDataByteSize
            }
        } else {
            // Unexpected format: bit-copy (never mute user to silence on exotic streams).
            if let outRaw = outABL.first?.mData {
                memcpy(outRaw, inRaw, bytes)
                outABL[0].mDataByteSize = inBuf.mDataByteSize
            }
        }
    }

    private func ensureChannelFilters(count: Int) {
        guard count > channelFilters.count else { return }
        let template = channelFilters.first
            ?? DynamoEQCurves.filters(for: .cinema, device: .auto, sampleRate: 48_000).filters
        while channelFilters.count < count {
            channelFilters.append(template.map { $0.clone() })
        }
        channelCount = channelFilters.count
    }

    private func silence(_ outABL: UnsafeMutableAudioBufferListPointer) {
        for buf in outABL {
            if let p = buf.mData {
                memset(p, 0, Int(buf.mDataByteSize))
            }
        }
    }

    private func process(_ x: Float, filters: [Biquad]) -> Float {
        var y = x
        for f in filters {
            y = f.process(y)
        }
        y *= makeup
        // Soft limiter — stereo-linked would need max(|L|,|R|); per-channel soft clip
        // is milder on spatial beds and avoids hard mono coupling.
        if y > 0.97 {
            y = 0.97 + 0.03 * tanh((y - 0.97) * 8)
        } else if y < -0.97 {
            y = -0.97 + 0.03 * tanh((y + 0.97) * 8)
        }
        return max(-1, min(1, y))
    }

    // MARK: - Core Audio helpers

    private func resolveProcessObjectIDs(preferredBundleID: String?) -> [AudioObjectID] {
        let apps = NSWorkspace.shared.runningApplications
        var bundle: String? = preferredBundleID
        if bundle == nil {
            if apps.contains(where: { $0.bundleIdentifier == "com.apple.Music" && !$0.isTerminated }) {
                bundle = "com.apple.Music"
            } else if apps.contains(where: { $0.bundleIdentifier == "com.spotify.client" && !$0.isTerminated }) {
                bundle = "com.spotify.client"
            }
        }
        guard let bundle,
              let app = apps.first(where: { $0.bundleIdentifier == bundle && !$0.isTerminated }),
              let obj = audioProcessObjectID(forPID: app.processIdentifier)
        else { return [] }
        return [obj]
    }

    private func audioProcessObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidCopy = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &pidCopy) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        guard err == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr else { throw AmplifyError.failed("No default output") }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw AmplifyError.failed("No output UID") }
        return uid as String
    }

    private func readTapStreamDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr else { throw AmplifyError.failed("Tap format (\(err))") }
        return asbd
    }
}

// MARK: - Biquad

final class Biquad {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    func reset() {
        z1 = 0
        z2 = 0
    }

    func clone() -> Biquad {
        Biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }
}

// MARK: - Output device voicing (symphony path)

enum AmplifyOutputDevice: String, CaseIterable, Identifiable {
    case auto
    case headphones
    case wireless
    case speakers
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .headphones: return "Headphones (wired)"
        case .wireless: return "Wireless / BT"
        case .speakers: return "Mac speakers"
        case .external: return "External speakers"
        }
    }

    var statusLabel: String {
        switch self {
        case .auto: return "Auto"
        case .headphones: return "Wired"
        case .wireless: return "Wireless"
        case .speakers: return "Speakers"
        case .external: return "External"
        }
    }

    /// Infer from system output device name (AirPods, Bluetooth, Built-in, …).
    static func infer(fromDeviceName name: String?) -> AmplifyOutputDevice {
        guard let n = name?.lowercased(), !n.isEmpty else { return .auto }
        if n.contains("airpod") || n.contains("bluetooth") || n.contains("beats")
            || n.contains("galaxy buds") || n.contains("wf-") || n.contains("wh-") {
            return .wireless
        }
        if n.contains("headphone") || n.contains("headset") || n.contains("earphone") {
            return .headphones
        }
        if n.contains("built-in") || n.contains("macbook") || n.contains("imac")
            || n.contains("internal") {
            return .speakers
        }
        if n.contains("speaker") || n.contains("soundbar") || n.contains("homePod")
            || n.contains("homepod") || n.contains("display") || n.contains("hdmi")
            || n.contains("usb") || n.contains("dac") {
            return .external
        }
        return .auto
    }
}

// MARK: - Embedded curves (match Tools/DynamoEQ/dynamo_eq.py)

enum DynamoEQCurves {
    static func filters(
        for profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        sampleRate: Double
    ) -> (filters: [Biquad], makeup: Float, width: Float) {
        let sr = Float(sampleRate)
        var bands: [(String, Float, Float, Float, String)] // kind, freq, gain, q, label
        var makeupDB: Float
        var width: Float = 0.08

        switch profile {
        case .presence:
            bands = [
                ("lowshelf", 90, -1.2, 0.7, "sub"),
                ("peak", 350, -1.0, 0.9, "body"),
                ("peak", 1800, 2.8, 1.1, "presence"),
                ("peak", 3500, 2.2, 1.0, "air"),
                ("highshelf", 8000, 1.8, 0.7, "brilliance")
            ]
            makeupDB = 0.35
        case .cinema:
            bands = [
                ("lowshelf", 70, 2.4, 0.7, "sub"),
                ("peak", 250, 0.8, 0.9, "warmth"),
                ("peak", 900, -1.8, 1.0, "mud"),
                ("peak", 3200, 1.4, 1.0, "presence"),
                ("highshelf", 9000, 2.2, 0.7, "air")
            ]
            makeupDB = 0.5
        case .impact:
            bands = [
                ("lowshelf", 60, 3.8, 0.7, "sub"),
                ("peak", 110, 2.6, 1.0, "punch"),
                ("peak", 220, 1.5, 1.0, "body"),
                ("peak", 800, -1.2, 0.9, "mud"),
                ("highshelf", 7000, 1.0, 0.7, "air")
            ]
            makeupDB = 0.65
        case .symphony:
            bands = [
                ("lowshelf", 65, 2.0, 0.7, "sub"),
                ("peak", 180, 1.2, 0.95, "body"),
                ("peak", 700, -1.4, 1.0, "mud"),
                ("peak", 2200, 2.0, 1.05, "presence"),
                ("peak", 4500, 1.3, 1.0, "sheen"),
                ("highshelf", 10000, 1.6, 0.7, "air")
            ]
            makeupDB = 0.45
            width = 0.12
        }

        // Device voicing — “you are there” on each transducer type
        let bias: [String: Float]
        switch device {
        case .headphones:
            bias = ["presence": 1.2, "air": 1.4, "brilliance": 1.0, "sub": -0.4]
            width = max(width, 0.12)
        case .wireless:
            bias = ["sub": 0.6, "presence": 0.9, "air": 0.5, "mud": -0.5, "punch": 0.8]
            width = max(width, 0.08)
            makeupDB += 0.15
        case .speakers:
            bias = ["sub": 0.8, "body": 0.6, "mud": -0.8, "presence": 0.7]
            width = max(width, 0.05)
        case .external:
            bias = ["sub": 1.0, "presence": 0.5, "air": 0.6, "mud": -0.6]
            width = max(width, 0.10)
        case .auto:
            bias = [:]
        }
        bands = bands.map { kind, freq, gain, q, label in
            (kind, freq, gain + (bias[label] ?? 0), q, label)
        }

        let filters = bands.map { kind, freq, gain, q, _ -> Biquad in
            switch kind {
            case "lowshelf": return lowshelf(sr: sr, freq: freq, gainDB: gain, q: q)
            case "highshelf": return highshelf(sr: sr, freq: freq, gainDB: gain, q: q)
            default: return peaking(sr: sr, freq: freq, gainDB: gain, q: q)
            }
        }
        let makeup = pow(10.0, makeupDB / 20.0)
        return (filters, makeup, width)
    }

    private static func peaking(sr: Float, freq: Float, gainDB: Float, q: Float) -> Biquad {
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Float.pi * (freq / sr)
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2 * max(q, 0.05))
        let b0 = 1 + alpha * a
        let b1 = -2 * cosw
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosw
        let a2 = 1 - alpha / a
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func lowshelf(sr: Float, freq: Float, gainDB: Float, q: Float) -> Biquad {
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Float.pi * (freq / sr)
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2 * max(q, 0.05))
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
        let b2 = a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha)
        let a0 = (a + 1) + (a - 1) * cosw + twoSqrtAAlpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosw)
        let a2 = (a + 1) + (a - 1) * cosw - twoSqrtAAlpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func highshelf(sr: Float, freq: Float, gainDB: Float, q: Float) -> Biquad {
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Float.pi * (freq / sr)
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2 * max(q, 0.05))
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
        let b2 = a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha)
        let a0 = (a + 1) - (a - 1) * cosw + twoSqrtAAlpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosw)
        let a2 = (a + 1) - (a - 1) * cosw - twoSqrtAAlpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

// MARK: - Optional Python coeff load (offline designer, no network)

enum DynamoEQPython {
    struct Result {
        var filters: [Biquad]
        var makeup: Float
        var width: Float
    }

    static func coeffs(profile: String, device: String, sampleRate: Double) -> Result? {
        let script = scriptURL()
        guard FileManager.default.isReadableFile(atPath: script.path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [
            script.path, "coeffs",
            "--profile", profile,
            "--device", device,
            "--sr", String(sampleRate)
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let biquads = json["biquads"] as? [[String: Any]]
        else { return nil }
        var filters: [Biquad] = []
        for b in biquads {
            guard let b0 = b["b0"] as? Double,
                  let b1 = b["b1"] as? Double,
                  let b2 = b["b2"] as? Double,
                  let a1 = b["a1"] as? Double,
                  let a2 = b["a2"] as? Double
            else { continue }
            filters.append(Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2), a1: Float(a1), a2: Float(a2)))
        }
        guard !filters.isEmpty else { return nil }
        let makeup = Float((json["makeup"] as? Double) ?? 1.0)
        let width = Float((json["width"] as? Double) ?? 0.0)
        return Result(filters: filters, makeup: makeup, width: width)
    }

    private static func scriptURL() -> URL {
        if let res = Bundle.main.url(forResource: "dynamo_eq", withExtension: "py") {
            return res
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Tools/DynamoEQ/dynamo_eq.py"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/Dynamo/Tools/DynamoEQ/dynamo_eq.py")
        ]
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) } ?? candidates[0]
    }
}

private enum AmplifyError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}
