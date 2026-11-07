import Foundation

public struct GrokQuotaProduct: Equatable, Sendable {
    public let name: String
    public let usedPercent: Double
}

public struct GrokQuotaSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let usedPercent: Double
    public let periodMinutes: Int
    public let resetsAt: Date?
    public let products: [GrokQuotaProduct]
}

public enum GrokQuotaFetch: Equatable, Sendable {
    case snapshot(GrokQuotaSnapshot)
    case needsLogin
    case failed
}

/// Reads the plan credit window Grok's own `/usage` shows.
/// Uses the existing CLI login. The token is only read, never refreshed or logged.
public enum GrokQuotaLoader {
    public static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    public static func load(authURL: URL) async -> GrokQuotaFetch {
        let auth: Data
        do {
            auth = try Data(contentsOf: authURL)
        } catch {
            return .needsLogin
        }
        guard let token = token(in: auth) else { return .needsLogin }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.77", forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 { return .needsLogin }
                guard (200...299).contains(http.statusCode) else { return .failed }
            }
            guard let snapshot = parse(data) else { return .failed }
            return .snapshot(snapshot)
        } catch {
            return .failed
        }
    }

    /// The CLI login lives under an account id. Prefer a key that has not expired.
    public static func token(in authJSON: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: authJSON)) as? [String: Any] else { return nil }
        var candidates: [(String, Date?)] = []
        func walk(_ value: Any) {
            guard let record = value as? [String: Any] else { return }
            if let key = record["key"] as? String {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let expires = (record["expires_at"] as? String).flatMap(ClaudeUsageScanner.parseISO8601)
                    candidates.append((trimmed, expires))
                }
            }
            for nested in record.values { walk(nested) }
        }
        walk(object)
        let now = Date()
        if let fresh = candidates.filter({ ($0.1 ?? .distantFuture) > now }).sorted(by: { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }).first {
            return fresh.0
        }
        return candidates.sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }.first?.0
    }

    public static func parse(_ data: Data, capturedAt: Date = Date()) -> GrokQuotaSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let config = (object["config"] as? [String: Any]) ?? object
        guard let percent = Self.number(config["creditUsagePercent"]), percent.isFinite, percent >= 0 else { return nil }
        let period = config["currentPeriod"] as? [String: Any]
        let start = (period?["start"] as? String).flatMap(ClaudeUsageScanner.parseISO8601)
        let end = (period?["end"] as? String).flatMap(ClaudeUsageScanner.parseISO8601)
            ?? (config["billingPeriodEnd"] as? String).flatMap(ClaudeUsageScanner.parseISO8601)
        let minutes: Int
        if let start, let end, end > start {
            minutes = max(Int((end.timeIntervalSince(start) / 60).rounded()), 1)
        } else if (period?["type"] as? String)?.contains("MONTH") == true {
            minutes = 30 * 1440
        } else {
            minutes = 7 * 1440
        }
        let products = (config["productUsage"] as? [[String: Any]] ?? []).compactMap { item -> GrokQuotaProduct? in
            guard let name = item["product"] as? String, !name.isEmpty,
                  let used = Self.number(item["usagePercent"]), used.isFinite, used >= 0 else { return nil }
            return GrokQuotaProduct(name: name, usedPercent: used)
        }
        return GrokQuotaSnapshot(
            capturedAt: capturedAt,
            usedPercent: percent,
            periodMinutes: minutes,
            resetsAt: end,
            products: products
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
