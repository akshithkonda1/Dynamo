import Foundation

/// When enabled and a calendar event is **Now**, Dynamo quiets non-critical
/// sneak peeks and can dim media ambient so the notch stays useful in meetings.
@MainActor
final class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    private static let enabledKey = "dynamo.meetingMode.enabled"
    private static let dimMediaKey = "dynamo.meetingMode.dimMedia"
    private static let quietOnFocusKey = "dynamo.meetingMode.quietOnFocus"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Dim music ambient while a meeting is Now.
    @Published var dimMediaAmbient: Bool {
        didSet { UserDefaults.standard.set(dimMediaAmbient, forKey: Self.dimMediaKey) }
    }

    /// Also suppress normal peeks when system Focus is active (best-effort).
    @Published var quietOnFocus: Bool {
        didSet { UserDefaults.standard.set(quietOnFocus, forKey: Self.quietOnFocusKey) }
    }

    /// Injected by the calendar plugin.
    var isInActiveMeeting: () -> Bool = { false }

    /// Optional Focus status provider (set by FocusQuietMonitor).
    var isFocusActive: () -> Bool = { false }

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

    /// Suppress routine peeks while in a live meeting (or Focus if enabled).
    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        guard peek.emphasis != .critical else { return false }
        if isEnabled, isInActiveMeeting() { return true }
        if quietOnFocus, isFocusActive() { return true }
        return false
    }

    func shouldDimMediaAmbient() -> Bool {
        guard isEnabled, dimMediaAmbient else { return false }
        return isInActiveMeeting()
    }
}
