import Foundation

public struct CodexQuotaWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let minutes: Int
    public let resetsAt: Date?

    public var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0), 100)
    }
}

public struct CodexQuotaSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let windows: [CodexQuotaWindow]

    public func lowestRemainingWindow() -> CodexQuotaWindow? {
        windows.min { lhs, rhs in
            if lhs.remainingPercent != rhs.remainingPercent {
                return lhs.remainingPercent < rhs.remainingPercent
            }
            return lhs.minutes < rhs.minutes
        }
    }
}

/// Reads only existing local Codex rollout records. No credentials or network access.
public enum CodexQuotaLoader {
    private static let maximumFileCount = 40
    private static let maximumTailBytes: UInt64 = 1_048_576

    public static func load(root: URL) throws -> CodexQuotaSnapshot? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return nil }
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.1 > $1.1 }
        var latest: CodexQuotaSnapshot?
        var lastReadError: Error?
        for (url, _) in candidates.prefix(maximumFileCount) {
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let size = try file.seekToEnd()
                let start = size > maximumTailBytes ? size - maximumTailBytes : 0
                try file.seek(toOffset: start)
                let data = try file.readToEnd() ?? Data()
                var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                if start > 0 && !lines.isEmpty { lines.removeFirst() }
                for line in lines.reversed() {
                    guard let snapshot = parse(line), snapshot.capturedAt <= Date().addingTimeInterval(60) else { continue }
                    if let current = latest, current.capturedAt >= snapshot.capturedAt { break }
                    latest = snapshot
                    break
                }
            } catch {
                lastReadError = error
            }
        }
        if latest == nil, let lastReadError { throw lastReadError }
        return latest
    }

    public static func parse(_ line: String) -> CodexQuotaSnapshot? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let timestamp = object["timestamp"] as? String,
              let capturedAt = ClaudeUsageScanner.parseISO8601(timestamp),
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        if let limitID = limits["limit_id"] as? String, !limitID.isEmpty, limitID != "codex" { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> CodexQuotaWindow? in
            guard let window = limits[key] as? [String: Any],
                  let percent = window["used_percent"] as? Double, percent.isFinite, (0...100).contains(percent),
                  let minutes = window["window_minutes"] as? Int, minutes > 0 else { return nil }
            let resetsAt = (window["resets_at"] as? Double).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return CodexQuotaWindow(usedPercent: percent, minutes: minutes, resetsAt: resetsAt)
        }
        guard !windows.isEmpty else { return nil }
        return CodexQuotaSnapshot(capturedAt: capturedAt, windows: windows)
    }
}
