import AppKit
import Foundation

/// User-selectable base focus mode (Meeting is auto-only overlay).
enum FocusBaseMode: String, CaseIterable, Identifiable {
    case normal
    case dynamic
    case trueFocus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .dynamic: return "Dynamic"
        case .trueFocus: return "True Focus"
        }
    }

    var subtitle: String {
        switch self {
        case .normal: return "Default Dynamo — no special policy"
        case .dynamic: return "Peeks + workflow companion (no AI)"
        case .trueFocus: return "Calendar-driven productivity partner"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "circle"
        case .dynamic: return "bolt.horizontal.circle"
        case .trueFocus: return "target"
        }
    }
}

enum FocusEffectiveMode: Equatable {
    case normal
    case meeting
    case dynamic
    case trueFocus
}

enum MeetingReason: Equatable {
    case calendar
    case call(appName: String)

    var label: String {
        switch self {
        case .calendar: return "Calendar event"
        case .call(let name): return name
        }
    }
}

/// Central Focus state: base mode + auto Meeting overlay.
@MainActor
final class FocusController: ObservableObject {
    static let shared = FocusController()

    private static let baseModeKey = "dynamo.focus.baseMode"
    private static let autoMeetingKey = "dynamo.focus.autoMeeting"
    private static let duckPercentKey = "dynamo.focus.duckPercent"

    @Published var baseMode: FocusBaseMode {
        didSet {
            UserDefaults.standard.set(baseMode.rawValue, forKey: Self.baseModeKey)
            objectWillChange.send()
        }
    }

    /// When false, calendar/call never enter Meeting overlay.
    @Published var autoMeetingEnabled: Bool {
        didSet { UserDefaults.standard.set(autoMeetingEnabled, forKey: Self.autoMeetingKey) }
    }

    @Published var duckPercent: Int {
        didSet {
            let p = min(40, max(10, duckPercent))
            if p != duckPercent { duckPercent = p; return }
            UserDefaults.standard.set(duckPercent, forKey: Self.duckPercentKey)
            ducker.targetPercent = duckPercent
        }
    }

    @Published private(set) var isMeetingActive = false
    @Published private(set) var meetingReason: MeetingReason?
    /// Recent Dynamic peeks for Focus UI transparency.
    @Published private(set) var recentDynamicPeeks: [String] = []

    /// Injected by CalendarPlugin.
    var isCalendarMeetingNow: () -> Bool = { false }

    private let callProbe = CallSessionProbe()
    private let ducker = MeetingVolumeDucker()
    private var clearMeetingWorkItem: DispatchWorkItem?
    private var started = false

    /// Effective mode including Meeting overlay.
    var effective: FocusEffectiveMode {
        if isMeetingActive { return .meeting }
        switch baseMode {
        case .normal: return .normal
        case .dynamic: return .dynamic
        case .trueFocus: return .trueFocus
        }
    }

    var effectiveTitle: String {
        switch effective {
        case .normal: return "Normal"
        case .meeting: return "Meeting"
        case .dynamic: return "Dynamic"
        case .trueFocus: return "True Focus"
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.baseModeKey),
           let mode = FocusBaseMode(rawValue: raw) {
            baseMode = mode
        } else {
            baseMode = .normal
        }
        if UserDefaults.standard.object(forKey: Self.autoMeetingKey) == nil {
            autoMeetingEnabled = true
        } else {
            autoMeetingEnabled = UserDefaults.standard.bool(forKey: Self.autoMeetingKey)
        }
        let storedDuck = UserDefaults.standard.object(forKey: Self.duckPercentKey) as? Int
        duckPercent = storedDuck ?? 25
        ducker.targetPercent = duckPercent
    }

    func start() {
        guard !started else { return }
        started = true
        // Keep legacy MeetingMode flags aligned for any remaining readers.
        MeetingMode.shared.isEnabled = autoMeetingEnabled
        callProbe.start { [weak self] in
            self?.reevaluateMeeting()
        }
        // Calendar changes often; poll lightly.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluateMeeting() }
        }
        reevaluateMeeting()
    }

    func stop() {
        callProbe.stop()
        ducker.exit()
        started = false
    }

    func reevaluateMeeting() {
        guard autoMeetingEnabled else {
            setMeeting(active: false, reason: nil)
            return
        }
        if callProbe.isInCall, let name = callProbe.activeCallAppName {
            setMeeting(active: true, reason: .call(appName: name))
            return
        }
        if isCalendarMeetingNow() {
            setMeeting(active: true, reason: .calendar)
            return
        }
        // Hysteresis: delay exit.
        scheduleMeetingClear()
    }

    private func scheduleMeetingClear() {
        clearMeetingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Re-check before clear.
                if self.callProbe.isInCall || self.isCalendarMeetingNow() { return }
                self.setMeeting(active: false, reason: nil)
            }
        }
        clearMeetingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func setMeeting(active: Bool, reason: MeetingReason?) {
        if active {
            clearMeetingWorkItem?.cancel()
            clearMeetingWorkItem = nil
        }
        let was = isMeetingActive
        isMeetingActive = active
        meetingReason = active ? reason : nil
        if active, !was {
            ducker.enter()
        } else if !active, was {
            ducker.exit()
        }
        // Legacy bridge
        MeetingMode.shared.syncFromFocus(
            enabled: autoMeetingEnabled,
            meetingNow: active
        )
        objectWillChange.send()
    }

    // MARK: - Policy helpers (replaces MeetingMode usage)

    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        if peek.style == .media { return false }
        // During Meeting: suppress low/normal.
        if isMeetingActive, peek.urgency < .high { return true }
        // True Focus: suppress low non-agenda noise (media still allowed).
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
