import AppKit
import Foundation

struct DistractionLogEntry: Identifiable {
    let id = UUID()
    let title: String
    let date: Date
}

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
    private static let breakNudgeKey = "dynamo.focus.breakNudgeMinutes"
    private static let dndSyncKey = "dynamo.focus.dndSync"

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

    @Published var breakNudgeMinutes: Int = 25 {
        didSet {
            guard !isConfiguring else { return }
            UserDefaults.standard.set(breakNudgeMinutes, forKey: Self.breakNudgeKey)
            restartBreakNudge()
        }
    }

    @Published var dndSyncEnabled: Bool = false {
        didSet {
            guard !isConfiguring else { return }
            UserDefaults.standard.set(dndSyncEnabled, forKey: Self.dndSyncKey)
            if dndSyncEnabled {
                subscribeDND()
            } else {
                unsubscribeDND()
            }
        }
    }

    @Published var duckPercent: Int = 25 {
        didSet {
            guard !isConfiguring else { return }
            let p = min(40, max(10, duckPercent))
            if p != duckPercent {
                // Clamp without re-entering didSet recursion loops.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.duckPercent != p else { return }
                    self.duckPercent = p
                }
                return
            }
            UserDefaults.standard.set(duckPercent, forKey: Self.duckPercentKey)
            ducker.targetPercent = duckPercent
        }
    }

    /// Suppress didSet side effects while loading UserDefaults in init.
    private var isConfiguring = true

    /// Call app currently frontmost / visible (for UI + suggestions only).
    @Published private(set) var suggestedCallApp: String?
    @Published private(set) var meetingEnteredAt: Date?
    @Published private(set) var recentDynamicPeeks: [String] = []
    @Published private(set) var distractionLog: [DistractionLogEntry] = []

    /// Injected by CalendarPlugin for Meeting context strip.
    var isCalendarMeetingNow: () -> Bool = { false }
    var calendarMeetingTitle: () -> String? = { nil }
    var calendarMeetingNotes: () -> String? = { nil }
    var calendarMeetingAttendees: () -> [String] = { [] }
    var calendarMeetingEnd: () -> Date? = { nil }

    /// Wired by sneak-peek host so Dynamic/Meeting can emit peeks.
    var emitPeek: ((NotchSneakPeek) -> Void)?

    private let callProbe = CallSessionProbe()
    private let ducker = MeetingVolumeDucker()
    private var started = false
    private var didSuggestMeetingThisSession = false
    private var breakNudgeTimer: Timer?
    private var dndObserver: NSObjectProtocol?

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
        breakNudgeMinutes = UserDefaults.standard.object(forKey: Self.breakNudgeKey) as? Int ?? 25
        dndSyncEnabled = UserDefaults.standard.bool(forKey: Self.dndSyncKey)
        isConfiguring = false
    }

    func start() {
        guard !started else { return }
        started = true
        // Legacy dim flag: enabled when user might use Meeting.
        MeetingMode.shared.isEnabled = true
        callProbe.start { [weak self] in
            self?.refreshCallContext()
        }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCallContext() }
        }
        refreshCallContext()
        // If relaunched already in Meeting, re-apply duck + notes session.
        if baseMode == .meeting {
            meetingEnteredAt = meetingEnteredAt ?? Date()
            ducker.enter()
            MeetingNotesStore.shared.ensureSession(
                calendarTitle: calendarMeetingTitle(),
                callApp: suggestedCallApp
            )
        }
        restartBreakNudge()
        if dndSyncEnabled { subscribeDND() }
    }

    func stop() {
        callProbe.stop()
        if baseMode == .meeting {
            ducker.exit()
            MeetingSpeechCapture.shared.stop()
        }
        breakNudgeTimer?.invalidate()
        breakNudgeTimer = nil
        unsubscribeDND()
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

    /// Kept for CalendarPlugin hooks — no longer forces mode.
    func reevaluateMeeting() {
        refreshCallContext()
    }

    private func refreshCallContext() {
        // Prefer frontmost confidence for suggestions.
        callProbe.refresh()
        let name = callProbe.suggestedFrontmostCallApp
        if name != suggestedCallApp {
            suggestedCallApp = name
        }
        maybeOfferMeeting()
        // Keep legacy bridge for ambient dim only when in Meeting mode.
        MeetingMode.shared.syncFromFocus(enabled: true, meetingNow: isMeetingActive)
        objectWillChange.send()
    }

    private func maybeOfferMeeting() {
        guard suggestMeetingOnCall else { return }
        guard baseMode != .meeting else { return }
        guard let app = suggestedCallApp else {
            // Reset so a later call can suggest again after leaving the app.
            return
        }
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

    /// Allow another “Enter Meeting?” offer after the user leaves Meeting mode.
    func resetMeetingSuggestion() {
        didSuggestMeetingThisSession = false
    }

    private func handleModeTransition(from old: FocusBaseMode, to new: FocusBaseMode) {
        let wasMeeting = old == .meeting
        let isMeeting = new == .meeting
        if isMeeting, !wasMeeting {
            meetingEnteredAt = Date()
            ducker.enter()
            MeetingNotesStore.shared.ensureSession(
                calendarTitle: calendarMeetingTitle(),
                callApp: suggestedCallApp
            )
        } else if wasMeeting, !isMeeting {
            MeetingSpeechCapture.shared.stop()
            ducker.exit()
            meetingEnteredAt = nil
            MeetingNotesStore.shared.endSession()
            // Allow a fresh suggest next time a call app is frontmost.
            resetMeetingSuggestion()
        }
        if new == .trueFocus {
            FocusAgendaEngine.shared.rebuild()
        }
        MeetingMode.shared.syncFromFocus(enabled: true, meetingNow: isMeeting)
    }

    // MARK: - Policy

    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        if peek.style == .media { return false }
        if isMeetingActive, peek.urgency < .high {
            if peek.detail.contains("Meeting companion") { return false }
            logDistraction(peek.title)
            return true
        }
        if effective == .trueFocus, peek.urgency == .low {
            logDistraction(peek.title)
            return true
        }
        return false
    }

    func clearDistractionLog() {
        distractionLog = []
    }

    private func logDistraction(_ title: String) {
        distractionLog.insert(DistractionLogEntry(title: title, date: Date()), at: 0)
        if distractionLog.count > 20 { distractionLog = Array(distractionLog.prefix(20)) }
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

    // MARK: - Break nudge

    private func restartBreakNudge() {
        breakNudgeTimer?.invalidate()
        guard breakNudgeMinutes > 0, started else { return }
        let interval = TimeInterval(breakNudgeMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireBreakNudge() }
        }
        RunLoop.main.add(t, forMode: .common)
        breakNudgeTimer = t
    }

    private func fireBreakNudge() {
        guard effective == .trueFocus || effective == .meeting else { return }
        emitPeek?(NotchSneakPeek(
            systemImage: "figure.stand",
            title: "Break time",
            subtitle: "You've been focused for \(breakNudgeMinutes)m — stand up & stretch",
            urgency: .normal,
            detail: "Focus · Break nudge"
        ))
    }

    // MARK: - macOS DND sync

    private func subscribeDND() {
        guard dndObserver == nil else { return }
        let nc = DistributedNotificationCenter.default()
        dndObserver = nc.addObserver(
            forName: NSNotification.Name("com.apple.donotdisturb.state.changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDNDChange() }
        }
        handleDNDChange()
    }

    private func unsubscribeDND() {
        if let obs = dndObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            dndObserver = nil
        }
    }

    private func handleDNDChange() {
        guard dndSyncEnabled else { return }
        let isDND = isDNDOn()
        if isDND, baseMode == .normal {
            baseMode = .trueFocus
        } else if !isDND, baseMode == .trueFocus {
            baseMode = .normal
        }
    }

    private func isDNDOn() -> Bool {
        // Read the com.apple.ncprefs plist that DND writes.
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.ncprefs.plist"
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let dndPrefs = dict["dnd_prefs"] as? [String: Any] else {
            return false
        }
        return (dndPrefs["userPref"] as? [String: Any])?["enabled"] as? Bool ?? false
    }
}
