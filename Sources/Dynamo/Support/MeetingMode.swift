import Foundation

/// Legacy facade kept so existing call sites compile while FocusController owns policy.
/// Prefer `FocusController.shared` for new code.
@MainActor
final class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    private static let enabledKey = "dynamo.meetingMode.enabled"
    private static let dimMediaKey = "dynamo.meetingMode.dimMedia"
    private static let quietOnFocusKey = "dynamo.meetingMode.quietOnFocus"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            // Keep FocusController in sync when toggled from Settings/menu.
            if FocusController.shared.autoMeetingEnabled != isEnabled {
                FocusController.shared.autoMeetingEnabled = isEnabled
            }
        }
    }

    @Published var dimMediaAmbient: Bool {
        didSet { UserDefaults.standard.set(dimMediaAmbient, forKey: Self.dimMediaKey) }
    }

    @Published var quietOnFocus: Bool {
        didSet { UserDefaults.standard.set(quietOnFocus, forKey: Self.quietOnFocusKey) }
    }

    /// Injected by calendar (also mirrored into FocusController).
    var isInActiveMeeting: () -> Bool = { false } {
        didSet {
            FocusController.shared.isCalendarMeetingNow = { [weak self] in
                self?.isInActiveMeeting() == true
            }
        }
    }

    var isFocusActive: () -> Bool = { false }

    /// Live meeting signal from FocusController when available.
    private var focusMeetingNow = false

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.dimMediaKey) == nil {
            dimMediaAmbient = true
        } else {
            dimMediaAmbient = UserDefaults.standard.bool(forKey: Self.dimMediaKey)
        }
        if UserDefaults.standard.object(forKey: Self.quietOnFocusKey) == nil {
            quietOnFocus = false
        } else {
            quietOnFocus = UserDefaults.standard.bool(forKey: Self.quietOnFocusKey)
        }
    }

    func syncFromFocus(enabled: Bool, meetingNow: Bool) {
        focusMeetingNow = meetingNow
        if isEnabled != enabled {
            // Avoid write-loop: set storage without re-entering Focus.
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            isEnabled = enabled
        }
        objectWillChange.send()
    }

    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        FocusController.shared.shouldSuppress(peek: peek)
    }

    func shouldDimMediaAmbient() -> Bool {
        guard dimMediaAmbient else { return false }
        return FocusController.shared.shouldDimMediaAmbient()
            || (isEnabled && (focusMeetingNow || isInActiveMeeting()))
    }
}
