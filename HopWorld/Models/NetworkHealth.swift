import Foundation
import Combine

/// Fixed classifications only: diagnostics never retain raw Codex log lines or identifiers.
struct CodexHealthEvent: Codable, Equatable, Sendable {
    enum WorkspaceFeature: String, Codable, Sendable {
        case inviteEligibility, inviteMenu, settings
    }
    enum RecoveryOrigin: String, Codable, Sendable {
        case appServerBridge, request, responseStream, businessResponse
    }
    enum Kind: String, Codable, Sendable {
        case reconnecting, waitingForNetwork, connectionFailure, connectionReady, requestFailure
        case responseProgress, responseCompleted, workspaceFailure, workspaceRecovered
        case authenticationFailure, rateLimited, serviceFailure, requestStopped
    }
    let date: Date
    let kind: Kind
    var scope: String = "unknown"
    var observationID: String? = nil
    var recoveryOrigin: RecoveryOrigin? = nil
    var workspaceFeature: WorkspaceFeature? = nil
    var inviteEligible: Bool? = nil

    /// Only the three visible interruption states can start automatic node recovery.
    var drivesRecovery: Bool {
        guard scope != "local", scope != "unconfirmed-route", workspaceFeature != .inviteEligibility, workspaceFeature != .inviteMenu else { return false }
        if kind == .workspaceFailure { return workspaceFeature == .settings && recoveryOrigin == .request }
        return (kind == .reconnecting || kind == .waitingForNetwork)
            && (recoveryOrigin == .appServerBridge || recoveryOrigin == .responseStream)
    }

    /// Status 1 record title/detail follow the same「状态 1 正常/异常」wording as the status board.
    private var statusOneAbnormal: Bool {
        if kind == .workspaceRecovered { return inviteEligible == false }
        return true
    }

    var title: String {
        if observationID == "interface-state" {
            if workspaceFeature == .settings {
                return CodexVisibleStatus.workspaceSettings.title(abnormal: false)
            }
            if kind == .waitingForNetwork {
                return CodexVisibleStatus.waitingForNetwork.title(abnormal: false)
            }
            return CodexVisibleStatus.reconnecting.title(abnormal: false)
        }
        if workspaceFeature == .inviteMenu {
            // Menu AX readings can linger from a previous good connection; they are not Status 1.
            return kind == .workspaceFailure ? "界面菜单不可用" : "界面菜单可用"
        }
        if workspaceFeature == .inviteEligibility {
            return CodexVisibleStatus.inviteCheck.title(abnormal: statusOneAbnormal)
        }
        switch kind {
        case .reconnecting: return CodexVisibleStatus.reconnecting.title(abnormal: true)
        case .waitingForNetwork: return CodexVisibleStatus.waitingForNetwork.title(abnormal: true)
        case .connectionFailure: return "Codex 连接失败"
        case .connectionReady: return "Codex 传输已连接"
        case .requestFailure: return "Codex 部分内容暂未加载"
        case .requestStopped: return "Codex 对话已停止"
        case .responseProgress: return "收到 Codex 响应片段"
        case .responseCompleted: return "Codex 响应已完成"
        case .workspaceFailure: return CodexVisibleStatus.workspaceSettings.title(abnormal: true)
        case .workspaceRecovered: return CodexVisibleStatus.workspaceSettings.title(abnormal: false)
        case .authenticationFailure: return "认证或访问验证异常"
        case .rateLimited: return "服务请求受限"
        case .serviceFailure: return "服务端异常"
        }
    }
    var detail: String {
        if observationID == "interface-state" {
            if workspaceFeature == .settings {
                return CodexVisibleStatus.workspaceSettings.recordDetail(abnormal: false,
                    note: "当前可读取的 Codex 界面已不再显示这项提示；会继续观察新的连接状态。")
            }
            let status = kind == .waitingForNetwork ? CodexVisibleStatus.waitingForNetwork : .reconnecting
            return status.recordDetail(abnormal: false,
                note: "当前可读取的 Codex 界面已不再显示这项提示；会继续观察新的连接状态。")
        }
        if workspaceFeature == .inviteMenu {
            return kind == .workspaceFailure
                ? "界面菜单控件读数仅供参考；状态 1 由经当前节点的检查判定。"
                : "界面菜单控件可能沿用上次连接；状态 1 由经当前节点的检查判定。"
        }
        if workspaceFeature == .inviteEligibility {
            let note: String
            switch kind {
            case .workspaceRecovered:
                note = observationID == CodexInviteCache.observationID
                    ? "Codex 自身重新检查状态 1 成功（HTTP 200，读取 Codex 本机网络缓存）。"
                    : inviteEligible == false
                    ? "经当前节点检查状态 1 异常；当前账号无此项，不会因此切换节点。"
                    : "经当前节点检查状态 1 正常；状态 2 至 4 仍会分别观察。"
            case .requestFailure:
                note = observationID == CodexInviteCheckResult.probeObservationID
                    ? "经当前节点检查状态 1 超时或失败，多半是节点偏慢或不稳；稍后会自动重试，不会单独因此切换节点。"
                    : "Codex 检查状态 1 失败；稍后会自动重试，不会单独因此切换节点。"
            case .authenticationFailure:
                note = "登录或访问验证异常，请检查 Codex 登录状态；不单独据此切换节点。"
            case .rateLimited:
                note = "状态 1 检查被限流，稍后重试即可，不将其判作节点网络失效。"
            case .serviceFailure:
                note = "ChatGPT 服务端暂时异常，不将其判作节点网络失效。"
            default:
                note = "状态 1 检查未完成，稍后会自动重试。"
            }
            return CodexVisibleStatus.inviteCheck.recordDetail(abnormal: statusOneAbnormal, note: note)
        }
        switch kind {
        case .reconnecting:
            return CodexVisibleStatus.reconnecting.recordDetail(abnormal: true,
                note: "请稍候。持续未恢复时，将按已开启的智能切换设置尝试备用节点。")
        case .waitingForNetwork:
            return CodexVisibleStatus.waitingForNetwork.recordDetail(abnormal: true,
                note: "请保持网络连接。持续未恢复时，将按已开启的智能切换设置尝试备用节点。")
        case .connectionFailure: return "Codex 刚才连接不顺畅，正在观察是否出现状态 3 或状态 4。"
        case .connectionReady: return "仅确认传输建立，尚不能证明任务或工作区恢复。"
        case .requestFailure:
            return "Codex 的部分内容暂时没有加载成功，稍后会重试；仅凭这条记录不会自动切换节点。"
        case .requestStopped: return "本次对话已停止，已取消这次对话的网络等待，不再据此切换节点。"
        case .responseProgress: return "日志记录实际推理片段到达；不等于整个任务已完成。"
        case .responseCompleted: return "日志记录业务响应完整结束。"
        case .workspaceFailure:
            return CodexVisibleStatus.workspaceSettings.recordDetail(abnormal: true,
                note: "持续未恢复时按智能切换设置处理。")
        case .workspaceRecovered:
            return CodexVisibleStatus.workspaceSettings.recordDetail(abnormal: false,
                note: "可以继续使用。")
        case .authenticationFailure: return "登录或访问验证异常，请检查 Codex 登录状态；不单独据此切换节点。"
        case .rateLimited: return "请求被限流，稍后重试即可，不将其判作节点网络失效。"
        case .serviceFailure: return "ChatGPT 服务端暂时异常，不将其判作节点网络失效。"
        }
    }
    var category: String {
        if workspaceFeature != nil && kind == .requestFailure { return "工作区" }
        switch kind {
        case .workspaceFailure, .workspaceRecovered: return "工作区"
        case .authenticationFailure, .rateLimited, .serviceFailure: return "认证与服务"
        default: return "连接"
        }
    }
    var isBusinessSuccess: Bool { scope == "public" && (kind == .responseProgress || kind == .responseCompleted) }
    var isNetworkFailure: Bool { scope == "public" && workspaceFeature == nil && (kind == .connectionFailure || kind == .requestFailure) }
}

