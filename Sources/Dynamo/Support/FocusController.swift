import AppKit
import Foundation

/// User-selectable Focus modes. Meeting is chosen explicitly (Granola-style companion).
enum FocusBaseMode: String, CaseIterable, Identifiable {
    case normal
    case dynamic
    case trueFocus
    case meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .dynamic: return "Dynamic"
        case .trueFocus: return "True Focus"
        case .meeting: return "Meeting"
        }
    }

    var subtitle: String {
        switch self {
        case .normal: return "Default Dynamo"
        case .dynamic: return "Peeks + workflow companion"
        case .trueFocus: return "Calendar productivity partner"
        case .meeting: return "Notes, talk tips, quiet island"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "circle"
        case .dynamic: return "bolt.horizontal.circle"
        case .trueFocus: return "target"
        case .meeting: return "video.fill"
        }
    }
}

enum FocusEffectiveMode: Equatable {
    case normal
    case dynamic
    case trueFocus
    case meeting
}

/// Central Focus state — Meeting is a base mode, not a silent auto-overlay.
@MainActor
final class FocusController: ObservableObject {
    static let shared = FocusController()

    private static let baseModeKey = "dynamo.focus.baseMode"
    private static let suggestMeetingKey = "dynamo.focus.suggestMeeting"
    private static let duckPercentKey = "dynamo.focus.duckPercent"

    /// Suppress didSet side effects while loading UserDefaults in init.
    private var isConfiguring = true

    @Published var baseMode: FocusBaseMode = .normal {
        didSet {
            guard !isConfiguring else { return }
            guard oldValue != baseMode else { return }
            UserDefaults.standard.set(baseMode.rawValue, forKey: Self.baseModeKey)
            handleModeTransition(from: oldValue, to: baseMode)
        }
    }

    /// When true, frontmost call apps can offer “Enter Meeting Mode?” once per session.
    @Published var suggestMeetingOnCall: Bool = true {
        didSet {
            guard !isConfiguring else { return }
            UserDefaults.standard.set(suggestMeetingOnCall, forKey: Self.suggestMeetingKey)
        }
    }

