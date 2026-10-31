import Foundation
import CFNetwork
import CryptoKit
import Darwin

/// Incremental log events and process-wide app state have separate attribution lifetimes.
actor CodexHealthMonitor {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64
        var partial = Data()
        var discardUntilNewline = false
    }
    private let directory: URL
    private let sessionDirectory: URL?
    private let startedAt: Date
    private var runtimeReader: CodexRuntimeHealthReader?
    private(set) var interfaceSnapshot = CodexInterfaceHealthSnapshot()
    private(set) var interfaceObservation = CodexInterfaceObservation()
    private var bootstrapSince: Date
    private var observationNeedsBootstrap = true
    private var cursors: [String: Cursor] = [:]
    private var sessionSources: [String: (inode: UInt64, size: UInt64, desktop: Bool?, threadID: String?)] = [:]
    private var lastSessionEvents: [String: CodexHealthEvent] = [:]
    private var initialized = false
    private var nextFileIndex = 0
    private var nextSessionFileIndex = 0
    private var futureEvents: [CodexHealthEvent] = []
    private(set) var status = "等待 Codex 日志"
    private(set) var applicationObservation = CodexApplicationObservation()
    private let inviteCacheDirectory: URL?
    private var inviteCacheFiles: [URL] = []
    private var inviteCacheScannedAt: Date?
    private var inviteCacheModifiedAt: Date?
    private var lastInviteCacheSuccess: Date?

    init(directory: URL? = nil, startedAt: Date = Date(), bootstrapSince: Date? = nil,
         sessionDirectory: URL? = nil, runtimeDatabaseURL: URL? = nil, inviteCacheDirectory: URL? = nil) {
        self.inviteCacheDirectory = inviteCacheDirectory ?? (directory == nil
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Codex/Default/Cache/Cache_Data") : nil)
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex")
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.sessionDirectory = sessionDirectory ?? (directory == nil ? home.appendingPathComponent("sessions") : nil)
        self.startedAt = startedAt
        self.runtimeReader = directory == nil || runtimeDatabaseURL != nil
            ? CodexRuntimeHealthReader(databaseURL: runtimeDatabaseURL, startedAt: startedAt) : nil
        self.bootstrapSince = bootstrapSince ?? startedAt.addingTimeInterval(-24 * 60 * 60)
    }

    /// A new Codex process must not inherit unresolved state from a previous process.
    func resetApplicationObservation(since: Date) {
        bootstrapSince = since
        runtimeReader?.reset(since: since)
        applicationObservation = CodexApplicationObservation()
        interfaceObservation = CodexInterfaceObservation()
        interfaceSnapshot = CodexInterfaceHealthSnapshot()
        observationNeedsBootstrap = true
        futureEvents.removeAll()
        lastSessionEvents.removeAll()
        inviteCacheModifiedAt = nil
        lastInviteCacheSuccess = nil
    }

    /// Codex logs only failed eligibility loads; a fresh HTTP 200 in its own network cache is the success signal.
    private func inviteCacheSuccess(now: Date) -> CodexHealthEvent? {
        guard let root = inviteCacheDirectory else { return nil }
        let manager = FileManager.default
        if inviteCacheFiles.isEmpty || !inviteCacheFiles.allSatisfy({ manager.fileExists(atPath: $0.path) }),
           inviteCacheScannedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            inviteCacheScannedAt = now
            inviteCacheFiles = CodexInviteCache.locate(in: root)
        }
        let modified = inviteCacheFiles.compactMap {
            (try? manager.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }.max()
        guard let modified, modified != inviteCacheModifiedAt else { return nil }
        inviteCacheModifiedAt = modified
        guard let success = inviteCacheFiles.compactMap(CodexInviteCache.successDate(in:)).max(),
              success > (lastInviteCacheSuccess ?? .distantPast) else { return nil }
        lastInviteCacheSuccess = success
        return CodexHealthEvent(date: min(success, now), kind: .workspaceRecovered,
                                observationID: CodexInviteCache.observationID, recoveryOrigin: .request,
                                workspaceFeature: .inviteEligibility)
    }

    func observeInviteCheck(_ event: CodexHealthEvent) {
        guard event.workspaceFeature == .inviteEligibility else { return }
        applicationObservation.observe(event)
    }

    func poll(now: Date = Date(), codexPID: pid_t? = nil) -> [CodexHealthEvent] {
        interfaceSnapshot = codexPID.map { CodexInterfaceHealthReader.snapshot(pid: $0) } ?? CodexInterfaceHealthSnapshot()
        let interfaceEvents = interfaceObservation.observe(interfaceSnapshot, at: now)

        let manager = FileManager.default
        var files: [(URL, UInt64, UInt64, Date)] = []
        var sessions: [(URL, UInt64, UInt64, Date)] = []
        var sessionPaths = Set<String>()
        for root in [directory, sessionDirectory].compactMap({ $0 }) {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == (root == directory ? "log" : "jsonl") {
                guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? NSNumber,
                      let inode = attributes[.systemFileNumber] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) <= 2 * 24 * 60 * 60 else { continue }
                if url.pathExtension == "jsonl" {
                    sessionPaths.insert(url.path)
                    sessions.append((url, size.uint64Value, inode.uint64Value, modified))
                } else {
                    files.append((url, size.uint64Value, inode.uint64Value, modified))
                }
            }
        }
        sessions.sort { $0.0.path < $1.0.path }
        let sessionStart = sessions.isEmpty ? 0 : nextSessionFileIndex % sessions.count
        var headerBudget = 32
        for step in 0..<sessions.count {
            let index = (sessionStart + step) % sessions.count
            let (url, size, inode, _) = sessions[index]
            let cached = sessionSources[url.path]
            if cached?.inode != inode || size < (cursors[url.path]?.offset ?? 0)
                || (cached?.desktop == nil && cached?.size != size) {
                guard headerBudget > 0 else { continue }
                headerBudget -= 1
                let metadata = desktopSessionMetadata(url)
                sessionSources[url.path] = (inode, size, metadata.desktop, metadata.threadID)
                nextSessionFileIndex = index + 1
            }
            if sessionSources[url.path]?.desktop == true { files.append(sessions[index]) }
        }
        if observationNeedsBootstrap {
            restoreApplicationObservation(from: files.sorted { $0.3 > $1.3 }, now: now)
            observationNeedsBootstrap = false
        }
        let desktopThreadIDs = Set(sessionSources.values.compactMap(\.threadID))
        var runtimeEvents = (runtimeReader?.poll(now: now, desktopThreadIDs: desktopThreadIDs) ?? []) + interfaceEvents
            + [inviteCacheSuccess(now: now)].compactMap { $0 }
        // Baseline every existing file at EOF: restored state is never replayed as new node evidence.
        if !initialized {
            for (url, size, inode, _) in files { cursors[url.path] = Cursor(inode: inode, offset: size, discardUntilNewline: endsWithPartialLine(url: url, size: size)) }
            initialized = true
            status = files.isEmpty ? "未发现近期 Codex 日志" : "已监听 \(files.count) 个 Codex 日志；历史仅恢复应用状态，不计作新事件"
            for event in runtimeEvents where event.date >= bootstrapSince { applicationObservation.observe(event) }
            if let recovery = confirmWorkspaceInterfaceRecovery(now: now) { runtimeEvents.append(recovery) }
            return runtimeEvents
        }
        var events = runtimeEvents + futureEvents.filter { $0.date <= now }
        futureEvents.removeAll { $0.date <= now }
        var unreadable = 0
        var readFiles = 0
        var budget = 2 * 1024 * 1024
        // Stable round-robin scanning prevents eight busy files from starving another active renderer.
        files.sort { $0.0.path < $1.0.path }
        let startIndex = files.isEmpty ? 0 : nextFileIndex % files.count
        var visited = 0
        for step in 0..<files.count {
            let index = (startIndex + step) % files.count
            let (url, size, inode, modified) = files[index]
            visited += 1
            let baselineOffset = modified < startedAt ? size : 0
            var cursor = cursors[url.path] ?? Cursor(inode: inode, offset: baselineOffset, discardUntilNewline: baselineOffset > 0 && endsWithPartialLine(url: url, size: size))
            if cursor.inode != inode || size < cursor.offset { cursor = Cursor(inode: inode, offset: 0) }
            guard size > cursor.offset else { cursors[url.path] = cursor; continue }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: cursor.offset)
                let data = try handle.read(upToCount: min(budget, 256 * 1024, Int(size - cursor.offset))) ?? Data()
                budget -= data.count
                readFiles += 1
                cursor.offset += UInt64(data.count)
                cursor.partial.append(data)
                if cursor.discardUntilNewline {
                    if let newline = cursor.partial.firstIndex(of: 0x0a) {
                        cursor.partial.removeSubrange(...newline)
                        cursor.discardUntilNewline = false
                    } else {
                        cursor.partial.removeAll(keepingCapacity: false)
                    }
                }
                while let newline = cursor.partial.firstIndex(of: 0x0a) {
                    let line = cursor.partial.prefix(upTo: newline)
                    cursor.partial.removeSubrange(...newline)
                    guard line.count <= 64 * 1024 else { continue }
                    let event = url.pathExtension == "jsonl" ? CodexSessionHealthParser.parse(Data(line))
                        : String(data: line, encoding: .utf8).flatMap(CodexHealthLogParser.parse)
                    guard let event,
                          event.date >= startedAt, event.date <= now.addingTimeInterval(5) else { continue }
                    if url.pathExtension == "jsonl" {
                        guard lastSessionEvents[url.path] != event else { continue }
                        lastSessionEvents[url.path] = event
                    }
                    if event.date <= now { events.append(event) }
                    else if futureEvents.count < 128 { futureEvents.append(event) }
                }
                if cursor.partial.count > 64 * 1024 {
                    cursor.partial.removeAll(keepingCapacity: false)
                    cursor.discardUntilNewline = true
                }
                cursors[url.path] = cursor
            } catch { unreadable += 1 }
            if budget == 0 { break }
        }
        if !files.isEmpty { nextFileIndex = (startIndex + visited) % files.count }
        let paths = Set(files.map { $0.0.path })
        cursors = cursors.filter { paths.contains($0.key) }
        sessionSources = sessionSources.filter { sessionPaths.contains($0.key) }
        lastSessionEvents = lastSessionEvents.filter { paths.contains($0.key) }
        events.sort { $0.date < $1.date }
        for event in events where event.date >= bootstrapSince { applicationObservation.observe(event) }
        if let recovery = confirmWorkspaceInterfaceRecovery(now: now) { events.append(recovery) }
        let backlog = files.reduce(UInt64(0)) { total, file in
            total + (file.1 > (cursors[file.0.path]?.offset ?? file.1) ? file.1 - (cursors[file.0.path]?.offset ?? file.1) : 0)
        }
        status = unreadable > 0 ? "部分 Codex 日志无法读取（\(unreadable)）"
            : (files.isEmpty ? "未发现近期 Codex 日志"
               : "后台监听中；已接入对话重连状态，监听 \(files.count) 个日志与会话元数据文件，本轮读取 \(readFiles) 个；\(events.count) 条新分类事件"
                    + (backlog > 0 ? "；还有 \(backlog / 1024) KB 待处理" : ""))
        return events
    }

    private func confirmWorkspaceInterfaceRecovery(now: Date) -> CodexHealthEvent? {
        guard interfaceSnapshot.workspaceUnavailable == false,
              applicationObservation.pendingSettingsFailure != nil else { return nil }
        let event = CodexHealthEvent(date: now, kind: .workspaceRecovered, observationID: "interface-state",
                                    recoveryOrigin: .request, workspaceFeature: .settings)
        applicationObservation.observe(event)
        return event
    }

    private func restoreApplicationObservation(from files: [(URL, UInt64, UInt64, Date)], now: Date) {
        var events: [CodexHealthEvent] = []
        for (url, size, _, _) in files.filter({ $0.0.pathExtension == "log" }).prefix(32) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            do {
                let offset = size > 128 * 1024 ? size - 128 * 1024 : 0
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: 128 * 1024) else { continue }
                var lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
                if offset > 0, !lines.isEmpty { lines.removeFirst() }
                if data.last != 0x0a, !lines.isEmpty { lines.removeLast() }
                for line in lines where line.count <= 64 * 1024 {
                    guard let text = String(data: line, encoding: .utf8),
                          text.contains("app_server_connection.") || text.contains("sa_server_request_failed")
                            || text.contains("connection_ready") || text.contains("initialize_handshake_result")
                            || text.contains("Reasoning summary item completed") || text.contains("response.completed"),
                          let event = CodexHealthLogParser.parse(text), event.date >= bootstrapSince, event.date <= now else { continue }
                    events.append(event)
                }
            } catch { continue }
        }
        for event in events.sorted(by: { $0.date < $1.date }) { applicationObservation.observe(event) }
    }

    private func desktopSessionMetadata(_ url: URL) -> (desktop: Bool?, threadID: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let newline = data.firstIndex(of: 0x0a) else { return (nil, nil) }
        let line = Data(data[..<newline])
        return (CodexSessionHealthParser.isDesktopSession(line), CodexSessionHealthParser.desktopThreadID(line))
    }

    private func endsWithPartialLine(url: URL, size: UInt64) -> Bool {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: size - 1)
            return try handle.read(upToCount: 1) != Data([0x0a])
        } catch { return true }
    }
}

