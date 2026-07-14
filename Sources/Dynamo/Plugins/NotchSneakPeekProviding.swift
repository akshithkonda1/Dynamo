import Foundation

/// How insistent a sneak peek should look/feel. `.critical` is for things that
/// genuinely warrant grabbing attention (a severe weather alert) — it gets a
/// warning-colored glow and stays up longer than a routine peek (a track
/// change, a meeting reminder).
enum NotchSneakPeekEmphasis: Equatable {
    case normal
    case critical
}

/// Content for a brief "sneak peek" pill that slides out of the notch when
/// something noteworthy happens (e.g. a track change), then auto-hides — the
/// same transient-overlay mechanic the volume/brightness HUD uses.
struct NotchSneakPeek: Equatable {
    var systemImage: String
    var title: String
    var subtitle: String
    var emphasis: NotchSneakPeekEmphasis = .normal
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
