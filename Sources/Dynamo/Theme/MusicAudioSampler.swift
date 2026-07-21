import Accelerate
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Samples the song currently playing (Core Audio process / global tap on
/// macOS 14.2+) and publishes a **perceptual spectrum** + **beat kick** so the
/// peek equalizer follows the real tone and rhythm of the track.
@MainActor
final class MusicAudioSampler: ObservableObject {
    static let shared = MusicAudioSampler()

    static let bandCount = 36

    /// 0…1 magnitudes, low → high (bass left, air right).
    @Published private(set) var bands: [Float] = Array(repeating: 0.1, count: bandCount)
    /// 0…1 onset / kick strength (sharp attack, musical decay).
    @Published private(set) var kick: Float = 0
    /// 0…1 overall loudness.
    @Published private(set) var level: Float = 0
    /// 0…1 spectral brightness (low = dark/bass-heavy, high = bright/trebly).
    @Published private(set) var brightness: Float = 0.45
    /// Continuous 0…1 phase within the current beat (0 = downbeat).
    /// Prefer `phase(at:)` — this is a snapshot for observers.
    @Published private(set) var beatPhase: Float = 0
    /// Detected tempo from onsets (falls back ~120).
    @Published private(set) var detectedBPM: Double = 120
    /// Wall-clock anchor of last downbeat (for continuous phase in views).
    @Published private(set) var beatAnchor: TimeInterval = 0
    /// Seconds per beat from tempo tracking.
    @Published private(set) var beatPeriod: TimeInterval = 0.5
    /// Wall-clock of last onset (for kick envelope interpolation).
    @Published private(set) var lastOnsetAt: TimeInterval = 0
    /// Whether live PCM is driving the EQ.
    @Published private(set) var isLive: Bool = false
    @Published private(set) var status: String = "Idle"

    /// Continuous beat phase at any wall-clock time (does not wait for next FFT frame).
    /// Uses the same reference epoch as the analysis engine (`CFAbsoluteTime` /
    /// `timeIntervalSinceReferenceDate`) so phase never freezes between FFT hops.
    func phase(at date: Date = Date()) -> Float {
        guard beatPeriod > 0.05, beatAnchor > 0 else { return beatPhase }
        let now = date.timeIntervalSinceReferenceDate
        var t = now - beatAnchor
        // If the main-thread snapshot lags slightly behind wall clock, don't clamp
        // phase to 0 — keep free-running on the last known grid.
        if t < 0 { t = 0 }
        let p = t.truncatingRemainder(dividingBy: beatPeriod) / beatPeriod
        return Float(min(1, max(0, p)))
    }

    /// Kick envelope from last onset + predicted grid hits (smooth between frames).
    /// Pure time-based — never maxes with a stale published `kick` (that held bars
    /// high between FFT frames and destroyed the rhythm pulse).
    func kickEnvelope(at date: Date = Date()) -> Float {
        let now = date.timeIntervalSinceReferenceDate
        var onsetEnv: Double = 0
        if lastOnsetAt > 0 {
            let dt = now - lastOnsetAt
            if dt >= 0 {
                // ~70ms visual attack, sharp musical decay.
                onsetEnv = exp(-dt * 16.0)
            }
        }
        // Predicted downbeat pulse so rhythm keeps pumping when onsets miss.
        var gridEnv: Double = 0
        if beatPeriod > 0.05, beatAnchor > 0 {
            let p = Double(phase(at: date))
            let near = min(p, 1 - p)
            gridEnv = exp(-(near * near) * 110) * max(0.25, Double(level))
        }
        return Float(min(1, max(onsetEnv, gridEnv * 0.85)))
    }

    /// Opaque retain of SamplerEngine (macOS 14.2+) — typed storage is unavailable on 13.
    private var engineRetain: AnyObject?
    private var engineStop: (() -> Void)?
    private var wantsRunning = false
    private var preferredBundleID: String?

    private init() {}

    func setActive(_ active: Bool, preferredBundleID: String? = nil) {
        wantsRunning = active
        if let preferredBundleID { self.preferredBundleID = preferredBundleID }
        if active {
            startIfNeeded()
        } else {
            stop()
        }
    }

    func refreshTarget(preferredBundleID: String?) {
        let previous = self.preferredBundleID
        if let preferredBundleID { self.preferredBundleID = preferredBundleID }
        guard wantsRunning else { return }
        // Retarget when player changes (Music ↔ Spotify) or tap never came live.
        let playerChanged = preferredBundleID != nil && preferredBundleID != previous
        if playerChanged, engineRetain != nil {
            stopEngineOnly()
            isLive = false
            startIfNeeded()
            return
        }
        if engineRetain == nil || !isLive {
            startIfNeeded()
        }
    }

    private func startIfNeeded() {
        if #available(macOS 14.2, *) {
            // Already spinning up / live — don't tear down and recreate.
            if engineRetain != nil { return }
            requestPermissionIfNeeded { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.wantsRunning else { return }
                    guard granted else {
                        self.status = "Audio access denied"
                        self.isLive = false
                        return
                    }
                    self.launchEngine()
                }
            }
        } else {
            status = "Needs macOS 14.2+ for live audio"
            isLive = false
        }
    }

    @available(macOS 14.2, *)
    private func launchEngine() {
        // Avoid thrashing if already running (even before first FFT frame).
        if engineRetain != nil { return }
        stopEngineOnly()

        let engine = SamplerEngine(bandCount: Self.bandCount)
        engine.onFrame = { [weak self] bands, kick, level, brightness, beatPhase, bpm, anchor, period, onset in
            // Main hop for UI. Phase free-runs from anchors between frames.
            DispatchQueue.main.async {
                guard let self else { return }
                self.bands = bands
                self.kick = kick
                self.level = level
                self.brightness = brightness
                self.beatPhase = beatPhase
                self.detectedBPM = bpm
                self.beatAnchor = anchor
                self.beatPeriod = period
                self.lastOnsetAt = onset
                self.isLive = true
                self.status = "Live"
            }
        }
        engine.onStopped = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                self.isLive = false
                self.status = reason
                self.kick *= 0.4
                // Drop retain so a later startIfNeeded can rebuild the tap.
                if self.engineRetain != nil {
                    self.engineStop = nil
                    self.engineRetain = nil
                }
            }
        }
        do {
            try engine.start(preferredBundleID: preferredBundleID)
            engineRetain = engine
            engineStop = { engine.stop() }
            status = "Starting…"
        } catch {
            status = error.localizedDescription
            isLive = false
            engineRetain = nil
            engineStop = nil
        }
    }

    private func stop() {
        stopEngineOnly()
        isLive = false
        kick = 0
        level = 0
        brightness = 0.45
        beatPhase = 0
        beatAnchor = 0
        beatPeriod = 0.5
        lastOnsetAt = 0
        detectedBPM = 120
        bands = Array(repeating: 0.1, count: Self.bandCount)
        status = "Idle"
    }

    private func stopEngineOnly() {
        engineStop?()
        engineStop = nil
        engineRetain = nil
    }

    private func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        // Process taps share the recording privacy path on recent macOS.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}