/// Decode structural metadata only; assistant text, tool arguments and account fields are never decoded.
enum CodexSessionHealthParser {
    private struct Envelope: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String?
            let id: String?
            let role: String?
            let phase: String?
            let source: String?
            let originator: String?
        }
    }

    static func isDesktopSession(_ line: Data) -> Bool {
        guard line.count <= 64 * 1024, let record = try? JSONDecoder().decode(Envelope.self, from: line) else { return false }
        return record.type == "session_meta" && record.payload.source == "vscode" && record.payload.originator == "Codex Desktop"
    }

    static func desktopThreadID(_ line: Data) -> String? {
        guard isDesktopSession(line), let record = try? JSONDecoder().decode(Envelope.self, from: line),
              let id = record.payload.id, UUID(uuidString: id) != nil else { return nil }
        return id
    }

    static func parse(_ line: Data) -> CodexHealthEvent? {
        guard line.count <= 64 * 1024,
              let record = try? JSONDecoder().decode(Envelope.self, from: line) else { return nil }
        if record.type == "event_msg", record.payload.type == "turn_aborted",
           let rawDate = record.timestamp, let date = CodexHealthLogParser.timestamp(rawDate) {
            return CodexHealthEvent(date: date, kind: .requestStopped, recoveryOrigin: .responseStream)
        }
        guard record.type == "response_item", record.payload.type == "message", record.payload.role == "assistant",
              [nil, "commentary", "final", "final_answer"].contains(record.payload.phase),
              let rawDate = record.timestamp, let date = CodexHealthLogParser.timestamp(rawDate) else { return nil }
        let kind: CodexHealthEvent.Kind = ["final", "final_answer"].contains(record.payload.phase) ? .responseCompleted : .responseProgress
        // Session activity proves a response arrived, not that it used the current public proxy route.
        return CodexHealthEvent(date: date, kind: kind, scope: "unknown", recoveryOrigin: .businessResponse)
    }
}

