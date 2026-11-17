import Foundation
import SQLite3
import CommonCrypto
import Security

public struct CursorQuotaSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let usedPercent: Double
    public let autoUsedPercent: Double?
    public let apiUsedPercent: Double?
    public let resetsAt: Date?
    public let displayMessage: String?
}

public enum CursorQuotaFetch: Equatable, Sendable {
    case snapshot(CursorQuotaSnapshot)
    case needsLogin
    case failed
    case keychainDenied
}

/// Reads the plan usage Cursor's own settings page shows.
/// Uses the desktop login already stored on this Mac. The token is only read, never refreshed or logged.
public enum CursorQuotaLoader {
    public static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    public static func load(databaseURL: URL, storageURL: URL, clientVersion: String) async -> CursorQuotaFetch {
        guard let storedToken = token(in: databaseURL) else { return .needsLogin }
        let token: String
        if storedToken.hasPrefix("cursor-safe-storage:") {
            guard storedToken.hasPrefix("cursor-safe-storage:v1:") else { return .failed }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Cursor Safe Storage",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                return .keychainDenied
            }
            guard status == errSecSuccess, let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  let decrypted = decryptStoredToken(storedToken, password: password) else { return .failed }
            token = decrypted
        } else {
            token = storedToken
        }
        let identity = machineIdentity(in: storageURL)
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(clientVersion, forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
        if let machineId = identity.machineId {
            request.setValue(
                checksum(machineId: machineId, macMachineId: identity.macMachineId),
                forHTTPHeaderField: "x-cursor-checksum"
            )
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { return .needsLogin }
                guard (200...299).contains(http.statusCode) else { return .failed }
            }
            guard let snapshot = parse(data) else { return .failed }
            return .snapshot(snapshot)
        } catch {
            return .failed
        }
    }

    /// `state.vscdb` stores the access token as text, sometimes JSON-quoted.
    public static func token(in databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let encoded = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let uri = "file://\(encoded)?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else { return nil }
        return normalizeToken(String(cString: cString))
    }

    /// Same header Cursor's dashboard client sends: a scrambled timestamp plus the local machine ids.
    public static func checksum(machineId: String, macMachineId: String?, now: Date = Date()) -> String {
        let stamp = UInt64(now.timeIntervalSince1970 * 1000) / 1_000_000
        // Cursor's JavaScript bitwise shifts use a 32-bit value and wrap shift counts modulo 32.
        let javascriptStamp = UInt32(truncatingIfNeeded: stamp)
        var bytes: [UInt8] = [
            UInt8((javascriptStamp >> 8) & 255),
            UInt8(javascriptStamp & 255),
            UInt8((javascriptStamp >> 24) & 255),
            UInt8((javascriptStamp >> 16) & 255),
            UInt8((javascriptStamp >> 8) & 255),
            UInt8(javascriptStamp & 255),
        ]
        var seed: UInt8 = 165
        for index in bytes.indices {
            let mixed = (bytes[index] ^ seed) &+ UInt8(index % 256)
            bytes[index] = mixed
            seed = mixed
        }
        let prefix = Data(bytes).base64EncodedString()
        if let macMachineId, !macMachineId.isEmpty {
            return "\(prefix)\(machineId)/\(macMachineId)"
        }
        return "\(prefix)\(machineId)"
    }

    public static func machineIdentity(in storageURL: URL) -> (machineId: String?, macMachineId: String?) {
        guard let data = try? Data(contentsOf: storageURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, nil)
        }
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (text("telemetry.machineId"), text("telemetry.macMachineId"))
    }

    public static func normalizeToken(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // state.vscdb sometimes stores the string JSON-encoded, with surrounding quotes.
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
            trimmed = trimmed.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Electron safeStorage on macOS uses the Keychain password to derive an AES-128-CBC key.
    static func decryptStoredToken(_ stored: String, password: String) -> String? {
        let prefix = "cursor-safe-storage:v1:"
        guard stored.hasPrefix(prefix), !password.isEmpty,
              let encrypted = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              encrypted.starts(with: Data("v10".utf8)) else { return nil }
        let ciphertext = encrypted.dropFirst(3)
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withCString { passwordBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var length = 0
        let status = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, ciphertext.count, &plaintext, plaintext.count, &length)
        }
        guard status == kCCSuccess, let token = String(bytes: plaintext.prefix(length), encoding: .utf8) else { return nil }
        return normalizeToken(token)
    }

    public static func parse(_ data: Data, capturedAt: Date = Date()) -> CursorQuotaSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let enabled = object["enabled"] as? Bool, enabled == false { return nil }
        guard let plan = (object["planUsage"] as? [String: Any]) ?? (object["plan_usage"] as? [String: Any]) else { return nil }
        guard let used = usedPercent(in: plan) else { return nil }
        return CursorQuotaSnapshot(
            capturedAt: capturedAt,
            usedPercent: used,
            autoUsedPercent: percent(plan["autoPercentUsed"] ?? plan["auto_percent_used"]),
            apiUsedPercent: percent(plan["apiPercentUsed"] ?? plan["api_percent_used"]),
            resetsAt: date(from: object["billingCycleEnd"] ?? object["billing_cycle_end"]),
            displayMessage: nonEmpty(object["displayMessage"] as? String ?? object["display_message"] as? String)
        )
    }

    /// Cursor stores spend in cents. The settings page shows included spend over the plan limit.
    static func usedPercent(in plan: [String: Any]) -> Double? {
        let included = number(plan["includedSpend"] ?? plan["included_spend"])
        let limit = number(plan["limit"])
        if let included, let limit, limit > 0 {
            return min(max(included / limit * 100, 0), 100)
        }
        return percent(plan["totalPercentUsed"] ?? plan["total_percent_used"])
    }

    /// `totalPercentUsed` is already on a 0–100 scale; Cursor only falls back to it when `limit` is 0.
    private static func percent(_ value: Any?) -> Double? {
        guard let value = number(value), value.isFinite, value >= 0 else { return nil }
        return min(value, 100)
    }

    private static func date(from value: Any?) -> Date? {
        let raw: Double?
        if let number = number(value) {
            raw = number
        } else if let text = value as? String {
            raw = Double(text)
        } else {
            raw = nil
        }
        guard let raw, raw > 0, raw.isFinite else { return nil }
        if raw > 10_000_000_000 { return Date(timeIntervalSince1970: raw / 1000) }
        return Date(timeIntervalSince1970: raw)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