/// Process-wide app state is carried between proxy connections without crediting any node.
struct CodexApplicationObservation: Equatable, Sendable {
    private(set) var pendingBridgeFailure: CodexHealthEvent?
    private(set) var pendingRequestFailure: CodexHealthEvent?
    private(set) var pendingSettingsFailure: CodexHealthEvent?
    private(set) var lastSettingsUpdatedAt: Date?
    private(set) var inviteEligibilityFailure: CodexHealthEvent?
    private(set) var lastUpdatedAt: Date?
    private(set) var lastInviteEligibilityUpdatedAt: Date?
    /// Latest eligibility load by Codex itself (log failure or cached HTTP 200), never our probe.
    private(set) var lastCodexInviteLoadAt: Date?
    private var lastInviteProbeAt: Date?
    private var lastInviteLogAt: Date?
    private var lastInviteClearedAt: Date?
    private(set) var lastResponseAt: Date?
    private(set) var lastTransportReadyAt: Date?

    var pendingNetworkFailure: CodexHealthEvent? {
        [pendingBridgeFailure, pendingRequestFailure].compactMap { $0 }.max { $0.date < $1.date }
    }
    var pendingRecoveryFailure: CodexHealthEvent? {
        [pendingBridgeFailure, pendingRequestFailure, pendingSettingsFailure].compactMap { $0 }
            .filter(\.drivesRecovery).max { $0.date < $1.date }
    }
    var hasPendingNetworkFailure: Bool { pendingNetworkFailure != nil }

