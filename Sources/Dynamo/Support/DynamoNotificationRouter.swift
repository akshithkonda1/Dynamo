import AppKit
import Combine
import Foundation

/// **Dynamo is the notification router.**
///
/// Every alert — widgets, Focus, Messages/FaceTime (system ingest), URL scheme,
/// Shortcuts / distributed notifications — enters here. The router applies
/// policy, then delivers into the **Peek hub** (`PeekNotificationCenter`).
///
/// ```
///  [Widgets] [Focus] [System apps] [API / URL / Shortcuts]
///              └──────────► DynamoNotificationRouter ──► Peek hub
/// ```
///
/// This is not a passive mirror of macOS Notification Center. Dynamo owns
/// routing decisions; the Peek island is the presentation surface.
@MainActor
final class DynamoNotificationRouter: ObservableObject {
    static let shared = DynamoNotificationRouter()

    private static let systemRouteKey = "dynamo.router.systemEnabled"
    private static let widgetRouteKey = "dynamo.router.widgetsEnabled"
    private static let externalRouteKey = "dynamo.router.externalEnabled"
    private static let focusRouteKey = "dynamo.router.focusEnabled"

    /// Where an alert came from (for hub labels + policy).
    enum Source: String, CaseIterable, Identifiable {
        case widget
        case focus
        case system
        case call
        case api
        case external
        case test

        var id: String { rawValue }

        var title: String {
            switch self {
            case .widget: return "Widgets"
            case .focus: return "Focus"
            case .system: return "System apps"
            case .call: return "Calls"
            case .api: return "API"
            case .external: return "External"
            case .test: return "Test"
            }
        }

        var systemImage: String {
            switch self {
            case .widget: return "square.grid.2x2"
            case .focus: return "brain.head.profile"
            case .system: return "app.badge"
            case .call: return "phone.fill"
            case .api: return "link"
            case .external: return "arrow.left.arrow.right"
            case .test: return "checkmark.seal"
            }
        }
    }