enum CodexHealthLogParser {
    static func parse(_ line: String) -> CodexHealthEvent? {
        guard line.utf8.count <= 64 * 1024,
              let dateToken = line.split(separator: " ", maxSplits: 1).first,
              let date = timestamp(String(dateToken)) else { return nil }
        guard let header = line.range(of: #"^\S+ (?:info|warning|error|debug|trace) \[[^\]]+\] "#, options: .regularExpression) else { return nil }
        let source = line[header].dropLast(2).split(separator: "[").last.map(String.init) ?? ""
        let payload = String(line[header.upperBound...])
        let parsed = fields(in: payload)
        let lower = parsed.message.trimmingCharacters(in: .whitespaces).lowercased()
        let host = parsed.values["hostId"] ?? parsed.values["hostKind"] ?? "unknown"
        let scope = publicEndpoint(in: parsed.values) ? "public" : (["local", "durable", "remote"].contains(host) ? host : "unknown")
        let requestKey = (parsed.values["requestId"] ?? parsed.values["responseId"]).map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let applicationRequest = source == "electron-message-handler"
            && lower == "sa_server_request_failed" && applicationAPIEndpoint(in: parsed.values)
        let workspaceFeature: CodexHealthEvent.WorkspaceFeature? = applicationRequest
            ? (inviteEligibilityEndpoint(in: parsed.values) ? .inviteEligibility
               : (workspaceSettingsEndpoint(in: parsed.values) ? .settings : nil)) : nil
        func event(_ kind: CodexHealthEvent.Kind, origin: CodexHealthEvent.RecoveryOrigin? = nil) -> CodexHealthEvent {
            CodexHealthEvent(date: date, kind: kind, scope: scope, observationID: requestKey, recoveryOrigin: origin,
                             workspaceFeature: workspaceFeature)
        }
        let code = parsed.values["errorCode"]?.lowercased() ?? ""
        let status = parsed.values["status"] ?? parsed.values["statusCode"] ?? parsed.values["httpStatus"]
        let requestOrigin: CodexHealthEvent.RecoveryOrigin? = source == "electron-message-handler"
            && lower == "sa_server_request_failed" && applicationAPIEndpoint(in: parsed.values) ? .request : nil
        let bridgeOrigin: CodexHealthEvent.RecoveryOrigin? = source == "AppServerConnection"
            && scope != "local" ? .appServerBridge : nil
        let requestFailure = ["sa_server_request_failed", "request_failed", "request failed"].contains(lower)
        if requestFailure || lower == "chatgpt_pubsub_connection_failed" {
            if status == "401" || status == "403" || code.contains("cloudflare_challenge") || parsed.values["errorMessage"]?.lowercased().contains("cloudflare_challenge") == true {
                return event(.authenticationFailure, origin: requestOrigin)
            }
            if status == "429" { return event(.rateLimited, origin: requestOrigin) }
            let networkCodes = ["err_connection_closed", "err_timed_out", "err_connection_timed_out", "err_connection_reset", "err_internet_disconnected", "err_name_not_resolved", "etimedout", "econnreset", "enotfound",
                                "err_network_changed", "err_address_unreachable", "err_ssl_protocol_error",
                                "err_cert_common_name_invalid", "err_cert_authority_invalid", "err_cert_date_invalid"]
            if networkCodes.contains(code) { return event(workspaceFeature == .settings ? .workspaceFailure : .requestFailure, origin: requestOrigin) }
            if let status, let number = Int(status), (500...599).contains(number) { return event(.serviceFailure, origin: requestOrigin) }
        }
        if ["couldn't load workspace settings", "could not load workspace settings", "workspace_settings_load_failed"].contains(lower) {
            return CodexHealthEvent(date: date, kind: .workspaceFailure, scope: scope,
                                    recoveryOrigin: source == "electron-message-handler" ? .request : nil,
                                    workspaceFeature: .settings)
        }
        if lower == "workspace_settings_load_succeeded" {
            return CodexHealthEvent(date: date, kind: .workspaceRecovered, scope: scope,
                                    recoveryOrigin: source == "electron-message-handler" ? .request : nil,
                                    workspaceFeature: .settings)
        }
        // Only canonical events count; state_changed repeats error payloads and is not a new failure.
        if lower == "app_server_connection.connection_failed_before_ready" {
            if let kind = bridgeServiceFailure(status: status, message: parsed.values["errorMessage"]) {
                return event(kind, origin: bridgeOrigin)
            }
            return event(.connectionFailure, origin: bridgeOrigin)
        }
        if lower == "app_server_connection.closed", parsed.values["code"] == "1006" { return event(.connectionFailure, origin: bridgeOrigin) }
        if lower == "app_server_connection.reconnect_started" { return event(.reconnecting, origin: bridgeOrigin) }
        if lower == "connection_ready" || (lower == "initialize_handshake_result" && parsed.values["outcome"] == "success") {
            return event(.connectionReady, origin: bridgeOrigin)
        }
        let responseOrigin: CodexHealthEvent.RecoveryOrigin? = source == "electron-message-handler" ? .businessResponse : nil
        if lower == "reasoning summary item completed" { return event(.responseProgress, origin: responseOrigin) }
        if lower == "response.completed" { return event(.responseCompleted, origin: responseOrigin) }
        return nil
    }

    fileprivate static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func fields(in payload: String) -> (message: String, values: [String: String]) {
        // Parse all fields together so a quoted error/summary cannot inject a nested url= or event.
        let pattern = #"(?:^|\s)([A-Za-z][A-Za-z0-9_-]*)=("(?:[^"\\]|\\.)*"|[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (payload, [:]) }
        let matches = regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload))
        var values: [String: String] = [:]
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: payload), let valueRange = Range(match.range(at: 2), in: payload) else { continue }
            let key = String(payload[keyRange])
            let value = String(payload[valueRange])
            if value.first == "\"" {
                guard let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) else { break }
                values[key] = decoded
            } else { values[key] = value }
        }
        let message = matches.first.flatMap { Range($0.range, in: payload) }.map { String(payload[..<$0.lowerBound]) } ?? payload
        return (message, values)
    }

    private static func publicEndpoint(in fields: [String: String]) -> Bool {
        for name in ["url", "requestURL", "endpoint", "websocketURL"] {
            guard let value = fields[name], let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(), ["https", "wss"].contains(scheme),
                  let host = url.host?.lowercased() else { continue }
            if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "openai.com" || host.hasSuffix(".openai.com") { return true }
        }
        return false
    }

    private static func applicationAPIEndpoint(in fields: [String: String]) -> Bool {
        if publicEndpoint(in: fields) { return true }
        guard let value = fields["url"] else { return false }
        return value.hasPrefix("/") && !value.hasPrefix("//")
    }

    private static func workspaceSettingsEndpoint(in fields: [String: String]) -> Bool {
        guard let value = fields["url"], let path = URLComponents(string: value)?.path else { return false }
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "backend-api" { parts.removeFirst() }
        // These requests drive Codex's workspace-settings banner; /settings/user is unrelated.
        return parts.count == 3 && parts[0] == "accounts" && !parts[1].isEmpty
            && ["settings", "workspace_policy"].contains(parts[2])
            || parts.count == 3 && parts[0] == "accounts" && parts[1] == "check"
    }

    private static func inviteEligibilityEndpoint(in fields: [String: String]) -> Bool {
        guard let value = fields["url"], let path = URLComponents(string: value)?.path else { return false }
        return path == "/referrals/invite/eligibility" || path == "/backend-api/referrals/invite/eligibility"
    }

    private static func bridgeServiceFailure(status: String?, message: String?) -> CodexHealthEvent.Kind? {
        var code = status.flatMap(Int.init)
        if code == nil, let message,
           let range = message.range(of: #"(?i)unexpected server response: (?:401|403|429|5\d\d)\b"#, options: .regularExpression) {
            code = Int(message[range].split(separator: " ").last ?? "")
        }
        if code == 401 || code == 403 { return .authenticationFailure }
        if code == 429 { return .rateLimited }
        if let code, (500...599).contains(code) { return .serviceFailure }
        return nil
    }
}