    @Published var duckPercent: Int = 25 {
        didSet {
            guard !isConfiguring else { return }
            let p = min(40, max(10, duckPercent))
            if p != duckPercent {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.duckPercent != p else { return }
                    self.duckPercent = p
                }
                return
            }
            UserDefaults.standard.set(duckPercent, forKey: Self.duckPercentKey)
            ducker.targetPercent = duckPercent
            if baseMode == .meeting {
                ducker.reapplyIfNeeded()
            }
        }
    }

    /// Call app currently frontmost / visible (for UI + suggestions only).
    @Published private(set) var suggestedCallApp: String?
    @Published private(set) var meetingEnteredAt: Date?
    @Published private(set) var recentDynamicPeeks: [String] = []
    /// Live elapsed tick so Meeting UI timer updates.
    @Published private(set) var meetingElapsedTick: Int = 0

    /// Injected by CalendarPlugin for Meeting context strip.
    var isCalendarMeetingNow: () -> Bool = { false }
    var calendarMeetingTitle: () -> String? = { nil }

    /// Wired by sneak-peek host so Dynamic/Meeting can emit peeks.
    var emitPeek: ((NotchSneakPeek) -> Void)?

    private let callProbe = CallSessionProbe()
    private let ducker = MeetingVolumeDucker()
    private var started = false
    private var didSuggestMeetingThisSession = false
    private var reDuckTimer: Timer?
    private var elapsedTimer: Timer?
    private var contextTimer: Timer?

    /// Meeting is active only when user selected Meeting mode.
    var isMeetingActive: Bool { baseMode == .meeting }

    var effective: FocusEffectiveMode {
        switch baseMode {
        case .normal: return .normal
        case .dynamic: return .dynamic
        case .trueFocus: return .trueFocus
        case .meeting: return .meeting
        }
    }

    var effectiveTitle: String { baseMode.title }

    var meetingElapsed: TimeInterval {
        guard let start = meetingEnteredAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    private init() {
        isConfiguring = true
        if let raw = UserDefaults.standard.string(forKey: Self.baseModeKey),
           let mode = FocusBaseMode(rawValue: raw) {
            baseMode = mode
        } else {
            baseMode = .normal
        }
        if UserDefaults.standard.object(forKey: Self.suggestMeetingKey) == nil {
            suggestMeetingOnCall = true
        } else {
            suggestMeetingOnCall = UserDefaults.standard.bool(forKey: Self.suggestMeetingKey)
        }
        let storedDuck = UserDefaults.standard.object(forKey: Self.duckPercentKey) as? Int ?? 25
        duckPercent = min(40, max(10, storedDuck))
        ducker.targetPercent = duckPercent
        isConfiguring = false
    }

    func start() {
        guard !started else { return }
        started = true
        MeetingMode.shared.isEnabled = true
        callProbe.start { [weak self] in
            self?.refreshCallContext()
        }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCallContext() }
        }
        RunLoop.main.add(t, forMode: .common)
        contextTimer = t
        refreshCallContext()
        if baseMode == .meeting {
            meetingEnteredAt = meetingEnteredAt ?? Date()
            ducker.enter()
            startMeetingTimers()
            MeetingNotesStore.shared.ensureSession(
                calendarTitle: calendarMeetingTitle(),
                callApp: suggestedCallApp
            )
        }
    }

    func stop() {
        callProbe.stop()
        contextTimer?.invalidate()
        contextTimer = nil
        stopMeetingTimers()
        if baseMode == .meeting {
            ducker.exit()
            MeetingSpeechCapture.shared.stop()
        }
        started = false
    }

    func enterMeetingMode() {
        baseMode = .meeting
    }

    func leaveMeetingMode() {
        if baseMode == .meeting {
            baseMode = .normal
        }
    }

    /// Cycles Normal → Dynamic → TrueFocus → Normal (Meeting is explicit only).
    func cycleMode() {
        switch baseMode {
        case .normal: baseMode = .dynamic
        case .dynamic: baseMode = .trueFocus
        case .trueFocus: baseMode = .normal
        case .meeting: baseMode = .normal
        }
    }

    func reevaluateMeeting() {
        refreshCallContext()
    }

    func resetMeetingSuggestion() {
        didSuggestMeetingThisSession = false
    }

    private func refreshCallContext() {
        callProbe.refresh()
        let name = callProbe.suggestedFrontmostCallApp
        if name != suggestedCallApp {
            suggestedCallApp = name
        }
        maybeOfferMeeting()
        MeetingMode.shared.syncFromFocus(enabled: true, meetingNow: isMeetingActive)
        objectWillChange.send()
    }

    private func maybeOfferMeeting() {
        guard suggestMeetingOnCall else { return }
        guard baseMode != .meeting else { return }
        guard let app = suggestedCallApp else { return }
        guard !didSuggestMeetingThisSession else { return }
        guard emitPeek != nil else { return }
        didSuggestMeetingThisSession = true
        emitPeek?(NotchSneakPeek(
            systemImage: "video.fill",
            title: "Enter Meeting Mode?",
            subtitle: "\(app) is open · notes & quiet island",
            urgency: .high,
            detail: "Focus · Meeting companion"
        ))
    }

    private func handleModeTransition(from old: FocusBaseMode, to new: FocusBaseMode) {
        let wasMeeting = old == .meeting
        let isMeeting = new == .meeting
        if isMeeting, !wasMeeting {
            meetingEnteredAt = Date()
            meetingElapsedTick = 0
            ducker.enter()
            startMeetingTimers()
            MeetingNotesStore.shared.ensureSession(
                calendarTitle: calendarMeetingTitle(),
                callApp: suggestedCallApp
            )
        } else if wasMeeting, !isMeeting {
            MeetingSpeechCapture.shared.stop()
            stopMeetingTimers()
            ducker.exit()
            meetingEnteredAt = nil
            MeetingNotesStore.shared.endSession()
            resetMeetingSuggestion()
        }
        if new == .trueFocus {
            FocusAgendaEngine.shared.rebuild()
        }
        MeetingMode.shared.syncFromFocus(enabled: true, meetingNow: isMeeting)
        NotificationCenter.default.post(name: .dynamoFocusLayoutDidChange, object: nil)
        objectWillChange.send()
    }

    private func startMeetingTimers() {
        stopMeetingTimers()
        let reDuck = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.baseMode == .meeting else { return }
                self.ducker.reapplyIfNeeded()
            }
        }
        RunLoop.main.add(reDuck, forMode: .common)
        reDuckTimer = reDuck

        let elapsed = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.baseMode == .meeting else { return }
                self.meetingElapsedTick &+= 1
            }
        }
        RunLoop.main.add(elapsed, forMode: .common)
        elapsedTimer = elapsed
    }

    private func stopMeetingTimers() {
        reDuckTimer?.invalidate()
        reDuckTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Policy

    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        if peek.style == .media { return false }
        if isMeetingActive, peek.urgency < .high {
            if peek.detail.contains("Meeting companion") { return false }
            return true
        }
        if effective == .trueFocus, peek.urgency == .low { return true }
        return false
    }

    func shouldDimMediaAmbient() -> Bool {
        isMeetingActive
    }

    func noteDynamicPeek(_ title: String) {
        recentDynamicPeeks.insert(title, at: 0)
        if recentDynamicPeeks.count > 5 {
            recentDynamicPeeks = Array(recentDynamicPeeks.prefix(5))
        }
    }
}