    mutating func observe(_ event: CodexHealthEvent) {
        // Invite-menu AX is reference-only for Status 1: a grey control is surfaced via
        // `inviteControlEnabled` in CodexStatusOne, and becoming clickable must not clear a
        // real eligibility-load failure (curl may succeed while Electron stays grey).
        if event.workspaceFeature == .inviteMenu {
            return
        }
        guard let origin = event.recoveryOrigin else { return }
        // Active checks and buffered application logs arrive independently.
        if event.workspaceFeature == .inviteEligibility {
            // Buffered Codex logs carry earlier timestamps than live probes, so each source keeps
            // its own ordering; a later probe success must not discard Codex's own load failure.
            let isProbe = event.observationID == CodexInviteCheckResult.probeObservationID
            guard origin == .request, event.scope != "local", event.scope != "unconfirmed-route",
                  (isProbe ? lastInviteProbeAt : lastInviteLogAt).map({ event.date >= $0 }) ?? true,
                  event.kind != .requestFailure || lastInviteClearedAt.map({ event.date >= $0 }) ?? true
            else { return }
            if isProbe { lastInviteProbeAt = event.date } else {
                lastInviteLogAt = event.date
                lastCodexInviteLoadAt = event.date
            }
            lastInviteEligibilityUpdatedAt = max(lastInviteEligibilityUpdatedAt ?? event.date, event.date)
            let hadFailure = inviteEligibilityFailure != nil
            defer {
                if hadFailure, inviteEligibilityFailure == nil {
                    lastInviteClearedAt = max(lastInviteClearedAt ?? event.date, event.date)
                }
            }
            switch event.kind {
            case .requestFailure:
                // Keep an unresolved Codex menu-load failure; probe transport errors are shown via inviteResult.
                if event.observationID == CodexInviteCheckResult.probeObservationID,
                   let existing = inviteEligibilityFailure,
                   existing.observationID != CodexInviteCheckResult.probeObservationID {
                    break
                }
                inviteEligibilityFailure = event
            case .workspaceRecovered:
                // Probe `should_show == true` cannot clear Codex's own menu-load failure: curl may
                // succeed while Electron still fails (cert / session path), leaving the item grey.
                if event.inviteEligible == true,
                   inviteEligibilityFailure?.observationID != CodexInviteCheckResult.probeObservationID {
                    break
                }
                inviteEligibilityFailure = nil
            case .authenticationFailure, .rateLimited, .serviceFailure:
                inviteEligibilityFailure = nil
            default: break
            }
            return
        }
        if event.workspaceFeature == .settings {
            guard origin == .request, event.scope != "local", event.scope != "unconfirmed-route",
                  lastSettingsUpdatedAt.map({ event.date >= $0 }) ?? true else { return }
            lastSettingsUpdatedAt = event.date
            switch event.kind {
            case .workspaceFailure: pendingSettingsFailure = event
            case .workspaceRecovered, .authenticationFailure, .rateLimited, .serviceFailure:
                pendingSettingsFailure = nil
            default: break
            }
            return
        }
        if origin == .businessResponse && (event.kind == .responseProgress || event.kind == .responseCompleted) {
            if lastResponseAt.map({ event.date >= $0 }) ?? true { lastResponseAt = event.date }
            if lastSettingsUpdatedAt.map({ event.date >= $0 }) ?? true {
                pendingSettingsFailure = nil
                lastSettingsUpdatedAt = event.date
            }
        }
        guard origin != .request,
              !(origin == .appServerBridge && (event.scope == "local" || event.scope == "unconfirmed-route")),
              lastUpdatedAt.map({ event.date >= $0 }) ?? true else { return }
        lastUpdatedAt = event.date
        switch event.kind {
        case .connectionFailure, .requestFailure, .reconnecting, .waitingForNetwork:
            guard event.scope != "local", event.scope != "unconfirmed-route" else { return }
            if origin == .appServerBridge, pendingBridgeFailure?.drivesRecovery != true || event.drivesRecovery { pendingBridgeFailure = event }
            if origin == .responseStream, pendingRequestFailure?.drivesRecovery != true || event.drivesRecovery { pendingRequestFailure = event }
        case .connectionReady:
            guard origin == .appServerBridge else { return }
            lastTransportReadyAt = event.date
            pendingBridgeFailure = nil
        case .responseProgress, .responseCompleted:
            guard origin == .businessResponse else { return }
            clearPendingFailures()
        case .authenticationFailure, .rateLimited, .serviceFailure:
            if origin == .appServerBridge { pendingBridgeFailure = nil }
            if origin == .responseStream { pendingRequestFailure = nil }
        case .requestStopped:
            if origin == .responseStream { pendingRequestFailure = nil }
        case .workspaceRecovered, .workspaceFailure:
            break
        }
    }

    private mutating func clearPendingFailures() {
        pendingBridgeFailure = nil
        pendingRequestFailure = nil
    }
}

extension CodexInviteCheckResult {
    /// Marks HopWorld's directional probe so it cannot erase Codex's own menu-load failures.
    static let probeObservationID = "hopworld-invite-probe"

    func healthEvent(at date: Date) -> CodexHealthEvent {
        let kind: CodexHealthEvent.Kind
        switch self {
        case .available: kind = .workspaceRecovered
        case .networkFailure: kind = .requestFailure
        case .authenticationRequired, .accessDenied: kind = .authenticationFailure
        case .rateLimited: kind = .rateLimited
        case .serviceFailure: kind = .serviceFailure
        case .invalidResponse, .unavailable: kind = .workspaceFailure
        }
        return CodexHealthEvent(date: date, kind: kind, scope: "public",
                                observationID: Self.probeObservationID, recoveryOrigin: .request,
                                workspaceFeature: .inviteEligibility, inviteEligible: {
                                    if case .available(let eligible) = self { return eligible }
                                    return nil
                                }())
    }
}

enum AppHealthStatus: String, Codable, Sendable {
    case unknown, healthy, mild, degraded, unavailable
    var displayName: String {
        switch self {
        case .unknown: return "待验证"
        case .healthy: return "健康"
        case .mild: return "轻度降级"
        case .degraded: return "明显降级"
        case .unavailable: return "应用不可用"
        }
    }
}

struct AppHealthRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let nodeKey: String
    let context: String
    let date: Date
    let event: CodexHealthEvent
    var nodeID: UUID? = nil

    func belongsToNode(nodeKey: String, nodeID: UUID?) -> Bool {
        if let nodeID, let storedID = self.nodeID { return storedID == nodeID }
        return self.nodeKey == nodeKey
    }
}

