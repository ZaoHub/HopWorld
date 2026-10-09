import Foundation

/// Popular overseas services probed through the current local proxy.
enum AppProbeTarget: Hashable, Identifiable, Codable, Sendable {
    case google
    case cloudflare
    case chatgpt
    case github
    case youtube
    case twitter

    case application(path: String, name: String, url: URL?)

    static let allCases: [Self] = [.google, .cloudflare, .chatgpt, .github, .youtube, .twitter]
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
        }
    }

    var probeURL: URL { probeURLs[0] }
}

enum AppProbePhase: Equatable, Sendable {
    case idle
    case running
    case done
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
        await withTaskGroup(of: AppProbeResult.self) { group in
            for target in targets {
                group.addTask {
                    await probeOne(
                        target: target,
                        proxyHost: proxyHost,
                        httpPort: httpPort,
                        socksPort: socksPort,
                        timeout: timeout
                    )
                }
            }
            for await result in group {
                await onUpdate(result)
            }
        }
    }

    static func probeOne(
        target: AppProbeTarget,
        proxyHost: String,
        httpPort: Int,
        socksPort: Int?,
        timeout: TimeInterval
    ) async -> AppProbeResult {
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
        case .rules: return "规则代理应用"
        case .custom: return "自定义应用"
        }
    }
}

extension AppSettings {
    var effectiveAppProbeSource: AppProbeSource {
        appProbeSource ?? (proxyApplications.isEmpty ? .defaults : .rules)
    }
    var automaticAppProbeTargets: [AppProbeTarget] {
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
            if let configured = installedAppProbes.first(where: { $0.id == application.id }) {
                return configured.target ?? .application(path: application.path, name: application.name, url: nil)
            }
            let identifier = Bundle(path: application.path)?.bundleIdentifier ?? ""
            let name = (application.name + " " + identifier).lowercased()
            let service: AppProbeTarget?
            if name.contains("chatgpt") || name.contains("openai") || name.contains("codex") { service = .chatgpt }
            else if name.contains("github") { service = .github }
            else if name.contains("youtube") { service = .youtube }
            else if name.contains("twitter") { service = .twitter }
            else if name.contains("cloudflare") { service = .cloudflare }
            else if name.contains("chrome") || name.contains("safari") || name.contains("firefox") { service = .google }
            else { service = nil }
            guard let service else { return .application(path: application.path, name: application.name, url: nil) }
            return .application(path: application.path, name: application.name, url: service.probeURL)
        }
    }
}
