import XCTest
@testable import CodeIslandCore

final class CursorQuotaTests: XCTestCase {
    func testDecryptsCursorSafeStorageToken() {
        let encoded = "cursor-safe-storage:v1:djEwfWf06J+RaGVycInbP0yqji/+HBQo78auXCRu+f629Xw="
        XCTAssertEqual(CursorQuotaLoader.decryptStoredToken(encoded, password: "test-passphrase"), "fake.access.token")
        XCTAssertNil(CursorQuotaLoader.decryptStoredToken(encoded, password: "wrong-password"))
        XCTAssertNil(CursorQuotaLoader.decryptStoredToken("cursor-safe-storage:v1:invalid", password: "test-passphrase"))
        XCTAssertNil(CursorQuotaLoader.decryptStoredToken("cursor-safe-storage:v1:djExYQ==", password: "test-passphrase"))
    }

    func testParsesIncludedSpendAgainstPlanLimit() throws {
        let json = """
        {"enabled":true,"billingCycleEnd":"1798000000000","displayMessage":"35% of included usage","planUsage":{"includedSpend":3500,"limit":10000,"totalPercentUsed":99,"autoPercentUsed":12.5,"apiPercentUsed":40}}
        """
        let snapshot = try XCTUnwrap(CursorQuotaLoader.parse(Data(json.utf8), capturedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(snapshot.usedPercent, 35)
        XCTAssertEqual(snapshot.autoUsedPercent, 12.5)
        XCTAssertEqual(snapshot.apiUsedPercent, 40)
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 1_798_000_000))
        XCTAssertEqual(snapshot.displayMessage, "35% of included usage")
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 100))
    }

    func testFallsBackToTotalPercentWhenLimitIsMissing() {
        let json = """
        {"plan_usage":{"total_percent_used":18},"billing_cycle_end":1700000000}
        """
        let snapshot = CursorQuotaLoader.parse(Data(json.utf8))
        XCTAssertEqual(snapshot?.usedPercent, 18)
        XCTAssertEqual(snapshot?.resetsAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testRejectsDisabledOrEmptyPayload() {
        XCTAssertNil(CursorQuotaLoader.parse(Data("{\"enabled\":false,\"planUsage\":{\"limit\":100,\"includedSpend\":10}}".utf8)))
        XCTAssertNil(CursorQuotaLoader.parse(Data("{\"planUsage\":{}}".utf8)))
        XCTAssertNil(CursorQuotaLoader.parse(Data("not json".utf8)))
    }

    func testChecksumMatchesCursorClientScramble() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let checksum = CursorQuotaLoader.checksum(machineId: "machine", macMachineId: "mac", now: now)
        XCTAssertEqual(checksum, "Vfb45Bi9machine/mac")
        XCTAssertEqual(
            CursorQuotaLoader.checksum(machineId: "machine", macMachineId: nil, now: now),
            "Vfb45Bi9machine"
        )
    }

    func testNormalizeTokenStripsJSONQuotes() {
        XCTAssertEqual(CursorQuotaLoader.normalizeToken("\"abc.def.ghi\""), "abc.def.ghi")
        XCTAssertEqual(CursorQuotaLoader.normalizeToken("  raw-token  "), "raw-token")
        XCTAssertNil(CursorQuotaLoader.normalizeToken("   "))
        XCTAssertNil(CursorQuotaLoader.normalizeToken("\"\""))
    }

    func testReadsTokenFromStateDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.vscdb")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\"desk-token\"');"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(CursorQuotaLoader.token(in: db), "desk-token")
        XCTAssertNil(CursorQuotaLoader.token(in: dir.appendingPathComponent("missing.vscdb")))
    }
}