enum CodexInviteCheckResult: Equatable, Sendable {
    case available(eligible: Bool)
    case networkFailure, authenticationRequired, accessDenied, rateLimited
    case serviceFailure, invalidResponse, unavailable

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Codex profile menu enables invite only when eligibility succeeds with `should_show == true`.
    var isStatusOneAbnormal: Bool {
        switch self {
        case .available(true): return false
        case .available(false), .networkFailure, .authenticationRequired, .accessDenied,
             .rateLimited, .serviceFailure, .invalidResponse, .unavailable:
            return true
        }
    }

    /// Only actual network failures may start node recovery; other errors are separate diagnostics.
    var recoveryFailure: Bool? {
        switch self {
        case .available: return false
        case .networkFailure: return true
        default: return nil
        }
    }

    /// 面向用户的说明，不暴露 CFNetwork / URLSession 原始错误。
    var userFacingSummary: String {
        switch self {
        case .available(true):
            return "经当前节点调用与菜单相同的资格接口，邀请入口可用。"
        case .available(false):
            return "经当前节点调用与菜单相同的资格接口，当前账号暂无邀请入口。"
        case .networkFailure:
            return "经当前节点访问资格接口超时或失败，多半是节点偏慢或不稳；稍后会自动重试。"
        case .authenticationRequired:
            return "登录凭证无效或已过期，请在 Codex 中重新登录。"
        case .accessDenied:
            return "当前账号无权访问该检查接口。"
        case .rateLimited:
            return "请求过于频繁，稍后会自动重试。"
        case .serviceFailure:
            return "ChatGPT 服务端暂时异常，稍后再试。"
        case .invalidResponse:
            return "检查返回内容异常，稍后会自动重试。"
        case .unavailable:
            return "当前无法执行检查（直连模式、未连接或缺少探测端口）。"
        }
    }
}

