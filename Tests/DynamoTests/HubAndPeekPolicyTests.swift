import XCTest
@testable import Dynamo

final class HubPeekPolicyTests: XCTestCase {

    func testCalendarImageIsCalendarNotWidget() {
        let peek = NotchSneakPeek(
            systemImage: "calendar",
            title: "Standup",
            subtitle: "Starts in 15 minutes",
            urgency: .high,
            detail: "Work"
        )
        XCTAssertEqual(
            HubPeekPolicy.resolveCategory(peek: peek, source: .widget, explicit: "widget"),
            "calendar"
        )
    }

    func testExplicitHintWinsOverInference() {
        let peek = NotchSneakPeek(
            systemImage: "calendar",
            title: "Standup",
            subtitle: "x",
            category: "calendar"
        )
        XCTAssertEqual(
            HubPeekPolicy.resolveCategory(peek: peek, source: .widget, explicit: "battery"),
            "battery"
        )
    }

    func testMediaStyleIsMedia() {
        let peek = NotchSneakPeek(
            systemImage: "music.note",
            title: "Song",
            subtitle: "Artist",
            style: .media
        )
        XCTAssertEqual(HubPeekPolicy.resolveCategory(peek: peek, source: .widget), "media")
    }

    func testHubCalendarFilterMatchesInferredCategory() {
        let item = PeekNotificationCenter.PeekHistoryItem(
            id: "1",
            category: "calendar",
            title: "Standup",
            subtitle: "in 5m",
            detail: "Work",
            systemImage: "calendar",
            urgency: .high,
            deliveredAt: Date(),
            isUnread: true
        )
        XCTAssertTrue(HubInboxFilter.calendar.matches(item))
        XCTAssertFalse(HubInboxFilter.media.matches(item))
        XCTAssertTrue(HubInboxFilter.unread.matches(item))
    }
}

final class HubNotificationCenterTests: XCTestCase {

    func testGroupsMacAppsByBundleThenDynamoByCategory() {
        let messages = PeekNotificationCenter.PeekHistoryItem(
            id: "m1",
            category: "text",
            title: "Alex",
            subtitle: "hey",
            detail: "Text · Messages",
            systemImage: "message.fill",
            urgency: .critical,
            deliveredAt: Date(),
            isUnread: true,
            sourceBundleID: "com.apple.MobileSMS",
            appName: "Messages"
        )
        let mail = PeekNotificationCenter.PeekHistoryItem(
            id: "mail1",
            category: "mail",
            title: "Invoice",
            subtitle: "Due",
            detail: "Mail",
            systemImage: "envelope.fill",
            urgency: .high,
            deliveredAt: Date(),
            isUnread: false,
            sourceBundleID: "com.apple.mail",
            appName: "Mail"
        )
        let cal = PeekNotificationCenter.PeekHistoryItem(
            id: "c1",
            category: "calendar",
            title: "Standup",
            subtitle: "now",
            detail: "Work",
            systemImage: "calendar",
            urgency: .high,
            deliveredAt: Date(),
            isUnread: true
        )
        let groups = HubNotificationCenter.grouped([messages, mail, cal])
        XCTAssertEqual(groups.map(\.id), ["com.apple.MobileSMS", "com.apple.mail", "dynamo.calendar"])
        XCTAssertEqual(groups[0].title, "Messages")
        XCTAssertEqual(groups[0].unread, 1)
        XCTAssertEqual(groups[2].title, "Calendar")
        XCTAssertEqual(groups[2].bundleID, "")
    }

    func testGroupKeyFallsBackToDynamo() {
        let item = PeekNotificationCenter.PeekHistoryItem(
            id: "x",
            category: "",
            title: "Ping",
            subtitle: "",
            detail: "",
            systemImage: "bell.fill",
            urgency: .normal,
            deliveredAt: Date(),
            isUnread: false
        )
        XCTAssertEqual(HubNotificationCenter.groupKey(item), "dynamo")
        XCTAssertEqual(HubNotificationCenter.groupTitle(item), "Dynamo")
    }
}

final class CalendarPeekPolicyTests: XCTestCase {

    func testDefaultLeadFiresTLeadThenT5ThenNow() {
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 15 * 60, leadMinutes: 15), "tlead")
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 5 * 60, leadMinutes: 15), "t5")
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 20, leadMinutes: 15), "now")
    }

    func testFiveMinuteLeadDoesNotUseT15() {
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 5 * 60, leadMinutes: 5), "tlead")
        XCTAssertNil(CalendarPeekPolicy.stage(intervalUntilStart: 15 * 60, leadMinutes: 5))
    }

    func testThirtyMinuteLeadGetsT15() {
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 30 * 60, leadMinutes: 30), "tlead")
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 15 * 60, leadMinutes: 30), "t15")
        XCTAssertEqual(CalendarPeekPolicy.stage(intervalUntilStart: 5 * 60, leadMinutes: 30), "t5")
    }

    func testOutsideWindowIsNil() {
        XCTAssertNil(CalendarPeekPolicy.stage(intervalUntilStart: 90 * 60, leadMinutes: 15))
        XCTAssertNil(CalendarPeekPolicy.stage(intervalUntilStart: -120, leadMinutes: 15))
    }
}

