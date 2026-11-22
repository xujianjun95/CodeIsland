import Foundation

public struct AntigravityQuotaWindow: Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0), 100)
    }

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct AntigravityQuotaGroup: Equatable, Sendable {
    public let name: String
    public let description: String?
    public let windows: [AntigravityQuotaWindow]

    public var shortName: String {
        let lowered = name.lowercased()
        if lowered.contains("argon") { return "Argon" }
        if lowered.contains("claude") || lowered.contains("gpt") { return "Claude/GPT" }
        if lowered.contains("gemini") { return "Gemini" }
        return name
    }

    public func lowestRemainingWindow() -> AntigravityQuotaWindow? {
        windows.min { lhs, rhs in
            if lhs.remainingPercent != rhs.remainingPercent {
                return lhs.remainingPercent < rhs.remainingPercent
            }
            return false
        }
    }

    public init(name: String, description: String? = nil, windows: [AntigravityQuotaWindow]) {
        self.name = name
        self.description = description
        self.windows = windows
    }
}

public struct AntigravityQuotaSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let planName: String?
    public let primaryGroup: AntigravityQuotaGroup
    public let groups: [AntigravityQuotaGroup]

    public init(
        capturedAt: Date,
        planName: String?,
        primaryGroup: AntigravityQuotaGroup,
        groups: [AntigravityQuotaGroup]
    ) {
        self.capturedAt = capturedAt
        self.planName = planName
        self.primaryGroup = primaryGroup
        self.groups = groups
    }

    public func group(forModel model: String?) -> AntigravityQuotaGroup {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.lowercased() != "auto" else {
            return primaryGroup
        }
        let normalizedModel = Self.normalizeToken(model)
        guard !normalizedModel.isEmpty else { return primaryGroup }

        if normalizedModel.contains("argon"),
           let argon = groups.first(where: { $0.name.lowercased().contains("argon") }) {
            return argon
        }

        for group in groups {
            guard let description = group.description else { continue }
            if Self.normalizeToken(description).contains(normalizedModel) {
                return group
            }
        }

        let thirdPartyTokens = ["claude", "opus", "sonnet", "haiku", "gpt", "o1", "o3", "o4"]
        if thirdPartyTokens.contains(where: { normalizedModel.contains($0) }),
           let thirdParty = groups.first(where: {
               let lowered = $0.name.lowercased()
               return lowered.contains("claude") || lowered.contains("gpt")
           }) {
            return thirdParty
        }

        let geminiTokens = ["gemini", "neon", "hydrogen", "flash", "orchestrator"]
        if geminiTokens.contains(where: { normalizedModel.contains($0) }),
           let gemini = groups.first(where: {
               let lowered = $0.name.lowercased()
               return lowered.contains("gemini") && !lowered.contains("argon")
           }) {
            return gemini
        }

        return primaryGroup
    }

    private static func normalizeToken(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public enum AntigravityQuotaFetch: Equatable, Sendable {
    case snapshot(AntigravityQuotaSnapshot)
    case notRunning
    case failed
}

/// Reads quota windows from the local Google Antigravity language server over loopback Connect-RPC.
/// Only talks to `127.0.0.1` using the running language server's CSRF token; never refreshes or logs credentials.
public enum AntigravityQuotaLoader {
    public struct ServerProcess: Equatable, Sendable {
        public let pid: Int32
        public let csrfToken: String
        public let extensionServerPort: Int?

        public init(pid: Int32, csrfToken: String, extensionServerPort: Int?) {
            self.pid = pid
            self.csrfToken = csrfToken
            self.extensionServerPort = extensionServerPort
        }
    }

    private static let summaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    public static func load(agyExecutable: String? = nil) async -> AntigravityQuotaFetch {
        if let executable = agyExecutable ?? findAGYExecutable() {
            if let output = runCommand(executable, arguments: ["-p", "/usage", "--output-format", "json"]),
               let snapshot = parseCLIUsage(Data(output.utf8)) {
                return .snapshot(snapshot)
            }
            // Fall through to legacy local language_server probe in case CLI failed while older IDE is running.
            let legacy = await loadFromLocalLanguageServer()
            if case .snapshot = legacy {
                return legacy
            }
            return .failed
        }
        return await loadFromLocalLanguageServer()
    }

    public static func findAGYExecutable(
        homeDirectory: String = NSHomeDirectory(),
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = [
            (homeDirectory as NSString).appendingPathComponent(".local/bin/agy"),
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        if let environmentPath {
            for dir in environmentPath.split(separator: ":").map(String.init) where !dir.isEmpty {
                let candidate = (dir as NSString).appendingPathComponent("agy")
                if !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.first(where: isExecutable)
    }

    private static func loadFromLocalLanguageServer() async -> AntigravityQuotaFetch {
        guard let psOutput = runCommand("/bin/ps", arguments: ["-ax", "-o", "pid=,command="]) else {
            return .failed
        }
        let processes = parseProcesses(psOutput)
        guard !processes.isEmpty else { return .notRunning }

        let delegate = LoopbackTrustDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        for process in processes {
            let lsofOutput = runCommand(
                "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(process.pid)]
            ) ?? ""
            let ports = orderedCandidatePorts(
                listening: parseListeningPorts(lsofOutput),
                extensionServerPort: process.extensionServerPort
            )
            for port in ports {
                if let snapshot = await probe(port: port, csrfToken: process.csrfToken, session: session) {
                    return .snapshot(snapshot)
                }
            }
        }
        return .failed
    }

    /// Parses `agy -p "/usage" --output-format json` output.
    public static func parseCLIUsage(_ data: Data, capturedAt: Date = Date()) -> AntigravityQuotaSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let status = object["status"] as? String, status.uppercased() != "SUCCESS" {
            return nil
        }
        if let command = object["command"] as? [String: Any],
           let commandData = command["data"] as? [String: Any] {
            return parseGroupsContainer(commandData, capturedAt: capturedAt)
        }
        return parseGroupsContainer(object, capturedAt: capturedAt)
    }

    /// Parses `ps -ax -o pid=,command=` lines to locate running Antigravity language server instances.
    public static func parseProcesses(_ psOutput: String) -> [ServerProcess] {
        var found: [ServerProcess] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let firstSpace = line.firstIndex(where: \.isWhitespace) else { continue }
            let pidString = String(line[..<firstSpace])
            guard let pid = Int32(pidString) else { continue }
            let command = String(line[firstSpace...]).trimmingCharacters(in: .whitespaces)
            let lowered = command.lowercased()
            guard lowered.contains("language_server"), lowered.contains("antigravity") else { continue }
            guard let csrfToken = extractFlag("--csrf_token", from: command), !csrfToken.isEmpty else { continue }
            let extPort = extractFlag("--extension_server_port", from: command).flatMap(Int.init)
            found.append(ServerProcess(pid: pid, csrfToken: csrfToken, extensionServerPort: extPort))
        }
        return found
    }

    /// Parses `lsof -nP -iTCP -sTCP:LISTEN` output for local listening TCP ports.
    public static func parseListeningPorts(_ lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        var seen = Set<Int>()
        for rawLine in lsofOutput.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.contains("(LISTEN)") else { continue }
            // Match `127.0.0.1:12345`, `*:12345`, `[::1]:12345`, or `localhost:12345`
            let tokens = line.split(whereSeparator: \.isWhitespace)
            for token in tokens {
                let text = String(token)
                guard text.contains(":"),
                      text.hasPrefix("127.0.0.1:") || text.hasPrefix("*:") || text.hasPrefix("[::1]:") || text.hasPrefix("localhost:") else {
                    continue
                }
                guard let colon = text.lastIndex(of: ":") else { continue }
                let portText = String(text[text.index(after: colon)...])
                if let port = Int(portText), port > 0, port <= 65535, seen.insert(port).inserted {
                    ports.append(port)
                }
            }
        }
        return ports
    }

    /// Prefer non-extension ports first (Connect-RPC typically binds its own port), keeping extension port as fallback.
    public static func orderedCandidatePorts(listening: [Int], extensionServerPort: Int?) -> [Int] {
        var primary: [Int] = []
        var fallback: [Int] = []
        for port in listening {
            if port == extensionServerPort {
                fallback.append(port)
            } else {
                primary.append(port)
            }
        }
        if let ext = extensionServerPort, !listening.contains(ext), ext > 0, ext <= 65535 {
            fallback.append(ext)
        }
        return primary + fallback
    }

    /// Parses `RetrieveUserQuotaSummary` JSON responses.
    public static func parseQuotaSummary(_ data: Data, capturedAt: Date = Date()) -> AntigravityQuotaSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parseGroupsContainer(object, capturedAt: capturedAt)
    }

    private static func parseGroupsContainer(_ object: [String: Any], capturedAt: Date) -> AntigravityQuotaSnapshot? {
        guard let rawGroups = object["groups"] as? [[String: Any]], !rawGroups.isEmpty else { return nil }

        var groups: [AntigravityQuotaGroup] = []
        for rawGroup in rawGroups {
            let name = nonEmpty(rawGroup["displayName"] as? String ?? rawGroup["display_name"] as? String ?? rawGroup["name"] as? String) ?? "Antigravity"
            let description = nonEmpty(rawGroup["description"] as? String)
            let rawBuckets = (rawGroup["buckets"] as? [[String: Any]]) ?? []
            var windows: [AntigravityQuotaWindow] = []
            for bucket in rawBuckets {
                guard let used = usedPercent(from: bucket) else { continue }
                let id = nonEmpty(bucket["bucketId"] as? String ?? bucket["bucket_id"] as? String ?? bucket["id"] as? String)
                    ?? nonEmpty(bucket["window"] as? String)
                    ?? UUID().uuidString
                let windowLabel = nonEmpty(bucket["window"] as? String) ?? inferWindowLabel(from: id)
                let reset = parseResetDate(bucket["resetTime"] ?? bucket["reset_time"])
                windows.append(AntigravityQuotaWindow(id: id, label: windowLabel, usedPercent: used, resetsAt: reset))
            }
            guard !windows.isEmpty else { continue }
            windows.sort(by: windowSortOrder)
            groups.append(AntigravityQuotaGroup(name: name, description: description, windows: windows))
        }

        guard let primary = selectPrimaryGroup(from: groups) else { return nil }
        let planName = nonEmpty(object["planName"] as? String ?? object["plan_name"] as? String)
        return AntigravityQuotaSnapshot(
            capturedAt: capturedAt,
            planName: planName,
            primaryGroup: primary,
            groups: groups
        )
    }

    /// Parses `GetUserStatus` or `GetCommandModelConfigs` JSON responses as a fallback.
    public static func parseUserStatus(_ data: Data, capturedAt: Date = Date()) -> AntigravityQuotaSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let userStatus = object["userStatus"] as? [String: Any]
        let planInfo = (userStatus?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let planName = nonEmpty(planInfo?["planDisplayName"] as? String)
            ?? nonEmpty(planInfo?["planName"] as? String)

        let modelConfigs: [[String: Any]]?
        if let cascade = userStatus?["cascadeModelConfigData"] as? [String: Any],
           let configs = cascade["clientModelConfigs"] as? [[String: Any]] {
            modelConfigs = configs
        } else if let configs = object["clientModelConfigs"] as? [[String: Any]] {
            modelConfigs = configs
        } else {
            modelConfigs = nil
        }
        guard let modelConfigs, !modelConfigs.isEmpty else { return nil }

        var byGroup: [String: [AntigravityQuotaWindow]] = [:]
        var groupOrder: [String] = []
        var seenWindowKey = Set<String>()

        for config in modelConfigs {
            guard let quotaInfo = config["quotaInfo"] as? [String: Any] else { continue }
            let remaining = number(quotaInfo["remainingFraction"] ?? quotaInfo["remaining_fraction"])
            let reset = parseResetDate(quotaInfo["resetTime"] ?? quotaInfo["reset_time"])
            let used: Double
            if let remaining, remaining.isFinite {
                used = clampPercent((1.0 - remaining) * 100.0)
            } else if reset != nil {
                // Antigravity omits remainingFraction when a bucket is completely exhausted.
                used = 100.0
            } else {
                continue
            }

            let label = nonEmpty(config["label"] as? String)
                ?? nonEmpty((config["modelOrAlias"] as? [String: Any])?["model"] as? String)
                ?? "Model"
            let modelId = nonEmpty((config["modelOrAlias"] as? [String: Any])?["model"] as? String) ?? label
            let groupName = classifyModelGroup(label: label, modelId: modelId)
            let dedupeKey = "\(groupName)|\(label)"
            guard seenWindowKey.insert(dedupeKey).inserted else { continue }

            if byGroup[groupName] == nil {
                groupOrder.append(groupName)
            }
            byGroup[groupName, default: []].append(
                AntigravityQuotaWindow(id: modelId, label: label, usedPercent: used, resetsAt: reset)
            )
        }

        var groups: [AntigravityQuotaGroup] = []
        for groupName in groupOrder {
            guard let models = byGroup[groupName], !models.isEmpty else { continue }
            // Keep models ordered from highest usage to lowest so the most constrained quota surfaces first.
            let sorted = models.sorted { lhs, rhs in
                if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent > rhs.usedPercent }
                return lhs.label < rhs.label
            }
            groups.append(AntigravityQuotaGroup(name: groupName, windows: sorted))
        }

        guard let primary = selectPrimaryGroup(from: groups) else { return nil }
        // Collapse the primary group to a single representative window when using model-level fallback,
        // while preserving every model in `groups` for the hover tooltip.
        let representative = primary.windows[0]
        let primarySummary = AntigravityQuotaGroup(
            name: primary.name,
            windows: [
                AntigravityQuotaWindow(
                    id: representative.id,
                    label: "cycle",
                    usedPercent: representative.usedPercent,
                    resetsAt: representative.resetsAt
                )
            ]
        )
        return AntigravityQuotaSnapshot(
            capturedAt: capturedAt,
            planName: planName,
            primaryGroup: primarySummary,
            groups: groups
        )
    }

    // MARK: - Private helpers

    private static func probe(port: Int, csrfToken: String, session: URLSession) async -> AntigravityQuotaSnapshot? {
        for scheme in ["https", "http"] {
            if let data = await post(scheme: scheme, port: port, path: summaryPath, body: "{}", csrfToken: csrfToken, session: session),
               let snapshot = parseQuotaSummary(data) {
                return snapshot
            }
            let metadataBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#
            if let data = await post(scheme: scheme, port: port, path: userStatusPath, body: metadataBody, csrfToken: csrfToken, session: session),
               let snapshot = parseUserStatus(data) {
                return snapshot
            }
            if let data = await post(scheme: scheme, port: port, path: commandModelsPath, body: metadataBody, csrfToken: csrfToken, session: session),
               let snapshot = parseUserStatus(data) {
                return snapshot
            }
        }
        return nil
    }

    private static func post(
        scheme: String,
        port: Int,
        path: String,
        body: String,
        csrfToken: String,
        session: URLSession
    ) async -> Data? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func runCommand(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for index in tokens.indices {
            let token = tokens[index]
            if token == flag, index + 1 < tokens.count {
                return stripQuotes(tokens[index + 1])
            }
            let prefix = "\(flag)="
            if token.hasPrefix(prefix) {
                return stripQuotes(String(token.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func stripQuotes(_ value: String) -> String {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func usedPercent(from bucket: [String: Any]) -> Double? {
        if let remaining = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"]), remaining.isFinite {
            return clampPercent((1.0 - remaining) * 100.0)
        }
        if let usedFraction = number(bucket["usedFraction"] ?? bucket["used_fraction"]), usedFraction.isFinite {
            return clampPercent(usedFraction * 100.0)
        }
        if let usedPct = number(bucket["usedPercent"] ?? bucket["used_percent"]), usedPct.isFinite {
            return clampPercent(usedPct)
        }
        if bucket["resetTime"] != nil || bucket["reset_time"] != nil {
            return 100.0
        }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func inferWindowLabel(from id: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("week") { return "weekly" }
        if lowered.contains("5h") { return "5h" }
        return "cycle"
    }

    private static func windowSortOrder(_ lhs: AntigravityQuotaWindow, _ rhs: AntigravityQuotaWindow) -> Bool {
        windowRank(lhs.label) < windowRank(rhs.label)
    }

    private static func windowRank(_ label: String) -> Int {
        let lowered = label.lowercased()
        if lowered.contains("5h") || lowered.contains("hour") { return 0 }
        if lowered.contains("day") || lowered.contains("24h") { return 1 }
        if lowered.contains("week") { return 2 }
        return 3
    }

    private static func selectPrimaryGroup(from groups: [AntigravityQuotaGroup]) -> AntigravityQuotaGroup? {
        if let gemini = groups.first(where: { $0.name.lowercased().contains("gemini") }) {
            return gemini
        }
        return groups.first
    }

    private static func classifyModelGroup(label: String, modelId: String) -> String {
        let combined = "\(label) \(modelId)".lowercased()
        if combined.contains("gemini") { return "Gemini Models" }
        if combined.contains("claude") || combined.contains("gpt") || combined.contains("o1") || combined.contains("o3") {
            return "Claude and GPT models"
        }
        return "Antigravity Models"
    }

    private static func parseResetDate(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let iso = ClaudeUsageScanner.parseISO8601(text) { return iso }
            if let seconds = Double(text), seconds > 0, seconds.isFinite {
                return seconds > 10_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1000)
                    : Date(timeIntervalSince1970: seconds)
            }
            return nil
        }
        if let seconds = number(value), seconds > 0, seconds.isFinite {
            return seconds > 10_000_000_000
                ? Date(timeIntervalSince1970: seconds / 1000)
                : Date(timeIntervalSince1970: seconds)
        }
        return nil
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

/// Accepts self-signed certificates strictly for loopback (`127.0.0.1` / `localhost`) connections.
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (host == "127.0.0.1" || host == "localhost"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