/// Status 1 follows the same eligibility path Codex uses for「邀请好友」:
/// `GET /referrals/invite/eligibility` through the current node. Menu AX is not part of the verdict.
/// Codex’s own failed load of that path keeps「异常」even if a later probe returns available.
enum CodexStatusOne {
    static func verdict(
        probe: CodexInviteCheckResult?,
        probeCheckedAt: Date? = nil,
        menuLoadFailure: CodexHealthEvent?,
        isChecking: Bool = false
    ) -> CodexVisibleStatus.Verdict {
        if let failure = menuLoadFailure, failure.workspaceFeature == .inviteEligibility {
            return .abnormal
        }
        if let probe {
            if probe.isStatusOneAbnormal { return .abnormal }
            return .normal
        }
        return isChecking ? .checking : .unchecked
    }

    static func isAbnormal(
        probe: CodexInviteCheckResult?,
        probeCheckedAt: Date? = nil,
        menuLoadFailure: CodexHealthEvent?,
        isChecking: Bool = false
    ) -> Bool {
        verdict(probe: probe, probeCheckedAt: probeCheckedAt, menuLoadFailure: menuLoadFailure,
                isChecking: isChecking) == .abnormal
    }

    static func title(
        probe: CodexInviteCheckResult?,
        probeCheckedAt: Date? = nil,
        menuLoadFailure: CodexHealthEvent?,
        isChecking: Bool = false
    ) -> String {
        CodexVisibleStatus.inviteCheck.title(
            verdict: verdict(probe: probe, probeCheckedAt: probeCheckedAt, menuLoadFailure: menuLoadFailure,
                             isChecking: isChecking))
    }
}

