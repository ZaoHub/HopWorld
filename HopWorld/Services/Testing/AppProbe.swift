import Foundation

/// Popular overseas services probed through the current local proxy.
enum AppProbeTarget: Hashable, Identifiable, Codable, Sendable {
    case google
    case cloudflare
    case chatgpt
    case github
    case youtube
    case twitter
    case claude
    case tiktok

    case application(path: String, name: String, url: URL?)

    static let allCases: [Self] = [.google, .cloudflare, .chatgpt, .github, .youtube, .twitter, .claude, .tiktok]
    var id: String {
        switch self {
        case .application(let path, _, _): return path
        default: return displayName
        }
    }

    var displayName: String {
        switch self {
        case .application(_, let name, _): return name
        case .google: return "Google"
        case .cloudflare: return "Cloudflare"
        case .chatgpt: return "ChatGPT"
        case .github: return "GitHub"
        case .youtube: return "YouTube"
        case .twitter: return "X / Twitter"
        case .claude: return "Claude"
        case .tiktok: return "TikTok"
        }
    }

    /// 探测用端点：优先轻量/可匿名访问；ChatGPT 站点常对非浏览器返回 403，需配合「任意状态码即可达」。
    var probeURLs: [URL] {
        switch self {
        case .application(_, _, let url): return url.map { [$0] } ?? []
        case .google:
            return [
                URL(string: "https://www.google.com/generate_204")!,
                URL(string: "https://www.gstatic.com/generate_204")!
            ]
        case .cloudflare:
            return [
                URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!,
                URL(string: "https://1.1.1.1/cdn-cgi/trace")!
            ]
        case .chatgpt:
            return [
                URL(string: "https://chatgpt.com/cdn-cgi/trace")!,
                URL(string: "https://openai.com/cdn-cgi/trace")!,
                URL(string: "https://chatgpt.com/")!,
                URL(string: "https://chat.openai.com/")!
            ]
        case .github:
            return [
                URL(string: "https://github.com/")!,
                URL(string: "https://api.github.com/")!
            ]
        case .youtube:
            return [
                URL(string: "https://www.youtube.com/generate_204")!,
                URL(string: "https://www.youtube.com/")!
            ]
        case .twitter:
            return [
                URL(string: "https://x.com/")!,
                URL(string: "https://api.x.com/")!
            ]
        case .claude:
            return [
                URL(string: "https://claude.ai/cdn-cgi/trace")!,
                URL(string: "https://claude.ai/")!
            ]
        case .tiktok:
            return [
                URL(string: "https://www.tiktok.com/")!,
                URL(string: "https://www.tiktok.com/explore")!
            ]
        }
    }

    var probeURL: URL { probeURLs[0] }

    /// 概览「应用代理」卡片副标题（服务商）。
    var provider: String {
        switch self {
        case .application: return "自定义应用"
        case .google: return "Google"
        case .cloudflare: return "Cloudflare"
        case .chatgpt: return "OpenAI"
        case .github: return "GitHub"
        case .youtube: return "Google"
        case .twitter: return "X"
        case .claude: return "Anthropic"
        case .tiktok: return "ByteDance"
        }
    }
}

/// 网络健康中心「应用」页可诊断的 AI 应用；由「应用连通」中启用的目标决定。
enum HealthApplication: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex, claude, cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        }
    }

    var bundleIdentifiers: Set<String> {
        switch self {
        case .codex: return ["com.openai.codex"]
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        }
    }

    init?(target: AppProbeTarget) {
        switch target {
        case .chatgpt: self = .codex
        case .claude: self = .claude
        case .application(let path, let name, let url):
            let identifier = Bundle(path: path)?.bundleIdentifier ?? ""
            if let match = Self.allCases.first(where: { $0.bundleIdentifiers.contains(identifier) }) {
                self = match
                return
            }
            let text = [name, identifier, url?.host ?? ""].joined(separator: " ").lowercased()
            if text.contains("codex") || text.contains("chatgpt") || text.contains("openai") { self = .codex }
            else if text.contains("claude") || text.contains("anthropic") { self = .claude }
            else if text.contains("cursor") { self = .cursor }
            else { return nil }
        default:
            return nil
        }
    }

    func matches(_ application: ProxyApplication) -> Bool {
        if self == .claude, application.isClaude { return true }
        guard application.isBundle, let identifier = Bundle(path: application.path)?.bundleIdentifier else { return false }
        return bundleIdentifiers.contains(identifier)
    }
}

enum ClaudeModelAccess: Sendable {
    case available, regionBlocked, unreachable
}

extension AppSettings {
    /// 「应用连通」启用目标中可映射到 Codex / Claude / Cursor 的应用，按目标顺序去重。
    var healthApplications: [HealthApplication] {
        var seen = Set<HealthApplication>()
        return automaticAppProbeTargets.compactMap(HealthApplication.init(target:)).filter { seen.insert($0).inserted }
    }

    func healthTargets(for application: HealthApplication) -> [AppProbeTarget] {
        automaticAppProbeTargets.filter { HealthApplication(target: $0) == application }
    }
}

enum AppProbePhase: Equatable, Sendable {
    case idle
    case running
    case done
}

struct AppProbeBatchProgress {
    var isRunning = false
    var completed = 0
    var total = 0
    var connected = 0
    var failed = 0
    var statusText = ""
}

