import Foundation

public enum QuotaAgent: Equatable, Sendable {
    case claude, codex, grok, cursor, antigravity
}

public enum QuotaAgentSelection {
    /// Prefer the selected running session, then the most recently active running
    /// session. When none is running, retain the selected session if present.
    public static func resolveSession(sessions: [String: SessionSnapshot], activeID: String?) -> SessionSnapshot? {
        func running(_ session: SessionSnapshot) -> Bool {
            session.status == .running || session.status == .processing
        }
        let active = activeID.flatMap { sessions[$0] }
        let runningSessions = sessions.filter { running($0.value) }
        if let active, running(active) {
            return active
        }
        if !runningSessions.isEmpty {
            return runningSessions.sorted {
                if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
                return $0.value.lastActivity > $1.value.lastActivity
            }.first?.value
        }
        return active ?? sessions.sorted {
            if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
            return $0.value.lastActivity > $1.value.lastActivity
        }.first?.value
    }

    public static func resolveMostRecentSession(sessions: [String: SessionSnapshot], activeID: String?) -> SessionSnapshot? {
        func running(_ session: SessionSnapshot) -> Bool {
            session.status == .running || session.status == .processing
        }
        let active = activeID.flatMap { sessions[$0] }
        let runningSessions = sessions.filter { running($0.value) }
        if let active, running(active) {
            return active
        }
        if !runningSessions.isEmpty {
            return runningSessions.sorted {
                if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
                return $0.value.lastActivity > $1.value.lastActivity
            }.first?.value
        }
        return sessions.sorted {
            if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
            return $0.value.lastActivity > $1.value.lastActivity
        }.first?.value
    }

    public static func agent(for session: SessionSnapshot?) -> QuotaAgent? {
        switch SessionSnapshot.normalizedSupportedSource(session?.source) {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        case "cursor", "cursor-cli": return .cursor
        case "google-antigravity": return .antigravity
        default: return nil
        }
    }

    public static func resolve(sessions: [String: SessionSnapshot], activeID: String?) -> QuotaAgent? {
        agent(for: resolveSession(sessions: sessions, activeID: activeID))
    }
}
