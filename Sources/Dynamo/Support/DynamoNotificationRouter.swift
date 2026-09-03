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
    private static let peekOnlyKey = "dynamo.router.peekOnlyDelivery"
    private static let replaceKey = "dynamo.router.replacesNotificationCenter"
    private static let replaceSetupKey = "dynamo.router.replacementSetupOffered"
    private static let bannerHintKey = "dynamo.router.replacementBannerHintDismissed"

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

    /// **Deliver through Peek, not typical macOS banners.**
    ///
    /// Dynamo never posts system banners for its own alerts. With Peek-only on:
    /// - Everything the router handles is presented as a notch Peek
    /// - Messages/calls get longer dwell + hub priority
    /// - Leftover Mac corner banners still need Alert style **None**
    ///   (Apple does not let apps hide other apps’ banners)
    @Published var peekOnlyDelivery: Bool {
        didSet {
            UserDefaults.standard.set(peekOnlyDelivery, forKey: Self.peekOnlyKey)
            if isBootstrapping { return }
            if peekOnlyDelivery {
                isEnabled = true
                PeekNotificationCenter.shared.isPrimaryDelivery = true
                if !routeSystemApps {
                    routeSystemApps = true
                }
                lastStatus = "Peek-only · alerts via notch (not banners)"
            } else if !replacesNotificationCenter {
                lastStatus = "Router on · Peek + system banners may both show"
            }
        }
    }

    /// One opt-in: Hub + Peek replace Notification Center **to a degree**.
    /// Turns on ingest, Peek-only delivery, and a one-time permissions walkthrough.
    @Published var replacesNotificationCenter: Bool {
        didSet {
            UserDefaults.standard.set(replacesNotificationCenter, forKey: Self.replaceKey)
            if isBootstrapping { return }
            if replacesNotificationCenter {
                engageReplacement(offerSetup: true)
            } else {
                disengageReplacement()
            }
        }
    }

    @Published var bannerHintDismissed: Bool {
        didSet { UserDefaults.standard.set(bannerHintDismissed, forKey: Self.bannerHintKey) }
    }

    @Published private(set) var routedCount: Int = 0
    @Published private(set) var lastRoutedSource: Source?
    @Published private(set) var lastRoutedTitle: String = ""
    @Published private(set) var lastStatus: String = "Router ready"

    private var registryCancellable: AnyCancellable?
    private var mirrorEnabledCancellable: AnyCancellable?
    private weak var hub: PeekNotificationCenter?
    private var isBootstrapping = true

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
        let peekOnlyWasSet = UserDefaults.standard.object(forKey: Self.peekOnlyKey) != nil
        let peekOnlyValue = peekOnlyWasSet ? UserDefaults.standard.bool(forKey: Self.peekOnlyKey) : false
        let storedReplace = UserDefaults.standard.object(forKey: Self.replaceKey) as? Bool
        let replaceValue = HubNotificationCenter.Replacement.isOptedIn(
            stored: storedReplace,
            peekOnlyWasSet: peekOnlyWasSet,
            peekOnly: peekOnlyValue
        )
        peekOnlyDelivery = peekOnlyValue
        replacesNotificationCenter = replaceValue
        if UserDefaults.standard.object(forKey: Self.systemRouteKey) == nil {
            routeSystemApps = replaceValue
        } else {
            routeSystemApps = UserDefaults.standard.bool(forKey: Self.systemRouteKey)
        }
        bannerHintDismissed = UserDefaults.standard.bool(forKey: Self.bannerHintKey)
        isBootstrapping = false
        if replaceValue {
            engageReplacement(offerSetup: false)
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
                self?.route(peek, source: .widget)
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

        if routeSystemApps {
            SystemNotificationMirror.shared.start()
        }
        if replacesNotificationCenter || peekOnlyDelivery {
            PeekNotificationCenter.shared.isPrimaryDelivery = true
        }
        lastStatus = HubNotificationCenter.Replacement.statusLine(
            optedIn: replacesNotificationCenter,
            accessDenied: SystemNotificationMirror.shared.accessDenied,
            routerEnabled: isEnabled
        )
    }

    func stop() {
        registryCancellable?.cancel()
        registryCancellable = nil
        mirrorEnabledCancellable?.cancel()
        mirrorEnabledCancellable = nil
        SystemNotificationMirror.shared.stop()
        lastStatus = "Router stopped"
    }

    /// Opt-in: Dynamo becomes the notification surface for this Mac (ingest + Peek + Hub).
    func engageReplacement(offerSetup: Bool) {
        isEnabled = true
        if !peekOnlyDelivery { peekOnlyDelivery = true }
        if !routeSystemApps { routeSystemApps = true }
        PeekNotificationCenter.shared.isPrimaryDelivery = true
        SystemNotificationMirror.shared.isEnabled = true
        SystemNotificationMirror.shared.start()
        lastStatus = HubNotificationCenter.Replacement.statusLine(
            optedIn: true,
            accessDenied: SystemNotificationMirror.shared.accessDenied,
            routerEnabled: true
        )
        guard offerSetup else { return }
        let alreadyOffered = UserDefaults.standard.bool(forKey: Self.replaceSetupKey)
        UserDefaults.standard.set(true, forKey: Self.replaceSetupKey)
        guard !alreadyOffered else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if SystemNotificationMirror.shared.accessDenied {
                HubNotificationCenter.openFullDiskAccess()
            }
            self?.openNotificationSettingsForPeekOnly()
        }
    }

    func disengageReplacement() {
        routeSystemApps = false
        peekOnlyDelivery = false
        lastStatus = HubNotificationCenter.Replacement.statusLine(
            optedIn: false,
            accessDenied: false,
            routerEnabled: isEnabled
        )
    }

    func dismissBannerHint() {
        bannerHintDismissed = true
    }

    // MARK: - Route

    /// Single entry for any source. Applies router policy, then Peek hub delivery.
    @discardableResult
    func route(
        _ peek: NotchSneakPeek,
        source: Source,
        category: String? = nil,
        id: String? = nil,
        coalesce: Bool = true,
        present: Bool = true
    ) -> Bool {
        guard isEnabled else {
            lastStatus = "Router off — alert dropped"
            return false
        }
        guard allows(source) else {
            lastStatus = "Route blocked · \(source.title)"
            return false
        }

        let cat = HubPeekPolicy.resolveCategory(peek: peek, source: source, explicit: category)
        let hub = self.hub ?? PeekNotificationCenter.shared

        // Peek-only: never fall back to system banners; present only via hub.
        var delivery = peek
        if peekOnlyDelivery || replacesNotificationCenter {
            PeekNotificationCenter.shared.isPrimaryDelivery = true
            delivery = Self.elevateForPeekOnly(peek, category: cat, source: source)
        }

        hub.deliver(
            delivery,
            id: id ?? "\(source.rawValue)|\(cat)|\(delivery.title)|\(delivery.subtitle)",
            category: cat,
            coalesce: coalesce,
            present: present
        )

        routedCount &+= 1
        lastRoutedSource = source
        lastRoutedTitle = delivery.title
        lastStatus = replacesNotificationCenter
            ? "Hub · \(source.title) · \(delivery.title)"
            : (peekOnlyDelivery
                ? "Peek · \(source.title) · \(delivery.title)"
                : "Routed \(source.title) · \(delivery.title)")
        return true
    }

    /// Longer-lived / higher-urgency presentation so Peek feels like the real alert.
    private static func elevateForPeekOnly(
        _ peek: NotchSneakPeek,
        category: String,
        source: Source
    ) -> NotchSneakPeek {
        var p = peek
        let isMessage = category == "text" || p.detail.lowercased().hasPrefix("text")
        let isCall = category == "call" || source == .call || p.detail.lowercased().hasPrefix("call")
        if isMessage || isCall {
            // Critical so they preempt quieter peeks and stay up longer.
            if p.urgency < .critical {
                p.urgency = .critical
            }
        } else if p.urgency < .high, source == .system {
            p.urgency = .high
        }
        return p
    }

    // MARK: - Peek-only setup (system banners)

    /// Apps users typically want delivered as Peeks instead of corner banners.
    static var peekOnlyTargetApps: [(name: String, bundleID: String)] {
        HubNotificationCenter.bannerSilenceApps
    }

    /// Open System Settings → Notifications so the user can set alert style to **None**.
    /// Apple does not allow third-party apps to hide other apps’ banners for you.
    func openNotificationSettingsForPeekOnly() {
        // Sequoia+ Notifications pane
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
            "x-apple.systempreferences:com.apple.focus"
        ]
        for s in candidates {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                lastStatus = "Set Messages/FaceTime alert style to None — keep Allow Notifications on so Dynamo can still route them into Peek"
                return
            }
        }
    }

    func openFocusForPeekOnly() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.focus") {
            NSWorkspace.shared.open(url)
            lastStatus = "Optional: Focus can silence banners while Dynamo still shows Peeks"
        }
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
        coalesce: Bool = true,
        present: Bool = true,
        sourceBundleID: String = "",
        appName: String = ""
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
                detail: detail,
                category: category ?? "",
                sourceBundleID: sourceBundleID,
                appName: appName
            ),
            source: source,
            category: category,
            id: id,
            coalesce: coalesce,
            present: present
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
        HubPeekPolicy.resolveCategory(peek: peek, source: source)
    }
}