// MARK: - Engine

@available(macOS 14.2, *)
private final class SamplerEngine: @unchecked Sendable {
    /// bands, kick, level, brightness, beatPhase, bpm, anchor, period, lastOnset
    var onFrame: (([Float], Float, Float, Float, Float, Double, TimeInterval, TimeInterval, TimeInterval) -> Void)?
    var onStopped: ((String) -> Void)?

    private let bandCount: Int
    private let fftSize = 2048
    private let analysisQueue = DispatchQueue(
        label: "com.akshithkonda.Dynamo.audioSpectrum",
        qos: .userInteractive
    )

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()

    private var ring: [Float]
    private var ringWrite = 0
    private var ringFilled = 0
    private let ringLock = NSLock()

    private var window: [Float]
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    private var prevMags: [Float]
    private var smoothBands: [Float]
    private var longFlux: Float = 0.02
    private var longBass: Float = 0.02
    private var kickEnvelope: Float = 0
    private var agcGain: Float = 1.0
    private var analysisTimer: DispatchSourceTimer?

    // Beat / tempo tracking (onset-locked phase grid)
    /// Recent inter-onset intervals (seconds) for tempo median.
    private var onsetIntervals: [Double] = []
    private var lastOnsetTime: CFAbsoluteTime = 0
    private var beatInterval: Double = 0.5 // 120 BPM default
    private var beatAnchor: CFAbsoluteTime = 0
    private var trackedBPM: Double = 120
    /// Pending phase error for soft lock (avoids hard jumps mid-bar).
    private var phaseErrorSlew: Double = 0