/// Claude / Cursor 的 Claude 模型可用性记录；不含原始响应或请求标识。
struct ApplicationCheckRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let application: HealthApplication
    let nodeKey: String
    var nodeID: UUID? = nil
    let available: Bool
    let title: String
    let detail: String

    func belongsToNode(nodeKey: String, nodeID: UUID?) -> Bool {
        if let nodeID, let storedID = self.nodeID { return storedID == nodeID }
        return self.nodeKey == nodeKey
    }
}

struct AppHealthEventPage {
    static let size = 10
    let number: Int
    let pageCount: Int
    let totalCount: Int
    let records: [AppHealthRecord]

    init(records: [AppHealthRecord], number: Int) {
        totalCount = records.count
        pageCount = max(1, (records.count + Self.size - 1) / Self.size)
        self.number = min(max(1, number), pageCount)
        self.records = Array(records.dropFirst((self.number - 1) * Self.size).prefix(Self.size))
    }
}

struct HealthSwitchRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let from: String
    let to: String
    let context: String
    let reason: String
    let result: String
}

enum AppDiagnosticState: Equatable, Sendable {
    case idle, responding, reconnecting, waitingForNetwork, networkFailure, transportReady
    case serviceIssue, workspaceIssue, workspaceRecovered

    var displayName: String {
        switch self {
        case .idle: return "最近无新活动"
        case .responding: return "近期收到应用响应"
        case .reconnecting: return CodexVisibleStatus.reconnecting.title(abnormal: true)
        case .waitingForNetwork: return CodexVisibleStatus.waitingForNetwork.title(abnormal: true)
        case .networkFailure: return "部分内容暂未加载"
        case .transportReady: return "传输已连接"
        case .serviceIssue: return "认证或服务异常"
        case .workspaceIssue: return CodexVisibleStatus.workspaceSettings.title(abnormal: true)
        case .workspaceRecovered: return CodexVisibleStatus.workspaceSettings.title(abnormal: false)
        }
    }
}

/// Fixed Codex UI statuses shown in the health center as「状态 N 未检测/检测中/正常/异常」.
enum CodexVisibleStatus: Int, CaseIterable, Identifiable, Sendable {
    /// Same eligibility load path Codex uses for the invite menu, called through the current node.
    case inviteCheck = 1
    case workspaceSettings = 2
    case reconnecting = 3
    case waitingForNetwork = 4

    enum Verdict: Equatable, Sendable {
        /// No result yet (e.g. status 1 probe not finished, or not on the live connection).
        case unchecked
        /// A check is actively running.
        case checking
        case normal
        case abnormal
    }

    var id: Int { rawValue }

    func title(verdict: Verdict) -> String {
        let word: String
        switch verdict {
        case .unchecked: word = "未检测"
        case .checking: word = "检测中"
        case .normal: word = "正常"
        case .abnormal: word = "异常"
        }
        return "状态 \(rawValue) \(word)"
    }

    func title(abnormal: Bool) -> String {
        title(verdict: abnormal ? .abnormal : .normal)
    }

    func recordDetail(abnormal: Bool, note: String) -> String {
        "\(title(abnormal: abnormal))。\(note)"
    }
}

/// App log activity is useful even when it cannot establish public-node provenance.
struct AppDiagnosticSnapshot: Sendable {
    var state: AppDiagnosticState = .idle
    var connectionSummary = "最近没有通信活动；未发起对话时没有响应是正常状态。"
    var workspaceSummary = "尚无工作区加载事件"
    var serviceSummary = "尚无认证、限流或服务端事件"
    var lastEventAt: Date?
    var lastResponseAt: Date?
    var lastNetworkFailureAt: Date?

