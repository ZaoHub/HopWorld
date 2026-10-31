import Foundation

struct WebSocketQualityResult: Sendable {
    let verified: Bool
    let survived: Bool
    let observedSeconds: TimeInterval
    let requestedSeconds: TimeInterval
    let detail: String
    var measuredAt = Date()

    var survivalRate: Double? {
        guard verified, requestedSeconds.isFinite, requestedSeconds > 0,
              observedSeconds.isFinite, observedSeconds >= 0,
              !survived || observedSeconds >= requestedSeconds else { return nil }
        return survived ? 1 : 0
    }

    var isLongObservation: Bool { requestedSeconds.isFinite && requestedSeconds >= 360 }
    var scoringWeight: Int { survivalRate == nil || isLongObservation ? 35 : 10 }
}

struct DatagramLossResult: Sendable {
    let verified: Bool
    let sent: Int
    let received: Int
    let detail: String
    var measuredAt = Date()

    var lossRate: Double? {
        guard verified, sent > 0, (0...sent).contains(received) else { return nil }
        return Double(sent - received) / Double(sent)
    }

    var scoringWeight: Int {
        guard lossRate != nil else { return 15 }
        return min(15, max(1, sent / 2))
    }
}

enum AIQualityProfile: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }
    func isEnabled(in settings: AppSettings) -> Bool {
        self == .codex || settings.proxyApplications.contains { $0.isClaude }
    }

    var displayName: String { self == .codex ? "Codex" : "Claude" }
    var streamMetricName: String { self == .codex ? "WebSocket 长连接存活率" : "Claude 流式响应完整率" }
    var streamExplanation: String {
        switch self {
        case .codex:
            return "Codex 专项需验证真实 WebSocket 长连接；普通 HTTPS 成功不代表会话持续可用。"
        case .claude:
            return "Claude 专项需验证流式响应正常结束及中途错误；HTTP 200 不代表完整响应。API 流式测试与网页、桌面客户端需分别验证。"
        }
    }
}

/// Scores only measured dimensions. Missing evidence never earns points.
struct AINodeScoreComponent: Identifiable, Equatable {
    let id: String
    let title: String
    let weight: Int
    fileprivate let rawPoints: Double?

    var points: Int? { rawPoints.map { Int($0.rounded()) } }
}

struct AINodeScore: Equatable {
    let points: Int
    let coverage: Int

    static func calculate(longConnectionSurvival: Double? = nil, packetLoss: Double? = nil,
                          jitterMs: Double?, successRate: Double?, latencyMs: Double?) -> Self {
        aggregate(components(longConnectionSurvival: longConnectionSurvival, packetLoss: packetLoss,
                             jitterMs: jitterMs, successRate: successRate, latencyMs: latencyMs))
    }

    fileprivate static func aggregate(_ components: [AINodeScoreComponent]) -> Self {
        Self(points: Int(components.compactMap(\.rawPoints).reduce(0, +).rounded()),
             coverage: components.filter { $0.rawPoints != nil }.reduce(0) { $0 + $1.weight })
    }

    fileprivate static func components(streamTitle: String = "WebSocket 长连接存活率",
                                       streamWeight: Int = 35, packetLossWeight: Int = 15,
                                       longConnectionSurvival: Double?, packetLoss: Double?,
                                       jitterMs: Double?, successRate: Double?, latencyMs: Double?) -> [AINodeScoreComponent] {
        func component(_ id: String, _ title: String, _ value: Double?, weight: Int,
                       quality: (Double) -> Double) -> AINodeScoreComponent {
            let points = value.flatMap { value -> Double? in
                guard value.isFinite, value >= 0 else { return nil }
                return Double(weight) * min(1, max(0, quality(value)))
            }
            return AINodeScoreComponent(id: id, title: title, weight: weight, rawPoints: points)
        }
        return [
            component("stream", streamTitle, longConnectionSurvival.flatMap { $0 <= 1 ? $0 : nil }, weight: streamWeight) { $0 },
            component("packetLoss", "UDP 往返丢包", packetLoss.flatMap { $0 <= 1 ? $0 : nil }, weight: packetLossWeight) { 1 - $0 / 0.05 },
            component("jitter", "HTTPS 延迟抖动", jitterMs, weight: 15) { 1 - $0 / 300 },
            component("successRate", "HTTPS 请求成功率", successRate.flatMap { $0 <= 1 ? $0 : nil }, weight: 20) { $0 },
            component("latency", "HTTPS P95 延迟", latencyMs, weight: 15) { 1 - max(0, $0 - 200) / 1800 }
        ]
    }
}