    init(bandCount: Int) {
        self.bandCount = bandCount
        self.smoothBands = Array(repeating: 0.1, count: bandCount)
        self.prevMags = Array(repeating: 0, count: 1024)
        self.ring = Array(repeating: 0, count: 2048 * 6)
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func start(preferredBundleID: String?) throws {
        // Prefer the active player process; fall back to system mix (exclude Dynamo).
        let processIDs = Self.resolveProcessObjectIDs(preferredBundleID: preferredBundleID)
        let description: CATapDescription
        if !processIDs.isEmpty {
            // Swift overlay expects [AudioObjectID], not NSNumber.
            description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        } else {
            var exclude: [AudioObjectID] = []
            if let selfObj = Self.audioProcessObjectID(
                forPID: pid_t(ProcessInfo.processInfo.processIdentifier)
            ) {
                exclude.append(selfObj)
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        }
        description.uuid = UUID()
        description.name = "Dynamo Music Peek Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        guard err == noErr, newTap != kAudioObjectUnknown else {
            throw SamplerError.failed("Audio tap failed (\(err))")
        }
        tapID = newTap
        format = try Self.readTapStreamDescription(tapID: tapID)

        let outputUID = try Self.defaultOutputDeviceUID()
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamoPeekTap",
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
            throw SamplerError.failed("Aggregate device failed (\(err))")
        }
        aggregateID = agg

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, analysisQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.ingest(input: inInputData)
        }
        guard err == noErr else {
            throw SamplerError.failed("IO proc failed (\(err))")
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            throw SamplerError.failed("Device start failed (\(err))")
        }

