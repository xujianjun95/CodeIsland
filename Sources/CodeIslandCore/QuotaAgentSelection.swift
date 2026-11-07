import Foundation

public enum QuotaAgent: Equatable, Sendable {
    case claude, codex, grok
}

public enum QuotaAgentSelection {
    /// Prefer the selected running session, then the most recently active running
    /// session. When none is running, retain the selected session if present.
    public static func resolve(sessions: [String: SessionSnapshot], activeID: String?) -> QuotaAgent? {
        func running(_ session: SessionSnapshot) -> Bool {
            session.status == .running || session.status == .processing
        }
        let active = activeID.flatMap { sessions[$0] }
        let runningSessions = sessions.filter { running($0.value) }
        let selected: SessionSnapshot?
        if let active, running(active) {
            selected = active
        } else if !runningSessions.isEmpty {
            selected = runningSessions.sorted {
                if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
                return $0.value.lastActivity > $1.value.lastActivity
            }.first?.value
        } else {
            selected = active ?? sessions.sorted {
                if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
                return $0.value.lastActivity > $1.value.lastActivity
            }.first?.value
        }
        switch SessionSnapshot.normalizedSupportedSource(selected?.source) {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        default: return nil
        }
    }
}