enum NodeUsabilityState: String, Sendable {
    case unknown, unavailable, timeoutProne, slow, usable

    var displayName: String {
        switch self {
        case .unknown: return "待检测"
        case .unavailable: return "不能用"
        case .timeoutProne: return "能用但容易超时"
        case .slow: return "能用但很慢"
        case .usable: return "能用"
        }
    }
}

struct NodeUsabilityAssessment: Equatable, Sendable {
    let state: NodeUsabilityState
    let detail: String
}

/// Bounded observations for one node and probe target during this app run.
/// HTTPS failures are request failures, not packet loss or WebSocket disconnects.
struct AIConnectionQuality {
    struct Sample {
        let latencyMs: Int?
        var timedOut = false
        var timeoutSeconds: TimeInterval? = nil
        var measuredAt = Date()
    }
    private(set) var samples: [Sample] = []
    private(set) var exitChanges = 0
    private(set) var exitObservations = 0
    var webSocket: WebSocketQualityResult?
    var datagrams: DatagramLossResult?
    private var lastExitID: String?

    mutating func record(latencyMs: Int?, timedOut: Bool = false, timeoutSeconds: TimeInterval? = nil,
                         at date: Date = Date()) {
        let latency = latencyMs.flatMap { $0 >= 0 ? $0 : nil }
        let budget = timeoutSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        samples.append(Sample(latencyMs: latency, timedOut: latency == nil && timedOut,
                              timeoutSeconds: budget, measuredAt: date))
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }

    var lastSampleAt: Date? { samples.map(\.measuredAt).max() }

    func freshObservations(settings: AppSettings, now: Date = Date()) -> Self {
        let ttl = TimeInterval(max(1, settings.testResultTTLMinutes)) * 60
        var fresh = self
        fresh.samples = samples.filter { (0...ttl).contains(now.timeIntervalSince($0.measuredAt)) }
        if let webSocket, !(0...ttl).contains(now.timeIntervalSince(webSocket.measuredAt)) {
            fresh.webSocket = nil
        }
        if let datagrams, !(0...ttl).contains(now.timeIntervalSince(datagrams.measuredAt)) {
            fresh.datagrams = nil
        }
        return fresh
    }

    func refreshNeeds(settings: AppSettings, now: Date = Date()) -> (webSocket: Bool, datagrams: Bool) {
        let fresh = freshObservations(settings: settings, now: now)
        let webSocket = fresh.webSocket.map {
            if $0.survivalRate == 1 { return false }
            return now.timeIntervalSince($0.measuredAt) >= 60
        } ?? true
        let datagrams = fresh.datagrams.map {
            if $0.lossRate != nil { return false }
            return now.timeIntervalSince($0.measuredAt) >= 60
        } ?? true
        return (webSocket, datagrams)
    }

    /// The caller supplies a salted identifier, never a raw IP.
    @discardableResult
    mutating func recordExit(identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        let changed = lastExitID.map { $0 != identifier } ?? false
        if changed { exitChanges += 1 }
        exitObservations += 1
        lastExitID = identifier
        return changed
    }

