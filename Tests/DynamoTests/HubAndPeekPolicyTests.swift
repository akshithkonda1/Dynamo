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
