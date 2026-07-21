import Foundation

/// When enabled and a calendar event is **Now**, Dynamo quiets non-critical
/// sneak peeks (track changes, etc.) so the notch stays useful in meetings.
@MainActor
final class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    private static let enabledKey = "dynamo.meetingMode.enabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Injected by the calendar plugin (or any future meeting source).
    var isInActiveMeeting: () -> Bool = { false }

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    /// Suppress routine peeks while in a live meeting; critical always passes.
    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        guard isEnabled else { return false }
        guard peek.emphasis != .critical else { return false }
        return isInActiveMeeting()
    }
}