/// Chromium simple-cache entries written by Codex itself for the invite eligibility request.
enum CodexInviteCache {
    static let observationID = "codex-http-cache"
    private static let path = "/referrals/invite/eligibility"

    static func locate(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix("_0") && key(of: $0)?.contains(path) == true }
    }

    /// Simple-cache layout: 8-byte magic, UInt32 version, UInt32 key length, UInt32 hash, padding, then the key.
    static func key(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24 else { return nil }
        let length = header[12..<16].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard (1...4096).contains(length), let key = try? handle.read(upToCount: length), key.count == length else { return nil }
        return String(decoding: key, as: UTF8.self)
    }

    /// Server `date` of a cached HTTP 200 for the eligibility URL; failures never rewrite the entry.
    static func successDate(in file: URL) -> Date? {
        guard let data = try? Data(contentsOf: file), data.count <= 256 * 1024 else { return nil }
        return successDate(in: data)
    }

    static func successDate(in data: Data) -> Date? {
        let text = String(decoding: data, as: UTF8.self)
        guard let status = text.range(of: #"HTTP/[0-9.]+ [0-9]{3}"#, options: .regularExpression),
              text[status].hasSuffix(" 200"),
              let field = text.range(of: #"\x00date:[^\x00]+"#, options: [.regularExpression, .caseInsensitive],
                                     range: status.upperBound..<text.endIndex) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: String(text[field].dropFirst(6)).trimmingCharacters(in: .whitespaces))
    }
}

enum CodexInviteEligibilityProbe {
    struct Credential: Sendable {
        let token: String
        let accountID: String?
        let programID: String
    }

    enum CredentialResult: Sendable {
        case credential(Credential), failed(CodexInviteCheckResult)
    }

    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func check(httpProxyPort: Int, timeout: TimeInterval, executablePath: String? = nil) async -> CodexInviteCheckResult {
        guard (1...65535).contains(httpProxyPort), timeout.isFinite, timeout > 0 else { return .unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let worker = Task.detached(priority: .utility) {
            readCredential(executablePath: executablePath, timeout: min(5, timeout))
        }
        let credentialResult = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return .unavailable }
        let credential: Credential
        switch credentialResult {
        case .credential(let value): credential = value
        case .failed(let result): return result
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return .unavailable }
        // curl through the local proxy avoids URLSession dumping raw CFNetwork / NSURLError
        // "Task finished with error …" lines into the console on timeout or proxy failure.
        return await performEligibilityRequest(credential: credential, httpProxyPort: httpProxyPort, timeout: remaining)
    }