final class NotesScriptResultTests: XCTestCase {

    func testParsesSinglePipeError() {
        switch NotesScriptResult.parse("ERR|-1743:Not authorized to send Apple events") {
        case .error(let msg):
            XCTAssertTrue(msg.contains("-1743"))
        default:
            XCTFail("expected error")
        }
    }

    func testParsesLegacyTriplePipe() {
        switch NotesScriptResult.parse("ERR|||-600:Notes isn’t running") {
        case .error(let msg):
            XCTAssertTrue(msg.contains("-600"))
        default:
            XCTFail("expected error")
        }
    }

    func testOK() {
        XCTAssertEqual(NotesScriptResult.parse("OK"), .ok("OK"))
        XCTAssertTrue(NotesScriptResult.parse(nil).isFailure)
    }
}

final class SportsScoreboardLogicTests: XCTestCase {

    func testLiveScoreUpdateBeatsStaleLive() {
        let stale = sample(id: "nba-1", status: .live, home: "10", away: "8", homeLogo: nil)
        let fresh = sample(id: "nba-1", status: .live, home: "12", away: "8", homeLogo: "https://logo")
        var combined: [String: SportsEvent] = ["nba-1": stale]
        SportsScoreboardLogic.merge([fresh], into: &combined)
        XCTAssertEqual(combined["nba-1"]?.homeScore, "12")
        XCTAssertEqual(combined["nba-1"]?.homeLogoURL, "https://logo")
    }

    func testFinalReplacesLive() {
        let live = sample(id: "nba-1", status: .live, home: "99", away: "98", homeLogo: nil)
        let fin = sample(id: "nba-1", status: .final, home: "100", away: "98", homeLogo: nil)
        XCTAssertEqual(SportsScoreboardLogic.preferred(live, fin).status, .final)
    }

    func testEasternDayString() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 21))!
        // 21:00 PT = 00:00 next day ET
        XCTAssertEqual(
            SportsScoreboardLogic.dayString(date, timeZone: TimeZone(identifier: "America/New_York")!),
            "20260102"
        )
    }

    private func sample(
        id: String,
        status: SportsEventStatus,
        home: String,
        away: String,
        homeLogo: String?
    ) -> SportsEvent {
        SportsEvent(
            id: id,
            league: .nba,
            name: "Game",
            detail: "",
            status: status,
            homeName: "Home",
            awayName: "Away",
            homeScore: home,
            awayScore: away,
            homeAbbrev: "HOM",
            awayAbbrev: "AWY",
            homeLogoURL: homeLogo,
            awayLogoURL: nil,
            statusText: status.label,
            startDate: nil,
            linkURL: nil,
            headlineScore: nil,
            broadcast: nil
        )
    }
}

@MainActor
final class FocusAgendaRememberTests: XCTestCase {

    func testRememberIsFIFOAndDoesNotReinsert() {
        var keys: [String] = []
        XCTAssertTrue(FocusAgendaEngine.remember("a", in: &keys, cap: 3, keep: 2))
        XCTAssertFalse(FocusAgendaEngine.remember("a", in: &keys, cap: 3, keep: 2))
        _ = FocusAgendaEngine.remember("b", in: &keys, cap: 3, keep: 2)
        _ = FocusAgendaEngine.remember("c", in: &keys, cap: 3, keep: 2)
        XCTAssertTrue(FocusAgendaEngine.remember("d", in: &keys, cap: 3, keep: 2))
        XCTAssertEqual(keys, ["c", "d"])
    }
}

final class CalendarMonthStripTests: XCTestCase {

    func testThirtyDaysFromMonday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 3))!
        let days = CalendarMonthStrip.days(from: start, count: 30, calendar: cal)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(cal.component(.day, from: days[0]), 3)
        XCTAssertEqual(cal.component(.day, from: days[29]), 2)
        XCTAssertEqual(cal.component(.month, from: days[29]), 10)
    }
}

final class SportsLiveStatusTests: XCTestCase {

    func testLiveClockAppended() {
        let text = SportsScoreboardLogic.liveStatusText(
            detail: "3rd Quarter",
            displayClock: "4:12",
            period: 3,
            isLive: true
        )
        XCTAssertTrue(text.contains("4:12"))
        XCTAssertTrue(text.contains("3rd"))
    }

    func testNonLiveKeepsDetailOnly() {
        XCTAssertEqual(
            SportsScoreboardLogic.liveStatusText(
                detail: "7:00 PM",
                displayClock: "12:00",
                period: 1,
                isLive: false
            ),
            "7:00 PM"
        )
    }
}