    var successCount: Int { samples.compactMap(\.latencyMs).count }
    var successRate: Double? {
        samples.isEmpty ? nil : Double(successCount) / Double(samples.count)
    }
    var p95LatencyMs: Double? {
        let sorted = samples.compactMap(\.latencyMs).sorted()
        guard !sorted.isEmpty else { return nil }
        return Double(sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)])
    }
    var jitterMs: Double? {
        let differences = zip(samples, samples.dropFirst()).compactMap { left, right -> Double? in
            guard let left = left.latencyMs, let right = right.latencyMs else { return nil }
            return abs(Double(left) - Double(right))
        }
        guard !differences.isEmpty else { return nil }
        return differences.reduce(0, +) / Double(differences.count)
    }
    func usability(settings: AppSettings, now: Date = Date()) -> NodeUsabilityAssessment {
        let recent = Array(freshObservations(settings: settings, now: now).samples
            .sorted { $0.measuredAt < $1.measuredAt }.suffix(20))
        guard !recent.isEmpty else {
            return .init(state: .unknown, detail: "尚无有效的连接检测结果，连接节点后会自动检查。")
        }
        let generousBudget = TimeInterval(max(15, min(99, settings.connectTimeoutSeconds)))
        let tail = recent.suffix(3)
        if tail.count == 3, tail.allSatisfy({ $0.latencyMs == nil && ($0.timeoutSeconds ?? 0) >= generousBudget }) {
            return .init(state: .unavailable,
                         detail: "最近 3 次检测均未成功，已使用至少 \(Int(generousBudget)) 秒的等待上限确认，持续无法使用时再按设置切换节点。")
        }
        let successful = recent.compactMap(\.latencyMs).sorted()
        guard !successful.isEmpty, recent.count >= 3 else {
            return .init(state: .unknown,
                         detail: "检测结果还不足以确认节点状态；短时检测失败会先增加等待时间，不直接判定不能用。")
        }
        let timeouts = recent.filter(\.timedOut).count
        if timeouts >= 2, Double(timeouts) / Double(recent.count) >= 0.2 {
            return .init(state: .timeoutProne,
                         detail: "最近 \(recent.count) 次检测中 \(successful.count) 次成功、\(timeouts) 次超时；节点仍能使用，会先延长等待并继续确认。")
        }
        if successful.count >= 3 {
            let middle = successful.count / 2
            let median = successful.count.isMultiple(of: 2)
                ? Double(successful[middle - 1]) / 2 + Double(successful[middle]) / 2 : Double(successful[middle])
            if median >= 2_000 {
                return .init(state: .slow,
                             detail: "最近成功请求的典型响应时间为 \(String(format: "%.1f", median / 1_000)) 秒；节点仍能使用，速度慢不会单独触发切换。")
            }
        }
        return .init(state: .usable,
                     detail: "最近 \(recent.count) 次检测中 \(successful.count) 次成功，暂未发现持续超时或明显缓慢。")
    }

    func score(for profile: AIQualityProfile, settings: AppSettings, now: Date = Date()) -> AINodeScore? {
        let score = AINodeScore.aggregate(scoringComponents(for: profile, settings: settings, now: now))
        return score.coverage > 0 ? score : nil
    }

    func scoringComponents(for profile: AIQualityProfile, settings: AppSettings, now: Date = Date()) -> [AINodeScoreComponent] {
        let fresh = freshObservations(settings: settings, now: now)
        let enabled = profile.isEnabled(in: settings)
        let hasHTTPS = enabled && fresh.samples.count >= 10
        let stream = enabled && profile == .codex ? fresh.webSocket : nil
        let streamTitle = stream?.survivalRate != nil && stream?.isLongObservation == false
            ? "WebSocket 快速连接检查" : profile.streamMetricName
        return AINodeScore.components(streamTitle: streamTitle,
            streamWeight: stream?.scoringWeight ?? 35,
            packetLossWeight: enabled ? fresh.datagrams?.scoringWeight ?? 15 : 15,
            longConnectionSurvival: stream?.survivalRate,
            packetLoss: enabled ? fresh.datagrams?.lossRate : nil,
            jitterMs: hasHTTPS ? fresh.jitterMs : nil,
            successRate: hasHTTPS ? fresh.successRate : nil,
            latencyMs: hasHTTPS ? fresh.p95LatencyMs : nil)
    }
}