        startAnalysisLoop()
    }

    func stop() {
        analysisTimer?.cancel()
        analysisTimer = nil

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
    }

    // MARK: Ingest

    private func ingest(input: UnsafePointer<AudioBufferList>?) {
        guard let input else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // Prefer first buffer; mix channels to mono float.
        guard let buf = abl.first, let raw = buf.mData, buf.mDataByteSize > 0 else { return }

        let bytes = Int(buf.mDataByteSize)
        let channels = max(1, Int(format.mChannelsPerFrame != 0 ? format.mChannelsPerFrame : buf.mNumberChannels))
        let isFloat = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        ringLock.lock()
        defer { ringLock.unlock() }
        let capacity = ring.count

        if isFloat {
            let frameCount = bytes / (MemoryLayout<Float>.size * max(1, channels))
            let samples = raw.assumingMemoryBound(to: Float.self)
            // Non-interleaved: mNumberChannels often 1 per buffer; use abl count.
            if abl.count > 1, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                let frames = bytes / MemoryLayout<Float>.size
                let ch0 = samples
                let ch1 = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
                for f in 0..<frames {
                    var mono = ch0[f]
                    if let ch1 { mono = (mono + ch1[f]) * 0.5 }
                    ring[ringWrite] = mono
                    ringWrite = (ringWrite + 1) % capacity
                    ringFilled = min(capacity, ringFilled + 1)
                }
            } else {
                for f in 0..<frameCount {
                    var mono: Float = 0
                    for c in 0..<channels {
                        mono += samples[f * channels + c]
                    }
                    mono /= Float(channels)
                    ring[ringWrite] = mono
                    ringWrite = (ringWrite + 1) % capacity
                    ringFilled = min(capacity, ringFilled + 1)
                }
            }
        } else {
            // Int16 interleaved fallback
            let frameCount = bytes / (MemoryLayout<Int16>.size * max(1, channels))
            let samples = raw.assumingMemoryBound(to: Int16.self)
            for f in 0..<frameCount {
                var mono: Float = 0
                for c in 0..<channels {
                    mono += Float(samples[f * channels + c]) / 32768.0
                }
                mono /= Float(channels)
                ring[ringWrite] = mono
                ringWrite = (ringWrite + 1) % capacity
                ringFilled = min(capacity, ringFilled + 1)
            }
        }
    }

    private func startAnalysisLoop() {
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        // ~60 fps analysis for tight beat lock (UI free-runs phase between frames).
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.analyze() }
        timer.resume()
        analysisTimer = timer
    }

    private func analyze() {
        guard let fftSetup else { return }
        // Same epoch as Date.timeIntervalSinceReferenceDate / CFAbsoluteTime.
        let now = CFAbsoluteTimeGetCurrent()

        // Soft-slew any residual phase correction so the grid doesn't jump.
        if abs(phaseErrorSlew) > 0.0005 {
            let step = phaseErrorSlew * 0.35
            beatAnchor += step
            phaseErrorSlew -= step
        }

        var timeDomain = [Float](repeating: 0, count: fftSize)
        ringLock.lock()
        guard ringFilled >= fftSize else {
            ringLock.unlock()
            // Still publish free-running phase so UI keeps pumping on the grid.
            if beatAnchor > 0 {
                let phase = beatPhase(at: now)
                let near = min(phase, 1 - phase)
                let gridKick = Float(exp(-Double(near * near) * 110))
                onFrame?(
                    smoothBands,
                    max(kickEnvelope, gridKick * 0.5),
                    0,
                    0.45,
                    phase,
                    trackedBPM,
                    beatAnchor,
                    beatInterval,
                    lastOnsetTime
                )
            }
            return
        }
        let capacity = ring.count
        var idx = (ringWrite - fftSize + capacity) % capacity
        for i in 0..<fftSize {
            timeDomain[i] = ring[idx]
            idx = (idx + 1) % capacity
        }
        ringLock.unlock()

        // Window
        vDSP_vmul(timeDomain, 1, window, 1, &timeDomain, 1, vDSP_Length(fftSize))

        // RMS + adaptive gain
        var rms: Float = 0
        vDSP_rmsqv(timeDomain, 1, &rms, vDSP_Length(fftSize))
        let target: Float = 0.12
        if rms > 1e-5 {
            let desired = target / rms
            agcGain = agcGain * 0.90 + min(12, max(0.4, desired)) * 0.10
        }
        var g = agcGain
        vDSP_vsmul(timeDomain, 1, &g, &timeDomain, 1, vDSP_Length(fftSize))
        let level = min(1, max(0, rms * agcGain * 3.2))

        // Real FFT
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                timeDomain.withUnsafeBufferPointer { td in
                    td.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var mags = [Float](repeating: 0, count: fftSize / 2)
        mags[0] = abs(realp[0]) / Float(fftSize)
        for i in 1..<(fftSize / 2) {
            let re = realp[i]
            let im = imagp[i]
            mags[i] = sqrtf(re * re + im * im) / Float(fftSize / 2)
        }

        let sampleRate = max(8_000.0, format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        let binHz = sampleRate / Double(fftSize)

        // Kick drum band (40–160 Hz) + low-mid punch (160–280 Hz)
        let bass0 = max(1, Int(40 / binHz))
        let bass1 = min(mags.count - 1, Int(160 / binHz))
        let punch1 = min(mags.count - 1, Int(280 / binHz))
        var bassEnergy: Float = 0
        var punchEnergy: Float = 0
        if bass1 > bass0 {
            for i in bass0..<bass1 { bassEnergy += mags[i] }
            bassEnergy /= Float(bass1 - bass0)
        }
        if punch1 > bass1 {
            for i in bass1..<punch1 { punchEnergy += mags[i] }
            punchEnergy /= Float(max(1, punch1 - bass1))
        }

        // Spectral flux (full band) + bass-weighted flux for rhythm
        var flux: Float = 0
        var bassFlux: Float = 0
        let limit = min(mags.count, prevMags.count)
        for i in 1..<limit {
            let d = mags[i] - prevMags[i]
            if d > 0 {
                flux += d
                if i >= bass0 && i < punch1 { bassFlux += d }
            }
        }
        for i in 0..<min(mags.count, prevMags.count) {
            prevMags[i] = mags[i]
        }

        longFlux = longFlux * 0.90 + flux * 0.10
        longBass = longBass * 0.90 + bassEnergy * 0.10

        // --- Onset detection (kick + snare-ish flux) with tempo-aware refractory ---
        let fluxThresh = max(0.018, longFlux * 1.45)
        let bassThresh = max(0.0035, longBass * 1.32)
        let isOnset =
            (flux > fluxThresh && bassFlux > flux * 0.10)
            || (bassEnergy > bassThresh && bassFlux > longFlux * 0.07)
            || (punchEnergy > longBass * 1.5 && bassFlux > longFlux * 0.05 && level > 0.06)
        // Allow half-notes at high tempo; block double-hits closer than ~42% of beat.
        let minGap = min(0.20, max(0.12, beatInterval * 0.40))
        if isOnset, (now - lastOnsetTime) > minGap {
            registerOnset(at: now)
            kickEnvelope = 1.0
        } else {
            // Fast musical decay so hits stay percussive
            kickEnvelope *= 0.78
            if kickEnvelope < 0.015 { kickEnvelope = 0 }
        }

        // Continuous beat phase from tempo + last downbeat anchor
        let phase = beatPhase(at: now)
        // Predicted grid kick fills missed onsets so bars never desync from tempo.
        let near = min(phase, 1 - phase)
        let gridKick = Float(exp(-Double(near * near) * 110)) * max(0.2, level)
        let kick = max(kickEnvelope, gridKick * 0.9)

        // Spectral centroid → brightness
        var weighted: Float = 0
        var total: Float = 0
        for i in 1..<mags.count {
            let f = Float(i) * Float(binHz)
            weighted += mags[i] * f
            total += mags[i]
        }
        let centroid = total > 1e-8 ? weighted / total : 1_000
        let brightness = min(1, max(0, (centroid - 200) / 5_800))

        // Log bands 40 Hz … 16 kHz
        let minHz = 40.0
        let maxHz = min(16_000.0, sampleRate * 0.48)
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let t0 = Double(b) / Double(bandCount)
            let t1 = Double(b + 1) / Double(bandCount)
            let f0 = minHz * pow(maxHz / minHz, t0)
            let f1 = minHz * pow(maxHz / minHz, t1)
            let bin0 = max(1, Int(f0 / binHz))
            let bin1 = min(mags.count - 1, max(bin0 + 1, Int(f1 / binHz)))
            var sum: Float = 0
            for bin in bin0..<bin1 { sum += mags[bin] }
            var v = sum / Float(bin1 - bin0)

            let tilt = Float(0.85 + 0.35 * t0)
            v *= tilt

            // Beat pulse rides every band; bass more — phase-locked pump
            let beatPulse = kick * Float(0.18 + 0.48 * (1.0 - t0))
            let phaseBump = Float(exp(-pow(Double(near) * 5.5, 2))) * 0.16 * Float(1.0 - t0 * 0.45)
            v += beatPulse + phaseBump

            v = min(1, pow(max(0, v) * 3.0, 0.68))

            // Fast attack / quick release — stays locked to hits
            let prev = smoothBands[b]
            let coeff: Float = v > prev ? 0.82 : 0.42
            let smoothed = prev + (v - prev) * coeff
            smoothBands[b] = smoothed
            bands[b] = max(0.05, smoothed)
        }

        if level < 0.035 {
            for i in 0..<bands.count {
                bands[i] *= 0.3
                smoothBands[i] *= 0.8
            }
            kickEnvelope *= 0.5
        }

        // Seed grid on first loud energy if we never locked an onset yet.
        if beatAnchor <= 0, level > 0.08 {
            beatAnchor = now
            lastOnsetTime = now
        }

        onFrame?(
            bands,
            kick,
            level,
            brightness,
            phase,
            trackedBPM,
            beatAnchor,
            beatInterval,
            lastOnsetTime
        )
    }

    private func registerOnset(at time: CFAbsoluteTime) {
        // Prefer IOI (inter-onset interval) before overwriting last time.
        if lastOnsetTime > 0 {
            let dt = time - lastOnsetTime
            // Accept quarter-note range; fold double/half into tempo stability.
            var interval = dt
            if interval >= 0.22 && interval <= 1.15 {
                // Half-time / double-time fold toward current estimate.
                if beatInterval > 0.05 {
                    if abs(interval - beatInterval * 2) < abs(interval - beatInterval)
                        && abs(interval - beatInterval * 2) < 0.12 {
                        interval = interval / 2
                    } else if abs(interval * 2 - beatInterval) < abs(interval - beatInterval)
                        && abs(interval * 2 - beatInterval) < 0.12 {
                        interval = interval * 2
                    }
                }
                onsetIntervals.append(interval)
                if onsetIntervals.count > 16 {
                    onsetIntervals.removeFirst(onsetIntervals.count - 16)
                }
                let sorted = onsetIntervals.sorted()
                let med = sorted[sorted.count / 2]
                beatInterval = beatInterval * 0.28 + med * 0.72
                trackedBPM = min(180, max(60, 60.0 / beatInterval))
            }
        }
        lastOnsetTime = time

        // Hard phase-lock: this onset *is* the downbeat. Soft slew only cleans
        // residual sub-frame error so the next free-run stays smooth.
        if beatAnchor > 0, beatInterval > 0.05 {
            let elapsed = time - beatAnchor
            let phase = elapsed.truncatingRemainder(dividingBy: beatInterval) / beatInterval
            let toDownbeat = min(phase, 1 - phase)
            if toDownbeat < 0.22 {
                // Near predicted beat — snap fully, cancel pending slew.
                beatAnchor = time
                phaseErrorSlew = 0
            } else {
                // Syncopation / fill — still lock so bars hit this kick.
                beatAnchor = time
                phaseErrorSlew = 0
            }
        } else {
            beatAnchor = time
            phaseErrorSlew = 0
        }
    }

    /// 0 = downbeat, rises to 1 just before next beat.
    private func beatPhase(at time: CFAbsoluteTime) -> Float {
        guard beatInterval > 0.05, beatAnchor > 0 else { return 0 }
        var elapsed = time - beatAnchor
        if elapsed < 0 { elapsed = 0 }
        let p = elapsed.truncatingRemainder(dividingBy: beatInterval) / beatInterval
        return Float(min(1, max(0, p)))
    }

    // MARK: Process resolution

    private static func resolveProcessObjectIDs(preferredBundleID: String?) -> [AudioObjectID] {
        let apps = NSWorkspace.shared.runningApplications
        var candidates: [String] = []
        if let preferredBundleID { candidates.append(preferredBundleID) }
        candidates += [
            "com.apple.Music",
            "com.spotify.client",
            "com.apple.podcasts",
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.hnc.Discord",
            "com.tinyspeck.slackmacgap"
        ]

        var ids: [AudioObjectID] = []
        for bundle in candidates {
            for app in apps where app.bundleIdentifier == bundle && !app.isTerminated {
                if let obj = audioProcessObjectID(forPID: app.processIdentifier) {
                    ids.append(obj)
                }
            }
            if !ids.isEmpty { return ids }
        }
        return ids
    }

    private static func audioProcessObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidCopy = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidCopy,
            &size,
            &objectID
        )
        guard err == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func defaultOutputDeviceUID() throws -> String {
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
        guard err == noErr else { throw SamplerError.failed("No default output") }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var cfUID: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        err = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid = cfUID as String? else {
            throw SamplerError.failed("No device UID")
        }
        return uid
    }

    private static func readTapStreamDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr else { throw SamplerError.failed("Tap format unavailable") }
        return asbd
    }
}

private enum SamplerError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}
