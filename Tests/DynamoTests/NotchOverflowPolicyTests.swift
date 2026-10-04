import XCTest
@testable import Dynamo

/// Cards must overflow sideways. A vertical `ScrollView` in a widget expanded
/// card would hide content under the 200pt cap — this test reads sources so
/// that regression fails CI.
final class NotchOverflowPolicyTests: XCTestCase {

    func testWidgetSourcesDoNotUseVerticalScrollView() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgets = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Dynamo/Widgets", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(
            at: widgets,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var swiftFiles: [URL] = []
        var stack = files
        while let url = stack.popLast() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let kids = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                stack.append(contentsOf: kids)
            } else if url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }
        XCTAssertFalse(swiftFiles.isEmpty, "Did not find widget sources next to the test target")

        let vertical = try NSRegularExpression(pattern: #"ScrollView\s*(?:\(\s*\.vertical|\s*\{)"#)
        var offenders: [String] = []
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if vertical.firstMatch(in: text, range: range) != nil {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Widget card uses vertical ScrollView for overflow (must be left/right): \(offenders.joined(separator: ", "))"
        )
    }
}
