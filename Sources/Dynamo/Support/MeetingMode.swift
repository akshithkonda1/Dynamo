import Foundation

/// Legacy facade for media ambient dimming. Prefer `FocusController`.
@MainActor
final class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    private static let enabledKey = "dynamo.meetingMode.enabled"
    private static let dimMediaKey = "dynamo.meetingMode.dimMedia"
    private static let quietOnFocusKey = "dynamo.meetingMode.quietOnFocus"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if FocusController.shared.suggestMeetingOnCall != isEnabled {
                FocusController.shared.suggestMeetingOnCall = isEnabled
            }
        }
    }

    @Published var dimMediaAmbient: Bool {
        didSet { UserDefaults.standard.set(dimMediaAmbient, forKey: Self.dimMediaKey) }
    }

    @Published var quietOnFocus: Bool {
        didSet { UserDefaults.standard.set(quietOnFocus, forKey: Self.quietOnFocusKey) }
    }

    var isInActiveMeeting: () -> Bool = { false } {
        didSet {
            FocusController.shared.isCalendarMeetingNow = { [weak self] in
                self?.isInActiveMeeting() == true
            }
        }
    }

    var isFocusActive: () -> Bool = { false }

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
        objectWillChange.send()
    }

    func shouldSuppress(peek: NotchSneakPeek) -> Bool {
        FocusController.shared.shouldSuppress(peek: peek)
    }

    func shouldDimMediaAmbient() -> Bool {
        guard dimMediaAmbient else { return false }
        return FocusController.shared.shouldDimMediaAmbient() || focusMeetingNow
    }
}
