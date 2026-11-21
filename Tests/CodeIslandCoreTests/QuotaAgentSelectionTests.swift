import XCTest
@testable import CodeIslandCore

final class QuotaAgentSelectionTests: XCTestCase {
    private func session(_ source: String, _ status: AgentStatus, _ seconds: TimeInterval) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = source
        session.status = status
        session.lastActivity = Date(timeIntervalSince1970: seconds)
        return session
    }

    func testRunningAgentTakesPrecedenceOverIdleSelection() {
        let sessions = ["a": session("claude", .idle, 20), "b": session("codex", .running, 10)]
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: sessions, activeID: "a"), .codex)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: sessions, activeID: "b"), .codex)
    }

    func testSelectedAgentWinsWhenBothAreRunning() {
        let sessions = ["a": session("claude", .processing, 10), "b": session("codex", .running, 20)]
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: sessions, activeID: "a"), .claude)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: sessions, activeID: "b"), .codex)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: sessions, activeID: nil), .codex)
    }

    func testRetainsSelectionWhenIdleAndDoesNotMislabelOtherAgents() {
        let sessions = ["a": session("claude", .idle, 20), "b": session("codex", .idle, 10), "c": session("gemini", .running, 30)]
        XCTAssertNil(QuotaAgentSelection.resolve(sessions: sessions, activeID: "c"))
        let idle = sessions.filter { $0.key != "c" }
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: idle, activeID: "b"), .codex)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: idle, activeID: nil), .claude)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: ["g": session("grok", .idle, 5)], activeID: "g"), .grok)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: ["u": session("cursor", .processing, 5)], activeID: "u"), .cursor)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: ["u": session("cursor-cli", .idle, 5)], activeID: "u"), .cursor)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: ["ag": session("google-antigravity", .processing, 5)], activeID: "ag"), .antigravity)
        XCTAssertEqual(QuotaAgentSelection.resolve(sessions: ["ag": session("agy", .idle, 5)], activeID: "ag"), .antigravity)
        XCTAssertNil(QuotaAgentSelection.resolve(sessions: [:], activeID: nil))
    }
}