    /// Map proxy / TLS / connectivity failures to friendly results; never surface raw CFNetwork text.
    static func classifyTransportError(_ error: Error) -> CodexInviteCheckResult {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet, .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .httpTooManyRedirects, .redirectToNonExistentLocation,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return .networkFailure
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return .authenticationRequired
            case .cancelled:
                return .unavailable
            default:
                break
            }
        }

        let nsError = error as NSError
        // kCFErrorHTTPSProxyConnectionFailure = 310, and other CFNetwork transport codes.
        if nsError.domain == (kCFErrorDomainCFNetwork as String) {
            return .networkFailure
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let nested = classifyTransportError(underlying)
            if nested != .invalidResponse { return nested }
        }
        return .networkFailure
    }

    static func classifyCurlFailure(status: Int32, timedOut: Bool) -> CodexInviteCheckResult {
        if timedOut || status == 28 { return .networkFailure }
        switch status {
        case 5, 6, 7, 35, 51, 52, 55, 56, 60: return .networkFailure
        default: return .networkFailure
        }
    }

    /// Parse curl stdout that ends with `HOPWORLD_RESULT <code>`; body is everything before the marker.
    static func parseEligibilityCurlOutput(_ output: Data) -> CodexInviteCheckResult {
        let text = String(decoding: output, as: UTF8.self)
        let marker = "HOPWORLD_RESULT "
        let markerRange: Range<String.Index>
        if let ranged = text.range(of: "\n" + marker, options: .backwards) {
            markerRange = ranged
        } else if text.hasPrefix(marker) {
            markerRange = text.startIndex..<text.index(text.startIndex, offsetBy: marker.count)
        } else if let ranged = text.range(of: marker, options: .backwards) {
            markerRange = ranged
        } else {
            return .invalidResponse
        }
        let bodyText = String(text[..<markerRange.lowerBound])
        let statusText = text[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let statusToken = statusText.split(whereSeparator: \.isWhitespace).first,
              let status = Int(statusToken) else {
            return .invalidResponse
        }
        let body = Data(bodyText.utf8)
        guard body.count <= 64 * 1024 else { return .invalidResponse }
        return classify(statusCode: status, data: body)
    }

    private static func performEligibilityRequest(
        credential: Credential,
        httpProxyPort: Int,
        timeout: TimeInterval
    ) async -> CodexInviteCheckResult {
        let probe = request(credential: credential, timeout: timeout)
        guard let url = probe.url else { return .unavailable }
        var args = [
            "-sS",
            "--noproxy", "",
            "-x", "http://127.0.0.1:\(httpProxyPort)",
            "-o", "-",
            "-w", "\nHOPWORLD_RESULT %{http_code}",
            "--connect-timeout", String(format: "%.1f", max(0.8, timeout)),
            "--max-time", String(format: "%.1f", max(1.0, timeout + 0.5)),
            "--http1.1",
            "-H", "Authorization: Bearer " + credential.token,
            "-H", "Accept: application/json",
            "-H", "originator: Codex Desktop",
            "-A", "HopWorld/1.0",
            url.absoluteString
        ]
        if let accountID = credential.accountID {
            args.insert(contentsOf: ["-H", "ChatGPT-Account-Id: " + accountID], at: args.count - 1)
        }
        let result: ProcessRunResult
        do {
            result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: args,
                timeout: max(1, timeout + 0.5)
            )
        } catch {
            return .networkFailure
        }
        if result.cancelled || Task.isCancelled { return .unavailable }
        if result.timedOut || result.status != 0 {
            return classifyCurlFailure(status: result.status, timedOut: result.timedOut || result.status == 28)
        }
        return parseEligibilityCurlOutput(result.output)
    }

    static func configuration(httpProxyPort: Int, timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": httpProxyPort,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": httpProxyPort,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
            "ExceptionsList": [], "ExcludeSimpleHostnames": 0
        ]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    static func request(credential: Credential, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(string: "https://chatgpt.com/backend-api/referrals/invite/eligibility")!
        components.queryItems = [URLQueryItem(name: "program_id", value: credential.programID),
                                 URLQueryItem(name: "entrypoint", value: "persistent")]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("HopWorld/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func classify(statusCode: Int, data: Data) -> CodexInviteCheckResult {
        switch statusCode {
        case 401: return .authenticationRequired
        case 403: return .accessDenied
        case 429: return .rateLimited
        case 500...599: return .serviceFailure
        case 200:
            struct Eligibility: Decodable { let should_show: Bool }
            guard data.count <= 64 * 1024, let result = try? JSONDecoder().decode(Eligibility.self, from: data) else { return .invalidResponse }
            return .available(eligible: result.should_show)
        default: return .invalidResponse
        }
    }

    /// The app-server keeps ownership of login storage; the returned token lives only in this probe.
    static func readCredential(executablePath: String?, timeout: TimeInterval) -> CredentialResult {
        let candidates = executablePath.map { [$0] } ?? [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return .failed(.unavailable) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let end = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            try? output.fileHandleForReading.close()
        }
        do {
            try process.run()
            func send(_ message: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "hopworld_health", "title": "HopWorld Health", "version": "1.0"]]])
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var buffer = Data()
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { return .failed(.unavailable) }
                if ready == 0 { continue }
                guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { return .failed(.unavailable) }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return .failed(.unavailable) }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count < 1024 * 1024 else { return .failed(.unavailable) }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = message["id"] as? Int else { continue }
                    guard message["error"] == nil else { return .failed(.unavailable) }
                    if id == 1 {
                        try send(["method": "initialized"])
                        try send(["id": 2, "method": "getAuthStatus", "params": ["includeToken": true, "refreshToken": false]])
                    } else if id == 2 {
                        guard let result = message["result"] as? [String: Any] else { return .failed(.unavailable) }
                        return credential(from: result)
                    }
                }
            }
        } catch { return .failed(.unavailable) }
        return .failed(.unavailable)
    }

    static func credential(from result: [String: Any]) -> CredentialResult {
        guard let method = result["authMethod"] as? String, ["chatgpt", "chatgptAuthTokens"].contains(method),
              let token = result["authToken"] as? String, !token.isEmpty else { return .failed(.authenticationRequired) }
        guard token.utf8.count <= 16 * 1024, token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { return .failed(.unavailable) }
        let parts = token.split(separator: ".")
        var accountID: String?
        var programID = "codex_referral_consumer"
        if parts.count >= 2 {
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload),
               let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                if let value = auth["chatgpt_account_id"] as? String, !value.isEmpty, value.utf8.count <= 256,
                   value.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) { accountID = value }
                if let plan = auth["chatgpt_plan_type"] as? String,
                   ["team", "business", "enterprise", "edu"].contains(plan.lowercased()) { programID = "codex_referral_workspace" }
            }
        }
        return .credential(Credential(token: token, accountID: accountID, programID: programID))
    }
}

