import Foundation

enum SystemProxyError: LocalizedError, Sendable {
    case noNetworkService
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noNetworkService: return "未找到可用网络服务"
        case .commandFailed(let message): return message
        }
    }
}

/// System proxy changes shell out to `networksetup` — always off the main thread
/// so connect/disconnect never beach-balls the UI.
struct SystemProxyManager: Sendable {
    private let backupURL: URL
    private let commandRunner: @Sendable (String, [String]) async throws -> String

    init(backupURL: URL? = nil, commandRunner: (@Sendable (String, [String]) async throws -> String)? = nil) {
        self.commandRunner = commandRunner ?? { path, arguments in
            try await Self.runCommand(path, arguments: arguments)
        }
        if let backupURL { self.backupURL = backupURL; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HopWorld", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.backupURL = support.appendingPathComponent("proxy-backup.json")
    }

    func activeNetworkServices() async throws -> [String] {
        let output = try await run("/usr/sbin/networksetup", arguments: ["-listallnetworkservices"])
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
    }

    func backupCurrentSettings() async throws -> [OriginalProxySettings] {
        let backups = try await readCurrentSettings(services: activeNetworkServices())
        let data = try JSONEncoder().encode(backups)
        try data.write(to: backupURL, options: .atomic)
        return backups
    }

    private func readCurrentSettings(services: [String]) async throws -> [OriginalProxySettings] {
        var backups: [OriginalProxySettings] = []

        for service in services {
            let http = try await readProxy(service: service, type: "webproxy")
            let https = try await readProxy(service: service, type: "securewebproxy")
            let socks = try await readProxy(service: service, type: "socksfirewallproxy")
            let auto = try await readAutoProxy(service: service)
            let bypass = try await run("/usr/sbin/networksetup", arguments: ["-getproxybypassdomains", service])
            let discovery = try await run("/usr/sbin/networksetup", arguments: ["-getproxyautodiscovery", service])

            backups.append(
                OriginalProxySettings(
                    serviceName: service,
                    httpEnabled: http.enabled,
                    httpHost: http.host,
                    httpPort: http.port,
                    httpsEnabled: https.enabled,
                    httpsHost: https.host,
                    httpsPort: https.port,
                    socksEnabled: socks.enabled,
                    socksHost: socks.host,
                    socksPort: socks.port,
                    autoProxyEnabled: auto.enabled,
                    autoProxyURL: auto.url,
                    bypassDomains: bypass.lowercased().contains("there aren't any") ? [] :
                        bypass.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    autoDiscoveryEnabled: discovery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("on")
                )
            )
        }

        return backups
    }

    func enableSystemProxy(httpHost: String, httpPort: Int, socksHost: String, socksPort: Int) async throws {
        let services = try await activeNetworkServices()
        guard !services.isEmpty else { throw SystemProxyError.noNetworkService }
        var backups: [OriginalProxySettings] = []
        if FileManager.default.fileExists(atPath: backupURL.path) {
            backups = try JSONDecoder().decode([OriginalProxySettings].self, from: Data(contentsOf: backupURL))
        }
        // Network changes can introduce a new service mid-session. Back up only
        // that service before touching it; never overwrite the original settings.
        let known = Set(backups.map(\.serviceName))
        let added = services.filter { !known.contains($0) }
        if !added.isEmpty {
            backups += try await readCurrentSettings(services: added)
            try JSONEncoder().encode(backups).write(to: backupURL, options: .atomic)
        }
        let bypass = [
            "127.0.0.1", "localhost", "*.local", "0.0.0.0",
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
            "*.crashlytics.com"
        ]

        do {
            for service in services {
                try Task.checkCancellation()
                // PAC can override manual proxies and send traffic elsewhere — disable while HopWorld is on.
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setautoproxystate", service, "off"])
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setproxyautodiscovery", service, "off"])

                _ = try await run("/usr/sbin/networksetup", arguments: [
                    "-setwebproxy", service, httpHost, "\(httpPort)"
                ])
                _ = try await run("/usr/sbin/networksetup", arguments: [
                    "-setsecurewebproxy", service, httpHost, "\(httpPort)"
                ])
                // Browsers use HTTP(S) proxy (CONNECT). Keep SOCKS for non-HTTP apps.
                _ = try await run("/usr/sbin/networksetup", arguments: [
                    "-setsocksfirewallproxy", service, socksHost, "\(socksPort)"
                ])
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setwebproxystate", service, "on"])
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setsecurewebproxystate", service, "on"])
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setsocksfirewallproxystate", service, "on"])

                var bypassArgs = ["-setproxybypassdomains", service]
                bypassArgs.append(contentsOf: bypass)
                _ = try? await run("/usr/sbin/networksetup", arguments: bypassArgs)
            }
        } catch {
            // A failure half way through the service list must not leave some active
            // interfaces pointing at a local proxy that is about to be stopped.
            try? await restoreFromBackup()
            throw error
        }
    }

    func matchesSystemProxy(httpHost: String, httpPort: Int, socksHost: String, socksPort: Int) async throws -> Bool {
        let services = try await activeNetworkServices()
        guard !services.isEmpty else { return false }
        for service in services {
            let http = try await readProxy(service: service, type: "webproxy")
            let https = try await readProxy(service: service, type: "securewebproxy")
            let socks = try await readProxy(service: service, type: "socksfirewallproxy")
            guard http.enabled, http.host == httpHost, http.port == httpPort,
                  https.enabled, https.host == httpHost, https.port == httpPort,
                  socks.enabled, socks.host == socksHost, socks.port == socksPort else { return false }
            if try await readAutoProxy(service: service).enabled { return false }
            let discovery = try await run("/usr/sbin/networksetup", arguments: ["-getproxyautodiscovery", service])
            if discovery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("on") { return false }
        }
        return true
    }

    func restoreFromBackup() async throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
        let data = try Data(contentsOf: backupURL)
        let backups = try JSONDecoder().decode([OriginalProxySettings].self, from: data)

        for backup in backups {
            try await apply(backup)
        }
        // A completed restore ends the proxy session. Removing the file prevents a
        // later VPN-only disconnect from applying an unrelated, stale snapshot.
        try FileManager.default.removeItem(at: backupURL)
    }