    init(events: [CodexHealthEvent] = [], now: Date = Date()) {
        let events = events.filter { $0.date <= now }.sorted { $0.date < $1.date }
        lastEventAt = events.last?.date
        lastResponseAt = events.last { $0.kind == .responseProgress || $0.kind == .responseCompleted }?.date
        lastNetworkFailureAt = events.last { $0.workspaceFeature == nil && ($0.kind == .connectionFailure || $0.kind == .requestFailure) }?.date
        let response = events.last { $0.kind == .responseProgress || $0.kind == .responseCompleted }
        let requestFailure = events.last { $0.workspaceFeature == nil && ($0.kind == .requestFailure
            || $0.recoveryOrigin == .responseStream && ($0.kind == .reconnecting || $0.kind == .waitingForNetwork)) }
        let bridgeFailure = events.last { $0.recoveryOrigin != .responseStream && ($0.kind == .connectionFailure || $0.kind == .reconnecting || $0.kind == .waitingForNetwork) }
        let ready = events.last { $0.kind == .connectionReady }
        let serviceBoundary = events.last { $0.recoveryOrigin != .request && $0.workspaceFeature == nil && ($0.kind == .authenticationFailure || $0.kind == .rateLimited || $0.kind == .serviceFailure) }?.date ?? .distantPast
        let stopped = events.last { $0.kind == .requestStopped && $0.recoveryOrigin == .responseStream }?.date ?? .distantPast
        let pendingRequest = requestFailure.flatMap {
            $0.date >= max(response?.date ?? .distantPast, serviceBoundary, stopped) ? $0 : nil
        }
        let pendingBridge = bridgeFailure.flatMap {
            $0.date >= max(response?.date ?? .distantPast, ready?.date ?? .distantPast, serviceBoundary) ? $0 : nil
        }
        var connectionEvent: CodexHealthEvent?
        var connectionState: AppDiagnosticState = .idle
        if let failure = [pendingRequest, pendingBridge].compactMap({ $0 }).max(by: { $0.date < $1.date }) {
            connectionEvent = failure
            connectionState = failure.kind == .reconnecting ? .reconnecting
                : (failure.kind == .waitingForNetwork ? .waitingForNetwork : .networkFailure)
            connectionSummary = failure.kind == .requestFailure
                ? "Codex 部分内容暂未加载成功；会继续检查工作空间、重新连接和等待网络状态。"
                : failure.detail
            if now.timeIntervalSince(failure.date) > 120 {
                connectionSummary += " 最近暂无新日志，故障尚未观测恢复。"
            }
        } else if let response, now.timeIntervalSince(response.date) <= 120, response.date >= (ready?.date ?? .distantPast) {
            connectionEvent = response
            connectionState = .responding
            connectionSummary = "近期收到应用响应片段或响应结束事件；已有数据到达，完整请求结果仍单独验证。"
        } else if let ready, now.timeIntervalSince(ready.date) <= 120 {
            connectionEvent = ready
            connectionState = .transportReady
            connectionSummary = "传输已经建立；未发起对话时没有响应是正常状态。"
        } else if lastResponseAt != nil || lastNetworkFailureAt != nil || events.contains(where: { $0.kind == .connectionReady }) {
            connectionSummary = "最近没有通信活动；未发起对话时没有响应是正常状态，历史响应与故障记录保留供查看。"
        }
        state = connectionState
        var stateDate = connectionEvent?.date ?? .distantPast
        if let service = events.last(where: { $0.workspaceFeature == nil && ($0.kind == .authenticationFailure || $0.kind == .rateLimited || $0.kind == .serviceFailure) }) {
            serviceSummary = service.eventSummary(now: now)
            if now.timeIntervalSince(service.date) <= 120, service.date > stateDate {
                state = .serviceIssue
                stateDate = service.date
            }
        }
        let settingsEvents = events.filter { $0.workspaceFeature == .settings }
        let pendingSettings = settingsEvents.last { $0.kind == .workspaceFailure }.flatMap { failure in
            settingsEvents.last.map { $0.date <= failure.date } == true
                && (response.map { $0.date < failure.date } ?? true) ? failure : nil
        }
        if let pendingSettings {
            workspaceSummary = pendingSettings.title + "。" + pendingSettings.detail
            state = .workspaceIssue
        } else if let response, let lastSettingsFailure = settingsEvents.last(where: { $0.kind == .workspaceFailure }),
                  response.date >= lastSettingsFailure.date {
            workspaceSummary = "收到新的对话回复，状态 2 已恢复。"
        } else if let workspace = events.last(where: { $0.kind == .workspaceFailure || $0.kind == .workspaceRecovered || $0.workspaceFeature != nil }) {
            workspaceSummary = workspace.eventSummary(now: now)
            if workspace.workspaceFeature == nil, now.timeIntervalSince(workspace.date) <= 120, workspace.date > stateDate,
               workspace.kind == .workspaceFailure || (connectionState == .idle && state != .serviceIssue) {
                state = workspace.kind == .workspaceFailure ? .workspaceIssue : .workspaceRecovered
            }
        }
    }
}

private extension CodexHealthEvent {
    func eventSummary(now: Date) -> String {
        let prefix = now.timeIntervalSince(date) <= 120 ? "最近记录：" : "历史记录："
        // inviteEligibility titles already include「状态 1 …」.
        return prefix + title + " · " + date.formatted(date: .abbreviated, time: .standard)
    }
}

struct AppHealthSnapshot: Sendable {
    var diagnostic = AppDiagnosticSnapshot()
    var status: AppHealthStatus = .unknown
    var connectionSummary = "暂无实际应用通信证据"
    var workspaceSummary = "未观测"
    var serviceSummary = "未观测"
    var failureSince: Date?
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastObservedAt: Date?
    var lastFailureKind: CodexHealthEvent.Kind?
    var lastServiceFailureAt: Date?
    var score: Int?
    var scoreCoverage = 0
    var quarantined = false
    var recentFailureCount = 0
    var diagnosticEventCount = 0
    var attributedEventCount = 0
    var diagnosticReconnectCount = 0
    var diagnosticFailureCount = 0
    var responseFragmentCount = 0
    var verifiedRequestCount = 0
    var verifiedRequestSpan: TimeInterval = 0
    var observedSeconds: TimeInterval = 0
    var instabilityEventCount = 0
    var scoreUnavailableReason: String? = "最近 15 分钟尚无当前节点与环境的应用观测。"
    var observedAvailability: Double?
    var successRate: Double?
    var stabilityRatio: Double?
}

