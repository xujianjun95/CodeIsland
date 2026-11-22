import Foundation
import XCTest
@testable import CodeIslandCore

final class CodexQuotaTests: XCTestCase {
    func testOptionalLocalQuotaSmoke() throws {
        guard let root = ProcessInfo.processInfo.environment["CODEISLAND_QUOTA_TEST_ROOT"], !root.isEmpty else {
            throw XCTSkip("No local quota test root provided")
        }
        let snapshot = try XCTUnwrap(CodexQuotaLoader.load(root: URL(fileURLWithPath: root)))
        XCTAssertFalse(snapshot.windows.isEmpty)
    }

    func testParsesBothWindowsAndRejectsInvalidRecords() throws {
        let line = #"{"timestamp":"2026-11-06T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_at":1793960000},"secondary":{"used_percent":73,"window_minutes":10080}}}}"#
        let snapshot = try XCTUnwrap(CodexQuotaLoader.parse(line))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 37.5)
        XCTAssertEqual(snapshot.windows[1].minutes, 10080)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNil(CodexQuotaLoader.parse(#"{"type":"event_msg","payload":{}}"#))
        XCTAssertNil(CodexQuotaLoader.parse("not json"))
        let otherBucket = #"{"timestamp":"2026-11-06T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"other","primary":{"used_percent":10,"window_minutes":300}}}}"#
        XCTAssertNil(CodexQuotaLoader.parse(otherBucket))
        let fractional = line.replacingOccurrences(of: "2026-11-06T10:00:00Z", with: "2026-11-06T10:00:00.802Z")
        XCTAssertNotNil(CodexQuotaLoader.parse(fractional))
    }

    func testSelectsNewestRecordAcrossFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("rollout-a.jsonl")
        let second = directory.appendingPathComponent("rollout-b.jsonl")
        let early = #"{"timestamp":"2026-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300}}}}"#
        let late = #"{"timestamp":"2026-01-02T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":30,"window_minutes":300}}}}"#
        try (late + "\n").write(to: first, atomically: true, encoding: .utf8)
        try (early + "\n").write(to: second, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(CodexQuotaLoader.load(root: directory))
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)
    }

    func testLowestRemainingWindowPicksTighterWindowAndShortWindowOnTie() {
        let tighterWeekly = CodexQuotaSnapshot(
            capturedAt: Date(),
            windows: [
                CodexQuotaWindow(usedPercent: 10, minutes: 300, resetsAt: nil),
                CodexQuotaWindow(usedPercent: 97, minutes: 10080, resetsAt: nil),
            ]
        )
        XCTAssertEqual(tighterWeekly.lowestRemainingWindow()?.minutes, 10080)
        XCTAssertEqual(tighterWeekly.lowestRemainingWindow()?.remainingPercent ?? -1, 3, accuracy: 0.001)

        let tied = CodexQuotaSnapshot(
            capturedAt: Date(),
            windows: [
                CodexQuotaWindow(usedPercent: 0, minutes: 10080, resetsAt: nil),
                CodexQuotaWindow(usedPercent: 0, minutes: 300, resetsAt: nil),
            ]
        )
        XCTAssertEqual(tied.lowestRemainingWindow()?.minutes, 300)
    }
}