    /// TUN whitelist cannot make other apps direct if they already send their
    /// traffic to a third-party HTTP/SOCKS/PAC proxy. Refuse, don't overwrite it.
    func requireDirectSystemSettings() async throws {
        for service in try await activeNetworkServices() {
            try Task.checkCancellation()
            for type in ["webproxy", "securewebproxy", "socksfirewallproxy"] {
                if try await readProxy(service: service, type: type).enabled {
                    throw ApplicationProxyError.invalid("\(service) 仍启用了系统代理。请关闭其他代理软件的系统代理后再使用应用白名单。")
                }
            }
            if try await readAutoProxy(service: service).enabled {
                throw ApplicationProxyError.invalid("\(service) 仍启用了 PAC。请先关闭自动代理配置。")
            }
            let discovery = try await run("/usr/sbin/networksetup", arguments: ["-getproxyautodiscovery", service])
            if discovery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("on") {
                throw ApplicationProxyError.invalid("\(service) 仍启用了代理自动发现。请先关闭此设置。")
            }
        }
    }

    /// 当前已启用的系统代理，供网络工具展示。
    func enabledProxySummary() async throws -> [String] {
        var lines: [String] = []
        for service in try await activeNetworkServices() {
            for (label, type) in [("HTTP", "webproxy"), ("HTTPS", "securewebproxy"), ("SOCKS", "socksfirewallproxy")] {
                let proxy = try await readProxy(service: service, type: type)
                if proxy.enabled {
                    lines.append("\(service)：\(label) \(proxy.host ?? "-"):\(proxy.port.map(String.init) ?? "-")")
                }
            }
            let auto = try await readAutoProxy(service: service)
            if auto.enabled {
                lines.append("\(service)：PAC \(auto.url ?? "")")
            }
        }
        return lines
    }

