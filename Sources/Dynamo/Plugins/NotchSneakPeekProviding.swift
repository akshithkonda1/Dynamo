import Foundation

/// How insistent a sneak peek should look/feel and how long it stays up.
/// Higher values preempt lower ones and survive Meeting Mode quieting.
enum NotchSneakPeekUrgency: Int, Equatable, Comparable {
    /// Track change, ambient niceties — short, suppressible in meetings.
    case low = 0
    /// Routine heads-up.
    case normal = 1
    /// Calendar / reminder approaching (e.g. 15–5 min).
    case high = 2
    /// Starting now, overdue, severe alert — longest dwell, never suppressed.
    case critical = 3

    static func < (lhs: NotchSneakPeekUrgency, rhs: NotchSneakPeekUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Visual treatment for a sneak peek.
enum NotchSneakPeekStyle: Equatable {
    /// Default heads-up (calendar, health, weather).
    case standard
    /// Track change — full-bleed aurora equalizer island.
    case media
}

/// Content for a brief "sneak peek" that slides out of the notch when something
/// noteworthy happens (track change, meeting soon, due reminder), then auto-hides.
struct NotchSneakPeek: Equatable {
    var systemImage: String
    var title: String
    var subtitle: String
    var urgency: NotchSneakPeekUrgency = .normal
    /// Optional cover / thumbnail art (e.g. album art). Raw image bytes.
    var artworkData: Data? = nil
    /// Optional third line (location, calendar name, playlist).
    var detail: String = ""
    /// Presentation style (media peeks become an aurora equalizer).
    var style: NotchSneakPeekStyle = .standard

    /// Back-compat for call sites that still think in binary emphasis.
    var emphasis: NotchSneakPeekEmphasis {
        urgency >= .high ? .critical : .normal
    }

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        urgency: NotchSneakPeekUrgency = .normal,
        artworkData: Data? = nil,
        detail: String = "",
        style: NotchSneakPeekStyle = .standard,
        emphasis: NotchSneakPeekEmphasis? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        if let emphasis {
            self.urgency = emphasis == .critical ? .critical : .normal
        } else {
            self.urgency = urgency
        }
        self.artworkData = artworkData
        self.detail = detail
        self.style = style
    }
}

/// Legacy binary emphasis — prefer `NotchSneakPeekUrgency`.
enum NotchSneakPeekEmphasis: Equatable {
    case normal
    case critical
}

/// Optional capability: a widget that can request a brief sneak peek.
/// Discovered by protocol cast on the registry (like `FileDropAccepting` and
/// `NotchAmbientProviding`), so hosts never special-case a widget by name.
@MainActor
protocol NotchSneakPeekProviding: AnyObject {
    /// Set by the registry at registration time. The widget calls this
    /// whenever it wants to sneak-peek content into the notch.
    var onSneakPeek: ((NotchSneakPeek) -> Void)? { get set }
}
