import XCTest
@testable import Dynamo

final class ClipboardHistoryPolicyTests: XCTestCase {

    func testTrimKeepsNewestPrefix() {
        let items = (0..<5).map { i in
            ClipboardHistoryItem(kind: .text, text: "\(i)")
        }
        let result = ClipboardHistoryPolicy.trim(items, limit: 3)
        XCTAssertEqual(result.kept.map(\.text), ["0", "1", "2"])
        XCTAssertEqual(result.dropped.map(\.text), ["3", "4"])
    }

    func testTrimNoOpWhenUnderLimit() {
        let items = [ClipboardHistoryItem(kind: .text, text: "a")]
        let result = ClipboardHistoryPolicy.trim(items, limit: 20)
        XCTAssertEqual(result.kept.count, 1)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testSearchMatchesFilePathAndName() {
        let item = ClipboardHistoryItem(
            kind: .file,
            text: "Report.pdf",
            filePath: "/Users/me/Documents/Report.pdf"
        )
        XCTAssertTrue(ClipboardHistoryPolicy.matches(item, query: "report"))
        XCTAssertTrue(ClipboardHistoryPolicy.matches(item, query: "Documents"))
        XCTAssertFalse(ClipboardHistoryPolicy.matches(item, query: "xlsx"))
        XCTAssertTrue(ClipboardHistoryPolicy.matches(item, query: "  "))
    }

    func testDuplicateTextAndFile() {
        let a = ClipboardHistoryItem(kind: .text, text: "hello")
        let b = ClipboardHistoryItem(kind: .text, text: "hello")
        let c = ClipboardHistoryItem(kind: .file, text: "a.txt", filePath: "/tmp/a.txt")
        let d = ClipboardHistoryItem(kind: .file, text: "a.txt", filePath: "/tmp/a.txt")
        XCTAssertTrue(ClipboardHistoryPolicy.isDuplicate(a, of: b))
        XCTAssertTrue(ClipboardHistoryPolicy.isDuplicate(c, of: d))
        XCTAssertFalse(ClipboardHistoryPolicy.isDuplicate(a, of: c))
    }

    func testPinTagCyclesAllCases() {
        var tag = ClipboardPinTag.none
        var seen = Set<ClipboardPinTag>()
        for _ in 0..<ClipboardPinTag.allCases.count {
            seen.insert(tag)
            tag = tag.next
        }
        XCTAssertEqual(seen.count, ClipboardPinTag.allCases.count)
        XCTAssertEqual(tag, .none)
    }

    func testLegacySnippetJSONDecodesWithoutTagOrFile() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Old","text":"hi","updatedAt":0}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let snippet = try decoder.decode(PinnedSnippet.self, from: json)
        XCTAssertEqual(snippet.tag, .none)
        XCTAssertEqual(snippet.kind, .text)
        XCTAssertNil(snippet.filePath)
        XCTAssertEqual(snippet.text, "hi")
    }
}

final class DynamoURLCommandTests: XCTestCase {

    func testKnownHosts() {
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://show")!), .show)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://notch")!), .show)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://playpause")!), .play)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://clipboard")!), .clipboard)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://paste")!), .clipboard)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://hub")!), .hub)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://inbox")!), .hub)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://airdrop")!), .airdrop)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://peek?title=Hi")!), .notify)
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "https://example.com")!), .unknown("https"))
        XCTAssertEqual(DynamoURLCommand.parse(URL(string: "dynamo://nope")!), .unknown("nope"))
    }
}