    /// 供修复前弹窗说明：备份文件路径，以及文件里记下的代理。
    func backupDeletionDescription() -> String {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return "当前没有代理备份文件。选择「删除备份」不会删除其它文件。"
        }
        var lines = ["选择「删除备份」会删除这个文件：", backupURL.path]
        if let data = try? Data(contentsOf: backupURL),
           let backups = try? JSONDecoder().decode([OriginalProxySettings].self, from: data),
           !backups.isEmpty {
            lines.append("文件中记录的是连接前的系统代理：")
            lines.append(contentsOf: backups.flatMap(Self.backupLines(for:)))
        } else {
            lines.append("文件无法读取。删除时仍只移除这一份。")
        }
        lines.append("选择「保留备份」不会删除该文件。")
        return lines.joined(separator: "\n")
    }

    /// 先按备份恢复系统代理，再关闭仍指向本机的项。仅在要求删除时移除备份文件。
    func repairLoopbackProxies(deleteBackup: Bool) async throws -> Int {
        if FileManager.default.fileExists(atPath: backupURL.path),
           let data = try? Data(contentsOf: backupURL),
           let backups = try? JSONDecoder().decode([OriginalProxySettings].self, from: data) {
            for backup in backups {
                try await apply(backup)
            }
        }
        let turnedOff = try await disableLoopbackProxies()
        if deleteBackup, FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        return turnedOff
    }

    private static func backupLines(for settings: OriginalProxySettings) -> [String] {
        func endpoint(_ enabled: Bool, _ host: String?, _ port: Int?) -> String {
            guard enabled else { return "关" }
            return "\(host ?? "-"):\(port.map(String.init) ?? "-")"
        }
        var lines = ["· \(settings.serviceName)"]
        lines.append("  HTTP \(endpoint(settings.httpEnabled, settings.httpHost, settings.httpPort))")
        lines.append("  HTTPS \(endpoint(settings.httpsEnabled, settings.httpsHost, settings.httpsPort))")
        lines.append("  SOCKS \(endpoint(settings.socksEnabled, settings.socksHost, settings.socksPort))")
        if settings.autoProxyEnabled {
            lines.append("  PAC \(settings.autoProxyURL ?? "")")
        }
        return lines
    }

    /// 只关闭指向本机回环的 HTTP/HTTPS/SOCKS，不改用户设到其它地址的代理。
    func disableLoopbackProxies() async throws -> Int {
        var turnedOff = 0
        for service in try await activeNetworkServices() {
            let http = try await readProxy(service: service, type: "webproxy")
            if http.enabled, Self.isLoopback(http.host) {
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setwebproxystate", service, "off"])
                turnedOff += 1
            }
            let https = try await readProxy(service: service, type: "securewebproxy")
            if https.enabled, Self.isLoopback(https.host) {
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setsecurewebproxystate", service, "off"])
                turnedOff += 1
            }
            let socks = try await readProxy(service: service, type: "socksfirewallproxy")
            if socks.enabled, Self.isLoopback(socks.host) {
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setsocksfirewallproxystate", service, "off"])
                turnedOff += 1
            }
        }
        return turnedOff
    }

    private static func isLoopback(_ host: String?) -> Bool {
        switch host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "127.0.0.1", "localhost", "::1": return true
        default: return false
        }
    }

    func restoreIfOrphaned(expectedHTTPPort: Int, expectedSOCKSPort: Int, xrayRunning: Bool) async throws {
        guard !xrayRunning else { return }
        let services = try await activeNetworkServices()

        var orphaned = false
        for service in services {
            let http = try await readProxy(service: service, type: "webproxy")
            let https = try await readProxy(service: service, type: "securewebproxy")
            let socks = try await readProxy(service: service, type: "socksfirewallproxy")
            if http.enabled && http.host == "127.0.0.1" && http.port == expectedHTTPPort {
                orphaned = true
            }
            if https.enabled && https.host == "127.0.0.1" && https.port == expectedHTTPPort {
                orphaned = true
            }
            if socks.enabled && socks.host == "127.0.0.1" && socks.port == expectedSOCKSPort {
                orphaned = true
            }
        }

        guard orphaned else { return }

        // Prefer restoring the pre-HopWorld backup; if backup itself still points at us, force off.
        try? await restoreFromBackup()

        for service in services {
            let http = try await readProxy(service: service, type: "webproxy")
            let https = try await readProxy(service: service, type: "securewebproxy")
            let socks = try await readProxy(service: service, type: "socksfirewallproxy")

            if http.enabled && http.host == "127.0.0.1" && http.port == expectedHTTPPort {
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setwebproxystate", service, "off"])
            }
            if https.enabled && https.host == "127.0.0.1" && https.port == expectedHTTPPort {
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setsecurewebproxystate", service, "off"])
            }
            if socks.enabled && socks.host == "127.0.0.1" && socks.port == expectedSOCKSPort {
                _ = try await run("/usr/sbin/networksetup", arguments: ["-setsocksfirewallproxystate", service, "off"])
            }
        }
    }

    func isPointingToHopWorld(httpPort: Int, socksPort: Int) async throws -> Bool {
        try await isPointingToHopWorld(
            httpHost: "127.0.0.1",
            httpPort: httpPort,
            socksHost: "127.0.0.1",
            socksPort: socksPort
        )
    }

    private func isPointingToHopWorld(
        httpHost: String,
        httpPort: Int,
        socksHost: String,
        socksPort: Int
    ) async throws -> Bool {
        let services = try await activeNetworkServices()
        for service in services {
            let http = try await readProxy(service: service, type: "webproxy")
            let https = try await readProxy(service: service, type: "securewebproxy")
            let socks = try await readProxy(service: service, type: "socksfirewallproxy")
            if http.enabled && http.host == httpHost && http.port == httpPort { return true }
            if https.enabled && https.host == httpHost && https.port == httpPort { return true }
            if socks.enabled && socks.host == socksHost && socks.port == socksPort { return true }
        }
        return false
    }

    private func apply(_ backup: OriginalProxySettings) async throws {
        let service = backup.serviceName

        if let host = backup.httpHost, let port = backup.httpPort {
            _ = try await run("/usr/sbin/networksetup", arguments: ["-setwebproxy", service, host, "\(port)"])
        }
        _ = try await run("/usr/sbin/networksetup", arguments: [
            "-setwebproxystate", service, backup.httpEnabled ? "on" : "off"
        ])

        if let host = backup.httpsHost, let port = backup.httpsPort {
            _ = try await run("/usr/sbin/networksetup", arguments: ["-setsecurewebproxy", service, host, "\(port)"])
        }
        _ = try await run("/usr/sbin/networksetup", arguments: [
            "-setsecurewebproxystate", service, backup.httpsEnabled ? "on" : "off"
        ])

        if let host = backup.socksHost, let port = backup.socksPort {
            _ = try await run("/usr/sbin/networksetup", arguments: ["-setsocksfirewallproxy", service, host, "\(port)"])
        }
        _ = try await run("/usr/sbin/networksetup", arguments: [
            "-setsocksfirewallproxystate", service, backup.socksEnabled ? "on" : "off"
        ])

        if let url = backup.autoProxyURL, !url.isEmpty {
            _ = try await run("/usr/sbin/networksetup", arguments: ["-setautoproxyurl", service, url])
        }
        _ = try await run("/usr/sbin/networksetup", arguments: [
            "-setautoproxystate", service, backup.autoProxyEnabled ? "on" : "off"
        ])
        if let domains = backup.bypassDomains {
            _ = try await run("/usr/sbin/networksetup", arguments:
                ["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains))
        }
        if let enabled = backup.autoDiscoveryEnabled {
            _ = try await run("/usr/sbin/networksetup", arguments: ["-setproxyautodiscovery", service, enabled ? "on" : "off"])
        }
    }

    private func readProxy(service: String, type: String) async throws -> (enabled: Bool, host: String?, port: Int?) {
        let output = try await run("/usr/sbin/networksetup", arguments: ["-get\(type)", service])
        let lines = output.components(separatedBy: .newlines)
        var enabled = false
        var host: String?
        var port: Int?

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("enabled:") {
                enabled = lower.contains("yes")
            } else if lower.hasPrefix("server:") {
                host = line.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("port:") {
                port = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
            }
        }
        return (enabled, host, port)
    }

    private func readAutoProxy(service: String) async throws -> (enabled: Bool, url: String?) {
        let output = try await run("/usr/sbin/networksetup", arguments: ["-getautoproxyurl", service])
        var enabled = false
        var url: String?
        for line in output.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.hasPrefix("enabled:") {
                enabled = lower.contains("yes")
            } else if lower.hasPrefix("url:") {
                url = line.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return (enabled, url)
    }

    /// Commands have a hard deadline; rollback is shielded from cancellation.
    @discardableResult
    private func run(_ launchPath: String, arguments: [String]) async throws -> String {
        try await commandRunner(launchPath, arguments)
    }

    private static func runCommand(_ launchPath: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: launchPath),
                                                    arguments: arguments, timeout: 5)
            let text = String(decoding: result.output, as: UTF8.self)
            guard result.status == 0, !result.timedOut else {
                throw SystemProxyError.commandFailed(result.timedOut ? "networksetup 执行超时" : text)
            }
            return text
        }.value
    }
}
