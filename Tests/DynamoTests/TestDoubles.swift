import Foundation
@testable import Dynamo

/// EventKit-free calendar for factory / geometry tests.
@MainActor
final class StubCalendarProvider: CalendarProvider {
    var authorizationState: CalendarAuthState
    var upcoming: [CalendarEventItem] = []
    var onChange: (() -> Void)?

    init(authorizationState: CalendarAuthState = .notDetermined) {
        self.authorizationState = authorizationState
    }

    func start() {}
    func stop() {}
    func requestAccess() async {}
    func refresh() { onChange?() }
}

@MainActor
enum ProductionTestFixtures {
    static func bundle(
        calendarAuth: CalendarAuthState = .authorized
    ) -> ProductionWidgetBundle {
        ProductionWidgets.makeDefaultPlugins(
            mediaProvider: MockNowPlayingProvider(),
            calendarProvider: StubCalendarProvider(authorizationState: calendarAuth)
        )
    }
}