/// Visible UI faults have their own lifetime: other chats and hidden windows cannot prove recovery.
struct CodexInterfaceObservation: Equatable, Sendable {
    private(set) var failureSince: Date?
    private(set) var lastConfirmedAt: Date?
    private(set) var activeKinds: [CodexHealthEvent.Kind] = []
    /// Last confirmed invite-menu enabled flag; unread samples do not clear it.
    private(set) var inviteEnabled: Bool?
    private var failure: CodexHealthEvent?
    private var lastRecordedAt: Date?

    func pendingFailure(now: Date = Date()) -> CodexHealthEvent? {
        guard let lastConfirmedAt, (0...6).contains(now.timeIntervalSince(lastConfirmedAt)) else { return nil }
        return failure
    }

    mutating func observe(_ snapshot: CodexInterfaceHealthSnapshot, at date: Date) -> [CodexHealthEvent] {
        var events: [CodexHealthEvent] = []
        if let enabled = snapshot.inviteEnabled, enabled != inviteEnabled {
            inviteEnabled = enabled
            events.append(CodexHealthEvent(date: date, kind: enabled ? .workspaceRecovered : .workspaceFailure,
                                          workspaceFeature: .inviteMenu))
        }
        let observedKinds: [CodexHealthEvent.Kind] = [
            snapshot.workspaceUnavailable == true ? .workspaceFailure : nil,
            snapshot.waitingForNetwork == true ? .waitingForNetwork : nil,
            snapshot.reconnecting == true ? .reconnecting : nil
        ].compactMap { $0 }
        if activeKinds.contains(.workspaceFailure), snapshot.workspaceUnavailable == false {
            events.append(CodexHealthEvent(date: date, kind: .workspaceRecovered,
                                          observationID: "interface-state", workspaceFeature: .settings))
        }
        if let kind = observedKinds.first {
            let event = CodexHealthEvent(date: date, kind: kind, workspaceFeature: kind == .workspaceFailure ? .settings : nil)
            if failureSince == nil { failureSince = date }
            failure = event
            lastConfirmedAt = date
            let due = lastRecordedAt.map { date.timeIntervalSince($0) >= 10 } ?? true
            for activeKind in observedKinds where due || !activeKinds.contains(activeKind) {
                events.append(CodexHealthEvent(date: date, kind: activeKind,
                    workspaceFeature: activeKind == .workspaceFailure ? .settings : nil))
            }
            if due || observedKinds != activeKinds { lastRecordedAt = date }
            activeKinds = observedKinds
        } else if snapshot.workspaceUnavailable == false && snapshot.reconnecting == false && snapshot.waitingForNetwork == false {
            if let failure, failure.kind == .reconnecting || failure.kind == .waitingForNetwork {
                events.append(CodexHealthEvent(date: date, kind: failure.kind, observationID: "interface-state"))
            }
            failure = nil
            failureSince = nil
            lastConfirmedAt = nil
            lastRecordedAt = nil
            activeKinds = []
        }
        return events
    }
}
