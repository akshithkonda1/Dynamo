import Accelerate
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Real-time local multi-band EQ amplifier — **full Dolby Atmos + Apple Spatial support**.
///
/// Routing strategy:
/// 1. Prefer a **device-stream process tap** (no mixdown) so multi-channel Atmos beds
///    (5.1 / 7.1 / …) keep their channel count and layout.
/// 2. Fall back to stereo process mixdown for binaural Spatial / stereo renders.
/// 3. Apply path-aware Symphony curves:
///    - **Atmos bed**: mid-side off; LFE uses sub-only EQ; full-range channels share linear EQ
///    - **Spatial binaural**: mid-side off / tiny; preserve elevation HF cues
///    - **Stereo**: gentle mid-side stage when profile asks for it
///
/// Never disables system Spatial/Atmos settings; rides the post-render mix only.
///
/// Seamless transitions match `Tools/DynamoEQ/dynamo_eq.py` (dual-bank crossfade + wet ramps).
@available(macOS 14.2, *)
final class LocalAmplifyEngine: @unchecked Sendable {
    static let shared = LocalAmplifyEngine()

    private let queue = DispatchQueue(label: "com.akshithkonda.Dynamo.localAmplify", qos: .userInteractive)

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()

    /// Active (A) full-range filter chain per channel.
    private var channelFilters: [[Biquad]] = []
    /// Active (A) LFE-only chains (sub/lowshelf) — used on typical LFE index in 5.1/7.1 beds.
    private var lfeFilters: [[Biquad]] = []
    private var makeup: Float = 1.0
    /// Mid-side width 0…0.4 — stereo immersion only (forced 0 on Atmos / Spatial beds).
    private var stereoWidth: Float = 0.0

    /// Target (B) bank during profile/device crossfade; nil when settled.
    private var targetChannelFilters: [[Biquad]]?
    private var targetLFEFilters: [[Biquad]]?
    private var targetMakeup: Float = 1.0
    private var targetStereoWidth: Float = 0.0
    /// 0 = full A, 1 = full B. Advances each sample while transitioning.
    private var crossfadePos: Float = 1.0
    private var crossfadeInc: Float = 0.0

    /// Wet blend: 0 = dry passthrough, 1 = full Symphony EQ (seamless engage/disengage).
    private var wetGain: Float = 0.0
    private var wetTarget: Float = 1.0
    private var wetInc: Float = 0.0
    private var pendingStopAfterWet = false

    /// Default transition lengths — long enough to hide filter swaps, short enough to feel snappy.
    private static let profileTransitionSeconds: Float = 0.09
    private static let engageSeconds: Float = 0.12
    private static let disengageSeconds: Float = 0.08

    private var profileRaw: String = "symphony"
    private var deviceRaw: String = "auto"
    private var preferredBundleID: String?
    /// Content-side Atmos/Spatial hint from now-playing metadata (Music “Dolby Atmos”, etc.).
    private var contentImmersiveHint = false

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var statusLine: String = "Off"
    private(set) var spatialCompatible = true
    private(set) var channelCount: Int = 2
    private(set) var spatialHint: String = ""
    private(set) var deviceHint: String = ""
    private(set) var spatialPath: AmplifySpatialPath = .stereo
    private(set) var tapModeLabel: String = ""

    private init() {}