    /// Master switch — when off, nothing is routed (Peek hub stays idle).
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "dynamo.router.enabled") }
    }

    @Published var routeWidgets: Bool {
        didSet { UserDefaults.standard.set(routeWidgets, forKey: Self.widgetRouteKey) }
    }

    @Published var routeFocus: Bool {
        didSet { UserDefaults.standard.set(routeFocus, forKey: Self.focusRouteKey) }
    }

    /// Ingest Messages / FaceTime / Mail / other NC apps into the hub.
    @Published var routeSystemApps: Bool {
        didSet {
            UserDefaults.standard.set(routeSystemApps, forKey: Self.systemRouteKey)
            // Keep legacy mirror flag in sync so existing UI/bindings still work.
            if SystemNotificationMirror.shared.isEnabled != routeSystemApps {
                SystemNotificationMirror.shared.isEnabled = routeSystemApps
            }
        }
    }

    @Published var routeExternal: Bool {
        didSet { UserDefaults.standard.set(routeExternal, forKey: Self.externalRouteKey) }
    }

    @Published private(set) var routedCount: Int = 0
    @Published private(set) var lastRoutedSource: Source?
    @Published private(set) var lastRoutedTitle: String = ""
    @Published private(set) var lastStatus: String = "Router ready"

    private var registryCancellable: AnyCancellable?
    private var mirrorEnabledCancellable: AnyCancellable?
    private weak var hub: PeekNotificationCenter?

    private init() {
        if UserDefaults.standard.object(forKey: "dynamo.router.enabled") == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: "dynamo.router.enabled")
        }
        if UserDefaults.standard.object(forKey: Self.widgetRouteKey) == nil {
            routeWidgets = true
        } else {
            routeWidgets = UserDefaults.standard.bool(forKey: Self.widgetRouteKey)
        }
        if UserDefaults.standard.object(forKey: Self.focusRouteKey) == nil {
            routeFocus = true
        } else {
            routeFocus = UserDefaults.standard.bool(forKey: Self.focusRouteKey)
        }
        if UserDefaults.standard.object(forKey: Self.externalRouteKey) == nil {
            routeExternal = true
        } else {
            routeExternal = UserDefaults.standard.bool(forKey: Self.externalRouteKey)
        }
        // Prefer existing system-mirror preference as the system route default.
        if UserDefaults.standard.object(forKey: Self.systemRouteKey) == nil {
            routeSystemApps = SystemNotificationMirror.shared.isEnabled
        } else {
            routeSystemApps = UserDefaults.standard.bool(forKey: Self.systemRouteKey)
        }
    }

    // MARK: - Bootstrap

    /// Wire the router as the only path into the Peek hub.
    func start(registry: WidgetRegistry, hub: PeekNotificationCenter) {
        self.hub = hub
        lastStatus = "Dynamo routing into Peek hub"

        // Widgets → router (replaces direct hub attach of sneakPeekPublisher).
        registryCancellable = registry.sneakPeekPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] peek in
                self?.route(peek, source: .widget, category: "widget")
            }

        // Keep system ingest toggle aligned with router policy.
        if SystemNotificationMirror.shared.isEnabled != routeSystemApps {
            SystemNotificationMirror.shared.isEnabled = routeSystemApps
        }
        mirrorEnabledCancellable = SystemNotificationMirror.shared.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if self.routeSystemApps != enabled {
                    self.routeSystemApps = enabled
                }
            }

        // Focus / call peeks
        FocusController.shared.emitPeek = { [weak self] peek in
            let cat: String
            let detail = peek.detail.lowercased()
            if detail.hasPrefix("call") {
                cat = "call"
                self?.route(peek, source: .call, category: cat, id: "call|\(peek.title)|\(peek.subtitle)")
            } else {
                cat = "focus"
                self?.route(peek, source: .focus, category: cat, id: "focus|\(peek.title)|\(peek.subtitle)")
            }
        }

        SystemNotificationMirror.shared.start()
        lastStatus = routeSystemApps
            ? "Routing widgets · Focus · system apps → Peek"
            : "Routing widgets · Focus → Peek (system apps off)"
    }

    func stop() {
        registryCancellable?.cancel()
        registryCancellable = nil
        mirrorEnabledCancellable?.cancel()
        mirrorEnabledCancellable = nil
        SystemNotificationMirror.shared.stop()
        lastStatus = "Router stopped"
    }

    // MARK: - Route

    /// Single entry for any source. Applies router policy, then Peek hub delivery.
    @discardableResult
    func route(
        _ peek: NotchSneakPeek,
        source: Source,
        category: String? = nil,
        id: String? = nil,
        coalesce: Bool = true
    ) -> Bool {
        guard isEnabled else {
            lastStatus = "Router off — alert dropped"
            return false
        }
        guard allows(source) else {
            lastStatus = "Route blocked · \(source.title)"
            return false
        }

        let cat = category ?? defaultCategory(for: source, peek: peek)
        let hub = self.hub ?? PeekNotificationCenter.shared

        hub.deliver(
            peek,
            id: id ?? "\(source.rawValue)|\(cat)|\(peek.title)|\(peek.subtitle)",
            category: cat,
            coalesce: coalesce
        )

        routedCount &+= 1
        lastRoutedSource = source
        lastRoutedTitle = peek.title
        lastStatus = "Routed \(source.title) · \(peek.title)"
        return true
    }

    /// Convenience for API / system ingest payloads.
    @discardableResult
    func route(
        title: String,
        subtitle: String = "",
        detail: String = "",
        systemImage: String = "bell.fill",
        urgency: NotchSneakPeekUrgency = .normal,
        source: Source,
        category: String? = nil,
        id: String? = nil,
        artworkData: Data? = nil,
        coalesce: Bool = true
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return route(
            NotchSneakPeek(
                systemImage: systemImage,
                title: trimmed,
                subtitle: subtitle,
                urgency: urgency,
                artworkData: artworkData,
                detail: detail
            ),
            source: source,
            category: category,
            id: id,
            coalesce: coalesce
        )
    }

    // MARK: - Policy

    func allows(_ source: Source) -> Bool {
        switch source {
        case .widget: return routeWidgets
        case .focus: return routeFocus
        case .system: return routeSystemApps
        case .call: return routeSystemApps || routeFocus
        case .api, .external, .test: return routeExternal
        }
    }

    private func defaultCategory(for source: Source, peek: NotchSneakPeek) -> String {
        let d = peek.detail.lowercased()
        if d.hasPrefix("text") { return "text" }
        if d.hasPrefix("call") { return "call" }
        if d.hasPrefix("mail") { return "mail" }
        switch source {
        case .widget: return "widget"
        case .focus: return "focus"
        case .system: return "system"
        case .call: return "call"
        case .api: return "api"
        case .external: return "external"
        case .test: return "test"
        }
    }
}