@MainActor
final class NetworkHealthStore: ObservableObject {
    @Published private(set) var records: [AppHealthRecord] = []
    @Published private(set) var switches: [HealthSwitchRecord] = []
    @Published private(set) var checks: [ApplicationCheckRecord] = []
    @Published private(set) var persistenceError: String?
    static let applicationCheckLimit = 10
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "com.hopworld.health-history")
    private var persistenceBlocked = false
    // Scoring uses only the retained samples; missing history never becomes a passing score.
    private static let retention: TimeInterval = 24 * 60 * 60
    private struct Archive: Codable, Sendable {
        var records: [AppHealthRecord]
        var switches: [HealthSwitchRecord]
        var checks: [ApplicationCheckRecord]?
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HopWorld/network-health.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.fileURL))
            records = Self.limitedRecords(archive.records)
            switches = Array(archive.switches.sorted { $0.date < $1.date }.suffix(Self.applicationCheckLimit))
            checks = Self.limitedChecks(archive.checks ?? [])
            if records.count != archive.records.count || switches.count != archive.switches.count
                || checks.count != (archive.checks ?? []).count {
                scheduleSave()
            }
        } catch {
            persistenceBlocked = true
            persistenceError = "健康历史读取失败，已暂停写入以保留原文件：\(error.localizedDescription)"
        }
    }

    func record(event: CodexHealthEvent, nodeKey: String, context: String, now: Date = Date(), nodeID: UUID? = nil) {
        let age = now.timeIntervalSince(event.date)
        guard !nodeKey.isEmpty, !context.isEmpty, age.isFinite, age >= -5 else { return }
        // Duplicate state_changed/reconnect messages in the same burst are one observation.
        if let previous = records.last(where: { $0.nodeKey == nodeKey && $0.nodeID == nodeID && $0.context == context && $0.event.kind == event.kind && $0.event.scope == event.scope && $0.event.observationID == event.observationID && $0.event.workspaceFeature == event.workspaceFeature }),
           abs(event.date.timeIntervalSince(previous.date)) < 2 { return }
        records = Self.limitedRecords(records + [AppHealthRecord(nodeKey: nodeKey, context: context, date: event.date, event: event, nodeID: nodeID)])
        scheduleSave()
    }

    func recordCheck(_ record: ApplicationCheckRecord) {
        checks = Self.limitedChecks(checks + [record])
        scheduleSave()
    }

    func recordSwitch(from: String, to: String, context: String, reason: String, result: String, now: Date = Date()) {
        switches.append(HealthSwitchRecord(date: now, from: from, to: to, context: context, reason: reason, result: result))
        switches = Array(switches.sorted { $0.date < $1.date }.suffix(Self.applicationCheckLimit))
        scheduleSave()
    }

    private static func limitedRecords(_ records: [AppHealthRecord]) -> [AppHealthRecord] {
        var idsByKey: [String: Set<UUID>] = [:]
        for record in records {
            if let id = record.nodeID { idsByKey[record.nodeKey, default: []].insert(id) }
        }
        var counts: [String: Int] = [:]
        return Array(records.sorted { $0.date < $1.date }.reversed().filter { record in
            let keys: [String]
            if let id = record.nodeID { keys = ["id:" + id.uuidString] }
            else if let ids = idsByKey[record.nodeKey], !ids.isEmpty {
                keys = ids.map { "id:" + $0.uuidString }
            } else { keys = ["key:" + record.nodeKey] }
            guard keys.allSatisfy({ counts[$0, default: 0] < applicationCheckLimit }) else { return false }
            for key in keys { counts[key, default: 0] += 1 }
            return true
        }.reversed())
    }

    private static func limitedChecks(_ checks: [ApplicationCheckRecord]) -> [ApplicationCheckRecord] {
        var idsByKey: [String: Set<UUID>] = [:]
        for record in checks {
            if let id = record.nodeID {
                idsByKey[record.application.rawValue + "/" + record.nodeKey, default: []].insert(id)
            }
        }
        var counts: [String: Int] = [:]
        return Array(checks.sorted { $0.date < $1.date }.reversed().filter { record in
            let prefix = record.application.rawValue + "/"
            let keys: [String]
            if let id = record.nodeID { keys = [prefix + "id:" + id.uuidString] }
            else if let ids = idsByKey[prefix + record.nodeKey], !ids.isEmpty {
                keys = ids.map { prefix + "id:" + $0.uuidString }
            } else { keys = [prefix + "key:" + record.nodeKey] }
            guard keys.allSatisfy({ counts[$0, default: 0] < applicationCheckLimit }) else { return false }
            for key in keys { counts[key, default: 0] += 1 }
            return true
        }.reversed())
    }

    func snapshot(nodeKey: String, context: String, now: Date = Date(), diagnosticSince: Date? = nil) -> AppHealthSnapshot {
        let stored = records.filter { $0.nodeKey == nodeKey && $0.context == context && $0.date <= now }
        let all = stored.filter { now.timeIntervalSince($0.date) <= Self.retention }
        let recent = all.filter { now.timeIntervalSince($0.date) <= 120 }
        let window = all.filter { now.timeIntervalSince($0.date) <= 15 * 60 }
        let success = all.last { $0.event.isBusinessSuccess }
        let failures = recent.filter { $0.event.isNetworkFailure }
        let reconnects = recent.filter { $0.event.scope == "public" && $0.event.kind == .reconnecting }
        let lastFailure = all.last { $0.event.isNetworkFailure }
        let service = recent.last { $0.event.workspaceFeature == nil && ($0.event.kind == .authenticationFailure || $0.event.kind == .rateLimited || $0.event.kind == .serviceFailure) }
        let workspace = recent.last { $0.event.kind == .workspaceFailure || $0.event.kind == .workspaceRecovered || $0.event.workspaceFeature != nil }
        var result = AppHealthSnapshot()
        let diagnosticRecords = stored.filter { record in diagnosticSince.map { record.date >= $0 } ?? true }
        let diagnosticWindow = diagnosticRecords.filter { now.timeIntervalSince($0.date) <= 15 * 60 }
        result.diagnostic = AppDiagnosticSnapshot(events: diagnosticRecords.map(\.event), now: now)
        result.diagnosticEventCount = diagnosticWindow.count
        result.attributedEventCount = diagnosticWindow.filter { $0.event.scope == "public" }.count
        result.diagnosticReconnectCount = diagnosticWindow.filter { $0.event.kind == .reconnecting }.count
        result.diagnosticFailureCount = diagnosticWindow.filter {
            $0.event.workspaceFeature == nil && ($0.event.kind == .connectionFailure || $0.event.kind == .requestFailure)
        }.count
        result.responseFragmentCount = diagnosticWindow.filter { $0.event.kind == .responseProgress }.count
        result.lastSuccessAt = success?.date
        result.lastFailureAt = lastFailure?.date
        result.lastFailureKind = lastFailure?.event.kind
        result.lastObservedAt = all.last?.date
        result.lastServiceFailureAt = service?.date
        result.recentFailureCount = failures.count
        result.serviceSummary = service?.event.title ?? "暂无认证或服务故障证据"
        result.workspaceSummary = workspace?.event.title ?? "暂无工作区请求证据"
        // Failure duration comes from a continuing series, never time passing after one isolated error.
        let unresolved = failures.filter { $0.date > (success?.date ?? .distantPast) }
        if let first = unresolved.first, let last = unresolved.last,
           unresolved.count >= 2, now.timeIntervalSince(last.date) <= 20 {
            var start = first.date
            for pair in zip(unresolved, unresolved.dropFirst()) where pair.1.date.timeIntervalSince(pair.0.date) > 30 { start = pair.1.date }
            result.failureSince = start
        }
        let hasRecentResponse = success.map { now.timeIntervalSince($0.date) <= 120 } ?? false
        if let since = result.failureSince, now.timeIntervalSince(since) >= 30, unresolved.count >= 3,
           !hasRecentResponse, service == nil {
            result.status = .unavailable
            result.quarantined = true
            result.connectionSummary = "持续网络失败达到 30 秒，近期没有实际响应证据"
        } else if failures.count >= 3 || reconnects.count >= 3 {
            result.status = hasRecentResponse ? .mild : .degraded
            result.connectionSummary = hasRecentResponse ? "频繁重连，但仍收到实际响应；继续观察" : "近期频繁连接异常，尚未验证实际恢复"
        } else if !failures.isEmpty || !reconnects.isEmpty {
            result.status = .mild
            result.connectionSummary = hasRecentResponse ? "偶发连接异常，仍有实际响应" : "发现连接异常，等待实际响应确认恢复"
        } else if hasRecentResponse {
            result.status = .healthy
            result.connectionSummary = "近期收到实际业务响应"
        } else if let diagnostic = recent.last(where: { $0.event.workspaceFeature == nil && ($0.event.kind == .connectionFailure || $0.event.kind == .requestFailure || $0.event.kind == .reconnecting) }) {
            result.connectionSummary = diagnostic.event.title + "；日志未确认当前节点归属"
        } else if all.last != nil {
            result.connectionSummary = "近期没有对话响应记录；未发起对话时没有响应是正常状态。"
        }
        // Keep a recently proven bad node isolated after leaving it; stale evidence is not live failure.
        var streakStart: Date?
        var previousFailure: Date?
        var streakCount = 0
        for record in window {
            if record.event.isBusinessSuccess {
                streakStart = nil
                previousFailure = nil
                streakCount = 0
                result.quarantined = false
            } else if record.event.isNetworkFailure {
                if previousFailure.map({ record.date.timeIntervalSince($0) > 30 }) ?? true {
                    streakStart = record.date
                    streakCount = 0
                }
                streakCount += 1
                previousFailure = record.date
                if let start = streakStart, streakCount >= 3, record.date.timeIntervalSince(start) >= 30 {
                    result.quarantined = true
                }
            } else if record.event.workspaceFeature == nil && (record.event.kind == .authenticationFailure || record.event.kind == .rateLimited || record.event.kind == .serviceFailure) {
                // A service/authentication episode cannot establish a network quarantine.
                streakStart = nil
                previousFailure = nil
                streakCount = 0
            }
        }
        if hasRecentResponse || service != nil { result.quarantined = false }
        if result.quarantined && result.status != .unavailable {
            result.connectionSummary += "；此前持续网络故障仍在 15 分钟隔离期"
        }
        // Stream fragments can show progress but cannot inflate the completed-request success rate.
        let evidence = window.filter { $0.event.isNetworkFailure || $0.event.isBusinessSuccess }
        if evidence.count >= 2 {
            var available: TimeInterval = 0
            var observed: TimeInterval = 0
            for pair in zip(evidence, evidence.dropFirst()) {
                let seconds = max(0, pair.1.date.timeIntervalSince(pair.0.date))
                guard seconds <= 20 else { continue }
                observed += seconds
                if pair.0.event.isBusinessSuccess { available += seconds }
            }
            result.observedSeconds = observed
            if observed > 0 { result.observedAvailability = available / observed }
        }
        var requests: [String: AppHealthRecord] = [:]
        for record in window where record.event.scope == "public" &&
            (record.event.kind == .responseCompleted || record.event.isNetworkFailure && record.event.kind == .requestFailure) {
            if let key = record.event.observationID { requests[key] = record }
        }
        let completed = requests.values.sorted { $0.date < $1.date }
        result.verifiedRequestCount = completed.count
        if let first = completed.first, let last = completed.last {
            result.verifiedRequestSpan = last.date.timeIntervalSince(first.date)
        }
        result.instabilityEventCount = window.filter {
            $0.event.scope == "public" && ($0.event.kind == .reconnecting || $0.event.kind == .connectionFailure)
        }.count
        if !completed.isEmpty {
            result.successRate = Double(completed.filter { $0.event.kind == .responseCompleted }.count) / Double(completed.count)
            // Stability is the reconnect/failure penalty per verified request, not an event success rate.
            result.stabilityRatio = 1 - min(1, Double(result.instabilityEventCount) / Double(completed.count))
        }
        if completed.count >= 5, result.verifiedRequestSpan >= 20,
           let availability = result.observedAvailability,
           let requestSuccess = result.successRate, let stability = result.stabilityRatio {
            // Latency is deliberately absent: no fabricated 5 latency points.
            result.score = Int((45 * availability + 30 * requestSuccess + 20 * stability).rounded())
            result.scoreCoverage = 95
        }
        if result.score != nil {
            result.scoreUnavailableReason = nil
        } else if window.isEmpty {
            result.scoreUnavailableReason = "最近 15 分钟尚无当前节点与环境的应用观测。"
        } else if result.attributedEventCount == 0 {
            result.scoreUnavailableReason = "已收到日志诊断，但尚不能确认它们经过当前节点；真实会话评分采集尚未接通，保持连接或等待更久不能补齐缺失的归属信息。"
        } else if completed.isEmpty {
            result.scoreUnavailableReason = "已取得连接观测，但当前日志未提供可核实的完整请求结果，暂不支持真实会话评分。"
        } else if completed.count < 5 {
            result.scoreUnavailableReason = "已取得 \(completed.count) 个不同请求的结果，至少需要 5 个才可评分。"
        } else if let first = completed.first, let last = completed.last,
                  last.date.timeIntervalSince(first.date) < 20 {
            result.scoreUnavailableReason = "已有足量请求结果，但观测跨度尚未达到 20 秒。"
        } else {
            result.scoreUnavailableReason = "请求之间缺少连续的有效观测时段，尚不能计算应用可用占比。"
        }
        return result
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard !persistenceBlocked else { return }
        let archive = Archive(records: records, switches: switches, checks: checks)
        let destination = fileURL
        let error: String? = await withCheckedContinuation { continuation in
            saveQueue.async {
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(archive)
                    try data.write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "健康历史保存失败：\(error.localizedDescription)")
                }
            }
        }
        persistenceError = error
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            await self?.flush()
        }
    }

    deinit { saveTask?.cancel() }
}