struct AppProbeResult: Identifiable, Equatable, Sendable {
    var id: String { target.id }
    var target: AppProbeTarget
    var status: Status
    var latencyMs: Int?
    var testedAt: Date?

    enum Status: Equatable, Sendable {
        case untested
        case testing
        case ok
        case failed
    }

    static func placeholder(_ target: AppProbeTarget) -> AppProbeResult {
        AppProbeResult(target: target, status: .untested, latencyMs: nil, testedAt: nil)
    }
}

enum AppProbeRunner {
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func probeAll(
        targets: [AppProbeTarget] = AppProbeTarget.allCases,
        proxyHost: String,
        httpPort: Int,
        socksPort: Int? = nil,
        timeout: TimeInterval = 4,
        onUpdate: @MainActor @escaping (AppProbeResult) -> Void
    ) async {
        // Refill a bounded pool instead of spawning a process for every configured app at once.
        await BatchProbeScheduler.run(targets, concurrency: 8) { target in
            await probeOne(
                target: target,
                proxyHost: proxyHost,
                httpPort: httpPort,
                socksPort: socksPort,
                timeout: timeout
            )
        } onResult: { result in
            onUpdate(result)
        }
    }

    static func probeOne(
        target: AppProbeTarget,
        proxyHost: String,
        httpPort: Int,
        socksPort: Int?,
        timeout: TimeInterval
    ) async -> AppProbeResult {
        guard !target.probeURLs.isEmpty else { return .placeholder(target) }
        var bestMs: Int?
        for url in target.probeURLs {
            if let ms = await ProxyHTTPTester.measure(
                proxyHost: proxyHost,
                proxyPort: httpPort,
                testURL: url,
                timeout: timeout,
                socksPort: socksPort,
                strict: true,
                singleURL: true,
                acceptAnyHTTPResponse: true,
                userAgent: browserUA
            ) {
                bestMs = ms
                break
            }
        }
        return AppProbeResult(
            target: target,
            status: bestMs != nil ? .ok : .failed,
            latencyMs: bestMs,
            testedAt: Date()
        )
    }
}

/// Persist the installed application and an explicit service endpoint together.
struct InstalledAppProbe: Codable, Hashable, Identifiable, Sendable {
    var application: ProxyApplication
    var endpoint: String
    var id: String { application.id }
    var target: AppProbeTarget? {
        guard let url = URL(string: endpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return .application(path: application.path, name: application.name, url: url)
    }
}

enum AppProbeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaults, rules, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .defaults: return "默认应用"
        case .rules: return "按应用代理名单"
        case .custom: return "自定义应用"
        }
    }
}

extension AppSettings {
    var effectiveAppProbeSource: AppProbeSource {
        appProbeSource ?? (proxyApplications.isEmpty ? .defaults : .rules)
    }
    /// 当前来源的全部目标（含概览「应用代理」中停用的），按用户排序。
    var allAppProbeTargets: [AppProbeTarget] {
        let targets = unorderedAppProbeTargets
        let order = appProbeOrder[effectiveAppProbeSource.rawValue] ?? []
        return targets.enumerated().sorted {
            let left = order.firstIndex(of: $0.element.id) ?? (order.count + $0.offset)
            let right = order.firstIndex(of: $1.element.id) ?? (order.count + $1.offset)
            return left < right
        }.map(\.element)
    }
    var automaticAppProbeTargets: [AppProbeTarget] {
        allAppProbeTargets.filter { !appProbeDisabledTargetIDs.contains($0.id) && !$0.probeURLs.isEmpty }
    }
    private var unorderedAppProbeTargets: [AppProbeTarget] {
        switch effectiveAppProbeSource {
        case .defaults: return AppProbeTarget.allCases
        case .rules: return ruleAppProbeTargets
        case .custom:
            return installedAppProbes.map {
                $0.target ?? .application(path: $0.application.path, name: $0.application.name, url: nil)
            }
        }
    }
    var ruleAppProbeTargets: [AppProbeTarget] {
        proxyApplications.map { application -> AppProbeTarget in
            if let configured = installedAppProbes.first(where: { $0.id == application.id }),
               let target = configured.target {
                return target
            }
            let identifier = Bundle(path: application.path)?.bundleIdentifier ?? ""
            let name = (application.name + " " + identifier).lowercased()
            let service: AppProbeTarget?
            if name.contains("chatgpt") || name.contains("openai") || name.contains("codex") { service = .chatgpt }
            else if name.contains("cursor") {
                return .application(path: application.path, name: application.name, url: URL(string: "https://cursor.com/"))
            }
            else if name.contains("github") { service = .github }
            else if name.contains("youtube") { service = .youtube }
            else if name.contains("twitter") { service = .twitter }
            else if name.contains("claude") || name.contains("anthropic") { service = .claude }
            else if name.contains("tiktok") { service = .tiktok }
            else if name.contains("cloudflare") { service = .cloudflare }
            else if name.contains("chrome") || name.contains("safari") || name.contains("firefox") { service = .google }
            else { service = nil }
            guard let service else { return .application(path: application.path, name: application.name, url: nil) }
            return .application(path: application.path, name: application.name, url: service.probeURL)
        }
    }
}