    func start(
        profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        preferredBundleID: String?,
        contentImmersiveHint: Bool = false
    ) {
        queue.async {
            self.pendingStopAfterWet = false
            self.preferredBundleID = preferredBundleID
            self.profileRaw = profile.rawValue
            self.deviceRaw = device.rawValue
            self.contentImmersiveHint = contentImmersiveHint
            // Instant bank load (not yet audible) — wet ramp engages without a hard edge.
            self.applyProfileLocked(profile, device: device, sampleRate: 48_000, channels: 2, seamless: false)
            self.wetGain = 0
            self.wetTarget = 1
            self.wetInc = 0
            do {
                try self.startLocked()
                self.isRunning = true
                self.lastError = nil
                self.beginWetRamp(to: 1, seconds: Self.engageSeconds)
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
            self.applyProfileLocked(
                profile,
                device: device,
                sampleRate: sr,
                channels: ch,
                seamless: self.isRunning
            )
            if self.isRunning {
                self.statusLine = self.makeStatus(profile: profile)
            }
        }
    }

    /// Update Atmos/Spatial content hint (e.g. track metadata). May retune path without restart.
    func setContentImmersiveHint(_ hint: Bool) {
        queue.async {
            guard self.contentImmersiveHint != hint else { return }
            self.contentImmersiveHint = hint
            self.refreshSpatialPathLocked()
            if self.isRunning, let profile = MediaAmplifyProfile(rawValue: self.profileRaw) {
                let device = AmplifyOutputDevice(rawValue: self.deviceRaw) ?? .auto
                let sr = self.format.mSampleRate > 0 ? self.format.mSampleRate : 48_000
                self.applyProfileLocked(
                    profile,
                    device: device,
                    sampleRate: sr,
                    channels: max(1, self.channelCount),
                    seamless: true
                )
                self.statusLine = self.makeStatus(profile: profile)
            }
        }
    }

    func stop() {
        queue.async {
            guard self.isRunning else {
                self.teardownLocked()
                self.statusLine = "Off"
                self.lastError = nil
                self.spatialHint = ""
                self.spatialPath = .stereo
                self.tapModeLabel = ""
                return
            }
            // Soft disengage so muting the EQ doesn’t click, then tear the graph down.
            self.pendingStopAfterWet = true
            self.beginWetRamp(to: 0, seconds: Self.disengageSeconds)
            self.statusLine = "Fading out…"
        }
    }

    private func makeStatus(profile: MediaAmplifyProfile) -> String {
        var parts = ["\(profile.title)", "Symphony EQ"]
        if !deviceHint.isEmpty {
            parts.append(deviceHint)
        }
        parts.append(spatialPath.statusLabel)
        if channelCount > 2 {
            parts.append("\(channelCount)ch")
        }
        if !tapModeLabel.isEmpty {
            parts.append(tapModeLabel)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Profile / DSP

    private func resolveCurve(
        profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        sampleRate: Double,
        path: AmplifySpatialPath
    ) -> AmplifyEQCurve {
        if let fromPy = DynamoEQPython.coeffs(
            profile: profile.rawValue,
            device: device.rawValue,
            sampleRate: sampleRate,
            path: path.rawValue
        ) {
            return fromPy
        }
        return DynamoEQCurves.curve(for: profile, device: device, sampleRate: sampleRate, path: path)
    }

    private func applyProfileLocked(
        _ profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        sampleRate: Double,
        channels: Int,
        seamless: Bool
    ) {
        let ch = max(1, channels)
        deviceHint = device.statusLabel
        refreshSpatialPathLocked(channels: ch, sampleRate: sampleRate)
        let curve = resolveCurve(profile: profile, device: device, sampleRate: sampleRate, path: spatialPath)
        // Width is path-gated: Atmos / multi-channel never mid-side; Spatial binaural stays dry.
        let width = curve.width * spatialPath.widthScale
        let newFull = (0..<ch).map { _ in curve.filters.map { $0.clone() } }
        let newLFE = (0..<ch).map { _ in curve.lfeFilters.map { $0.clone() } }

        if seamless, isRunning, !channelFilters.isEmpty {
            promoteTargetIfNeeded(force: true)
            targetChannelFilters = newFull
            targetLFEFilters = newLFE
            targetMakeup = curve.makeup
            targetStereoWidth = width
            beginCrossfade(seconds: Self.profileTransitionSeconds)
        } else {
            channelFilters = newFull
            lfeFilters = newLFE
            makeup = curve.makeup
            stereoWidth = width
            targetChannelFilters = nil
            targetLFEFilters = nil
            crossfadePos = 1
            crossfadeInc = 0
        }
        channelCount = ch
    }

    private func refreshSpatialPathLocked(channels: Int? = nil, sampleRate: Double? = nil) {
        let ch = channels ?? max(1, channelCount)
        let sr = sampleRate ?? (format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        spatialPath = AmplifySpatialPath.detect(
            channels: ch,
            sampleRate: sr,
            contentImmersiveHint: contentImmersiveHint,
            deviceRaw: deviceRaw
        )
        spatialHint = spatialPath.statusLabel
        spatialCompatible = true
    }

    private func beginCrossfade(seconds: Float) {
        let sr = Float(format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        let samples = max(1, Int(seconds * sr))
        crossfadePos = 0
        crossfadeInc = 1.0 / Float(samples)
    }

    private func beginWetRamp(to target: Float, seconds: Float) {
        wetTarget = max(0, min(1, target))
        let sr = Float(format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        let samples = max(1, Int(seconds * sr))
        let delta = wetTarget - wetGain
        wetInc = abs(delta) < 1e-6 ? 0 : delta / Float(samples)
        if wetInc == 0 {
            wetGain = wetTarget
            finishPendingStopIfNeeded()
        }
    }

    /// When crossfade completes (or is forced), B becomes A and target is cleared.
    private func promoteTargetIfNeeded(force: Bool = false) {
        guard let target = targetChannelFilters else { return }
        if force || crossfadePos >= 1.0 - 1e-5 {
            channelFilters = target
            if let lfe = targetLFEFilters { lfeFilters = lfe }
            makeup = targetMakeup
            stereoWidth = targetStereoWidth
            targetChannelFilters = nil
            targetLFEFilters = nil
            crossfadePos = 1
            crossfadeInc = 0
        }
    }

    private func finishPendingStopIfNeeded() {
        guard pendingStopAfterWet, wetGain <= 0.001 else { return }
        pendingStopAfterWet = false
        teardownLocked()
        isRunning = false
        statusLine = "Off"
        lastError = nil
        spatialHint = ""
        spatialPath = .stereo
        tapModeLabel = ""
        wetGain = 0
        wetInc = 0
    }

    /// Equal-power crossfade weights (seamless A↔B without mid-fade dips).
    private static func equalPower(_ t: Float) -> (Float, Float) {
        let x = max(0, min(1, t))
        let a = cos(x * Float.pi * 0.5)
        let b = sin(x * Float.pi * 0.5)
        return (a, b)
    }

    // MARK: - Audio graph

    private func startLocked() throws {
        teardownLocked()

        let processIDs = resolveProcessObjectIDs(preferredBundleID: preferredBundleID)
        let outputUID = try defaultOutputDeviceUID()
        let (description, modeLabel) = try makeTapDescription(
            processIDs: processIDs,
            outputUID: outputUID
        )
        tapModeLabel = modeLabel

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        // Device-stream taps can fail on some devices — fall back to stereo mixdown.
        if err != noErr || newTap == kAudioObjectUnknown {
            let fallback = makeStereoFallbackDescription(processIDs: processIDs)
            tapModeLabel = "stereo-mix"
            err = AudioHardwareCreateProcessTap(fallback, &newTap)
            guard err == noErr, newTap != kAudioObjectUnknown else {
                throw AmplifyError.failed("Process tap failed (\(err)) — allow audio capture for Dynamo")
            }
            // Use fallback description UUID for aggregate.
            try finishGraph(with: fallback, tap: newTap, outputUID: outputUID)
            return
        }
        try finishGraph(with: description, tap: newTap, outputUID: outputUID)
    }

    /// Prefer full-channel device-stream tap (Atmos beds). Fallback: stereo mixdown of process.
    private func makeTapDescription(
        processIDs: [AudioObjectID],
        outputUID: String
    ) throws -> (CATapDescription, String) {
        if !processIDs.isEmpty {
            // Device-stream process tap: format matches hardware stream (multi-ch Atmos-ready).
            let desc = CATapDescription(processes: processIDs, deviceUID: outputUID, stream: 0)
            configureTap(desc, name: "Dynamo Amplify EQ (Atmos-ready)")
            desc.isMixdown = false
            desc.isMono = false
            return (desc, "device-stream")
        }
        var exclude: [AudioObjectID] = []
        if let selfObj = audioProcessObjectID(forPID: pid_t(ProcessInfo.processInfo.processIdentifier)) {
            exclude.append(selfObj)
        }
        // Global exclude + device stream when no player PID (still multi-channel capable).
        let desc = CATapDescription(excludingProcesses: exclude, deviceUID: outputUID, stream: 0)
        configureTap(desc, name: "Dynamo Amplify EQ (Atmos global)")
        desc.isMixdown = false
        desc.isMono = false
        return (desc, "global-stream")
    }

    private func makeStereoFallbackDescription(processIDs: [AudioObjectID]) -> CATapDescription {
        let desc: CATapDescription
        if !processIDs.isEmpty {
            desc = CATapDescription(stereoMixdownOfProcesses: processIDs)
            configureTap(desc, name: "Dynamo Amplify EQ (Spatial stereo)")
        } else {
            var exclude: [AudioObjectID] = []
            if let selfObj = audioProcessObjectID(forPID: pid_t(ProcessInfo.processInfo.processIdentifier)) {
                exclude.append(selfObj)
            }
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
            configureTap(desc, name: "Dynamo Amplify EQ (Spatial global)")
        }
        return desc
    }

    private func configureTap(_ description: CATapDescription, name: String) {
        description.uuid = UUID()
        description.name = name
        description.isPrivate = true
        // Mute only while tapped so the user hears our EQ’d feed once (no double path).
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = true
        }
    }

    private func finishGraph(
        with description: CATapDescription,
        tap: AudioObjectID,
        outputUID: String
    ) throws {
        tapID = tap
        format = try readTapStreamDescription(tapID: tapID)

        let sr = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let ch = max(1, Int(format.mChannelsPerFrame != 0 ? format.mChannelsPerFrame : 2))
        channelCount = ch

        let device = AmplifyOutputDevice(rawValue: deviceRaw) ?? .auto
        if let profile = MediaAmplifyProfile(rawValue: profileRaw) {
            applyProfileLocked(profile, device: device, sampleRate: sr, channels: ch, seamless: false)
        } else {
            refreshSpatialPathLocked(channels: ch, sampleRate: sr)
        }

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
        var err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard err == noErr else {
            throw AmplifyError.failed("Aggregate device failed (\(err))")
        }
        aggregateID = agg

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
        for chain in channelFilters { chain.forEach { $0.reset() } }
        for chain in lfeFilters { chain.forEach { $0.reset() } }
        if let target = targetChannelFilters {
            for chain in target { chain.forEach { $0.reset() } }
        }
        if let target = targetLFEFilters {
            for chain in target { chain.forEach { $0.reset() } }
        }
        targetChannelFilters = nil
        targetLFEFilters = nil
        crossfadePos = 1
        crossfadeInc = 0
        wetInc = 0
        pendingStopAfterWet = false
        tapModeLabel = ""
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
                for f in 0..<frames {
                    let wetG = wetGain
                    for c in 0..<nCh {
                        guard let iPtr = inABL[c].mData?.assumingMemoryBound(to: Float.self),
                              let oPtr = outABL[c].mData?.assumingMemoryBound(to: Float.self)
                        else { continue }
                        oPtr[f] = processSample(dry: iPtr[f], channel: c, wet: wetG)
                    }
                    advanceFrameRamps()
                }
                finishPendingStopIfNeeded()
                return
            }

            // Interleaved float — mid-side only on true stereo (never on Atmos multi-ch beds).
            if let outRaw = outABL.first?.mData?.assumingMemoryBound(to: Float.self) {
                let inSamples = inRaw.assumingMemoryBound(to: Float.self)
                let frameCount = bytes / (MemoryLayout<Float>.size * channels)
                let allowMS = spatialPath.allowsMidSide && channels == 2
                for f in 0..<frameCount {
                    let widthNow = allowMS ? currentWidth() : 0
                    let wetG = wetGain
                    if channels >= 2, widthNow > 0.001 {
                        let li = f * channels
                        let ri = li + 1
                        var l = inSamples[li]
                        var r = inSamples[ri]
                        let mid = 0.5 * (l + r)
                        var side = 0.5 * (l - r)
                        side *= (1.0 + widthNow)
                        l = mid + side
                        r = mid - side
                        outRaw[li] = processSample(
                            dry: l, channel: 0, wet: wetG, dryPassthrough: inSamples[li]
                        )
                        outRaw[ri] = processSample(
                            dry: r, channel: 1, wet: wetG, dryPassthrough: inSamples[ri]
                        )
                    } else {
                        for c in 0..<channels {
                            let idx = f * channels + c
                            outRaw[idx] = processSample(dry: inSamples[idx], channel: c, wet: wetG)
                        }
                    }
                    advanceFrameRamps()
                }
                outABL[0].mDataByteSize = inBuf.mDataByteSize
                finishPendingStopIfNeeded()
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
        let fallback = DynamoEQCurves.curve(
            for: .symphony, device: .auto, sampleRate: 48_000, path: spatialPath
        )
        if count > channelFilters.count {
            let template = channelFilters.first ?? fallback.filters
            let lfeTemplate = lfeFilters.first ?? fallback.lfeFilters
            while channelFilters.count < count {
                channelFilters.append(template.map { $0.clone() })
                lfeFilters.append(lfeTemplate.map { $0.clone() })
            }
        }
        if var target = targetChannelFilters, count > target.count {
            let template = target.first ?? fallback.filters
            while target.count < count {
                target.append(template.map { $0.clone() })
            }
            targetChannelFilters = target
        }
        if var targetLFE = targetLFEFilters, count > targetLFE.count {
            let template = targetLFE.first ?? fallback.lfeFilters
            while targetLFE.count < count {
                targetLFE.append(template.map { $0.clone() })
            }
            targetLFEFilters = targetLFE
        }
        channelCount = max(channelFilters.count, targetChannelFilters?.count ?? 0)
    }

    private func silence(_ outABL: UnsafeMutableAudioBufferListPointer) {
        for buf in outABL {
            if let p = buf.mData {
                memset(p, 0, Int(buf.mDataByteSize))
            }
        }
    }

    private func currentWidth() -> Float {
        guard targetChannelFilters != nil else { return stereoWidth }
        let (gA, gB) = Self.equalPower(crossfadePos)
        return stereoWidth * gA + targetStereoWidth * gB
    }

    /// One sample through A (+ B while crossfading), soft-limit, wet-blend with dry.
    /// LFE index (typical 5.1/7.1 layout channel 3) uses sub-only filters so Atmos beds stay clean.
    private func processSample(
        dry: Float,
        channel: Int,
        wet: Float,
        dryPassthrough: Float? = nil
    ) -> Float {
        let isLFE = spatialPath.usesLFERole && AmplifySpatialPath.isLFEChannel(channel, total: channelCount)
        let idx = channelFilters.isEmpty ? 0 : min(channel, channelFilters.count - 1)
        let aChain: [Biquad] = {
            if isLFE, !lfeFilters.isEmpty {
                return lfeFilters[min(channel, lfeFilters.count - 1)]
            }
            return channelFilters.isEmpty ? [] : channelFilters[idx]
        }()

        var yA = dry
        for f in aChain { yA = f.process(yA) }

        var eq: Float
        if let target = targetChannelFilters, !target.isEmpty {
            let tIdx = min(channel, target.count - 1)
            let bChain: [Biquad] = {
                if isLFE, let tl = targetLFEFilters, !tl.isEmpty {
                    return tl[min(channel, tl.count - 1)]
                }
                return target[tIdx]
            }()
            var yB = dry
            for f in bChain { yB = f.process(yB) }
            let (gA, gB) = Self.equalPower(crossfadePos)
            eq = yA * makeup * gA + yB * targetMakeup * gB
        } else {
            eq = yA * makeup
        }

        // Slightly softer ceiling on multi-channel beds to protect headroom across objects.
        eq = softLimit(eq, headroom: spatialPath.softLimitHeadroom)
        let dryOut = dryPassthrough ?? dry
        let mixed = dryOut * (1 - wet) + eq * wet
        return max(-1, min(1, mixed))
    }

    /// Advance crossfade + wet ramps once per audio frame (not per channel).
    private func advanceFrameRamps() {
        if targetChannelFilters != nil, crossfadeInc > 0 {
            crossfadePos = min(1, crossfadePos + crossfadeInc)
            if crossfadePos >= 1 {
                promoteTargetIfNeeded(force: true)
            }
        }
        if wetInc != 0 || abs(wetGain - wetTarget) > 1e-5 {
            wetGain = advanceToward(wetGain, target: wetTarget, inc: &wetInc)
        }
    }

    private func advanceToward(_ value: Float, target: Float, inc: inout Float) -> Float {
        if abs(inc) < 1e-12 {
            return target
        }
        let next = value + inc
        if (inc > 0 && next >= target) || (inc < 0 && next <= target) {
            inc = 0
            return target
        }
        return next
    }

    private func softLimit(_ y: Float, headroom: Float = 0.97) -> Float {
        let thr = max(0.9, min(0.98, headroom))
        var out = y
        if out > thr {
            out = thr + (1 - thr) * tanh((out - thr) * 8)
        } else if out < -thr {
            out = -thr + (1 - thr) * tanh((out + thr) * 8)
        }
        return out
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

// MARK: - Spatial / Atmos path

/// How Symphony EQ should treat the current feed (detected from channels + content + device).
enum AmplifySpatialPath: String, CaseIterable, Identifiable {
    case stereo
    case spatialBinaural
    case atmosBed
    case multichannel

    var id: String { rawValue }

    var statusLabel: String {
        switch self {
        case .stereo: return "Stereo"
        case .spatialBinaural: return "Spatial"
        case .atmosBed: return "Dolby Atmos"
        case .multichannel: return "Surround"
        }
    }

    /// Mid-side imaging only on plain stereo (never re-spatialize Atmos/Spatial).
    var allowsMidSide: Bool { self == .stereo }

    var widthScale: Float {
        switch self {
        case .stereo: return 1.0
        case .spatialBinaural: return 0.0
        case .atmosBed, .multichannel: return 0.0
        }
    }

    var usesLFERole: Bool {
        self == .atmosBed || self == .multichannel
    }

    var softLimitHeadroom: Float {
        switch self {
        case .atmosBed, .multichannel: return 0.94
        case .spatialBinaural: return 0.96
        case .stereo: return 0.97
        }
    }

    /// ITU-ish LFE index for common 5.1 / 7.1 beds (channel 4 = index 3).
    static func isLFEChannel(_ channel: Int, total: Int) -> Bool {
        total >= 6 && channel == 3
    }

    static func detect(
        channels: Int,
        sampleRate: Double,
        contentImmersiveHint: Bool,
        deviceRaw: String
    ) -> AmplifySpatialPath {
        if channels >= 6 {
            return contentImmersiveHint || channels >= 8 ? .atmosBed : .multichannel
        }
        if channels > 2 {
            return .multichannel
        }
        // Stereo feed: Spatial binaural when content is Atmos/Spatial or wireless headphones.
        let device = AmplifyOutputDevice(rawValue: deviceRaw) ?? .auto
        if contentImmersiveHint {
            return .spatialBinaural
        }
        if device == .wireless || device == .headphones, sampleRate >= 44_100 {
            // Likely Spatial-capable headphone path — keep EQ spatial-safe.
            return .spatialBinaural
        }
        return .stereo
    }

    /// Heuristic from now-playing strings (Music “Dolby Atmos”, Spatial badges, etc.).
    static func contentLooksImmersive(title: String, artist: String, album: String) -> Bool {
        let blob = "\(title) \(artist) \(album)".lowercased()
        let keys = [
            "dolby atmos", "atmos", "spatial audio", "spatial",
            "apple digital masters", "360 reality", "mpeg-h", "immersive"
        ]
        return keys.contains { blob.contains($0) }
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

// MARK: - EQ curve payload

struct AmplifyEQCurve {
    var filters: [Biquad]
    /// Sub/lowshelf-only for LFE channels in Atmos/surround beds.
    var lfeFilters: [Biquad]
    var makeup: Float
    var width: Float
}

// MARK: - Embedded curves (match Tools/DynamoEQ/dynamo_eq.py)

enum DynamoEQCurves {
    static func curve(
        for profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        sampleRate: Double,
        path: AmplifySpatialPath = .stereo
    ) -> AmplifyEQCurve {
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

        // Path voicing — Atmos/Spatial keep imaging cues intact.
        switch path {
        case .atmosBed:
            width = 0
            makeupDB = min(makeupDB, 0.35)
            bands = bands.map { kind, freq, gain, q, label in
                var g = gain
                if label == "air" || label == "brilliance" || label == "sheen" {
                    g *= 0.55  // protect height/object HF
                }
                if label == "presence" { g *= 0.75 }
                if label == "sub" || label == "punch" { g *= 0.9 }
                return (kind, freq, g, q, label)
            }
        case .multichannel:
            width = 0
            makeupDB = min(makeupDB, 0.4)
            bands = bands.map { kind, freq, gain, q, label in
                var g = gain
                if label == "air" || label == "brilliance" { g *= 0.7 }
                return (kind, freq, g, q, label)
            }
        case .spatialBinaural:
            width = 0
            makeupDB = min(makeupDB, 0.4)
            bands = bands.map { kind, freq, gain, q, label in
                var g = gain
                // Soften top end so Spatial elevation / pinna cues survive.
                if label == "air" || label == "brilliance" || label == "sheen" {
                    g *= 0.5
                }
                if label == "presence" { g *= 0.85 }
                return (kind, freq, g, q, label)
            }
        case .stereo:
            break
        }

        let filters = bands.map { kind, freq, gain, q, _ -> Biquad in
            switch kind {
            case "lowshelf": return lowshelf(sr: sr, freq: freq, gainDB: gain, q: q)
            case "highshelf": return highshelf(sr: sr, freq: freq, gainDB: gain, q: q)
            default: return peaking(sr: sr, freq: freq, gainDB: gain, q: q)
            }
        }
        // LFE: only low shelves / sub-region peaks under ~150 Hz.
        let lfeFilters = bands.compactMap { kind, freq, gain, q, _ -> Biquad? in
            guard freq <= 150 || kind == "lowshelf" else { return nil }
            switch kind {
            case "lowshelf": return lowshelf(sr: sr, freq: freq, gainDB: gain * 0.85, q: q)
            default: return peaking(sr: sr, freq: min(freq, 120), gainDB: gain * 0.7, q: q)
            }
        }
        let makeup = pow(10.0, makeupDB / 20.0)
        return AmplifyEQCurve(
            filters: filters,
            lfeFilters: lfeFilters.isEmpty ? [lowshelf(sr: sr, freq: 80, gainDB: 0, q: 0.7)] : lfeFilters,
            makeup: makeup,
            width: width
        )
    }

    /// Back-compat helper for tests.
    static func filters(
        for profile: MediaAmplifyProfile,
        device: AmplifyOutputDevice,
        sampleRate: Double
    ) -> (filters: [Biquad], makeup: Float, width: Float) {
        let c = curve(for: profile, device: device, sampleRate: sampleRate, path: .stereo)
        return (c.filters, c.makeup, c.width)
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
    static func coeffs(
        profile: String,
        device: String,
        sampleRate: Double,
        path: String = "stereo"
    ) -> AmplifyEQCurve? {
        let script = scriptURL()
        guard FileManager.default.isReadableFile(atPath: script.path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [
            script.path, "coeffs",
            "--profile", profile,
            "--device", device,
            "--path", path,
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
        func parse(_ arr: [[String: Any]]) -> [Biquad] {
            var out: [Biquad] = []
            for b in arr {
                guard let b0 = b["b0"] as? Double,
                      let b1 = b["b1"] as? Double,
                      let b2 = b["b2"] as? Double,
                      let a1 = b["a1"] as? Double,
                      let a2 = b["a2"] as? Double
                else { continue }
                out.append(Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2), a1: Float(a1), a2: Float(a2)))
            }
            return out
        }
        let filters = parse(biquads)
        guard !filters.isEmpty else { return nil }
        let lfeArr = (json["lfe_biquads"] as? [[String: Any]]) ?? []
        var lfe = parse(lfeArr)
        if lfe.isEmpty {
            // Fallback: first filter only if it looks low-shelf-ish (b0~1) — else identity-ish lowshelf from curve.
            lfe = Array(filters.prefix(1))
        }
        let makeup = Float((json["makeup"] as? Double) ?? 1.0)
        let width = Float((json["width"] as? Double) ?? 0.0)
        return AmplifyEQCurve(filters: filters, lfeFilters: lfe, makeup: makeup, width: width)
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