struct AppHealthRecordQuery: Equatable {
    enum Period: String, CaseIterable {
        case all = "全部时间"
        case quarterHour = "最近 15 分钟", hour = "最近 1 小时", day = "最近 24 小时"
        var seconds: TimeInterval {
            switch self {
            case .all: return .infinity
            case .quarterHour: return 900
            case .hour: return 3600
            case .day: return 86400
            }
        }
    }
    enum Category: String, CaseIterable {
        case all = "全部事件", connection = "连接", workspace = "工作区", service = "认证与服务"
        case verifiedRequests = "可核实请求"
    }
    var period: Period = .all
    var category: Category = .all
    var currentEnvironmentOnly = false

    func apply(to records: [AppHealthRecord], nodeKey: String, context: String, now: Date, nodeID: UUID? = nil) -> [AppHealthRecord] {
        records.filter {
            $0.belongsToNode(nodeKey: nodeKey, nodeID: nodeID) && (!currentEnvironmentOnly || $0.context == context)
                && (0...period.seconds).contains(now.timeIntervalSince($0.date))
                && (category == .all || $0.event.category == category.rawValue
                    || (category == .verifiedRequests && $0.event.scope == "public"
                        && $0.event.observationID != nil
                        && ($0.event.kind == .responseCompleted || $0.event.kind == .requestFailure && $0.event.isNetworkFailure)))
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
    }

    /// Export classifications only; exclude node, network and request identifiers.
    static func export(_ records: [AppHealthRecord], currentContext: String, generatedAt: Date) throws -> Data {
        struct Event: Encodable {
            let date: Date
            let title: String
            let category: String
            let detail: String
            let provenance: String
            let environment: String
        }
        struct Report: Encodable {
            let generatedAt: Date
            let events: [Event]
        }
        let report = Report(generatedAt: generatedAt, events: records.map {
            Event(date: $0.date, title: $0.event.title, category: $0.event.category,
                  detail: $0.event.detail, provenance: $0.event.provenanceDescription,
                  environment: $0.context == currentContext ? "当前环境" : "其他历史环境")
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

extension CodexHealthEvent {
    var provenanceDescription: String {
        switch scope {
        case "public": return "已确认公网路径"
        case "durable", "remote": return "远程桥接诊断 · 节点归属未确认"
        case "local": return "本地诊断 · 节点归属未确认"
        case "unconfirmed-route": return "诊断事件 · 接管路径未确认"
        default: return "诊断事件 · 公网路径未确认"
        }
    }
}
