import XCTest
@testable import CodeIslandCore

final class GrokQuotaTests: XCTestCase {
    func testParsesWeeklyCreditWindowAndProductSplit() throws {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-01T13:15:44.106+00:00","end":"2026-11-08T13:15:44.106+00:00"},"creditUsagePercent":88,"productUsage":[{"product":"GrokBuild","usagePercent":43},{"product":"","usagePercent":5},{"product":"GrokChat","usagePercent":3}]}}
        """
        let snapshot = try XCTUnwrap(GrokQuotaLoader.parse(Data(json.utf8), capturedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(snapshot.usedPercent, 88)
        XCTAssertEqual(snapshot.periodMinutes, 7 * 1440)
        XCTAssertEqual(snapshot.resetsAt, ClaudeUsageScanner.parseISO8601("2026-11-08T13:15:44.106+00:00"))
        XCTAssertEqual(snapshot.products.map(\.name), ["GrokBuild", "GrokChat"])
    }

    func testRejectsPayloadWithoutACreditPercent() {
        XCTAssertNil(GrokQuotaLoader.parse(Data("{\"config\":{}}".utf8)))
        XCTAssertNil(GrokQuotaLoader.parse(Data("not json".utf8)))
    }

    func testTokenPrefersUnexpiredKeyAndIgnoresRefreshToken() throws {
        let json = """
        {"https://auth.example/old":{"key":"stale-key","refresh_token":"nope","expires_at":"2020-01-01T00:00:00Z"},"https://auth.example/new":{"key":"fresh-key","expires_at":"2099-01-01T00:00:00Z"}}
        """
        XCTAssertEqual(GrokQuotaLoader.token(in: Data(json.utf8)), "fresh-key")
        XCTAssertNil(GrokQuotaLoader.token(in: Data("{}".utf8)))
    }
}
