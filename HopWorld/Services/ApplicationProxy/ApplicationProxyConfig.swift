import Foundation

enum ApplicationProxyConfig {
    static func build(applications: [ProxyApplication], socksPort: Int, password: String,
                      bypassExecutables: [String], captureAll: Bool = false,
                      bootstrapDomains: [String] = []) throws -> [String: Any] {
        guard captureAll || !applications.isEmpty else { throw ApplicationProxyError.invalid("请先选择至少一个代理应用。") }
        guard (1...65535).contains(socksPort), !password.isEmpty else {
            throw ApplicationProxyError.invalid("应用代理本地入口无效。")
        }
        if !captureAll {
            for application in applications { try application.validate() }
        }
        var config: [String: Any] = [
            "log": ["level": "info", "timestamp": false, "disabled": false],
            "inbounds": [[
                "type": "tun", "tag": "application-tun",
                // Leave interface_name unset: the OS allocates a free utun.
                "address": ["172.31.255.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 1500, "auto_route": true, "stack": "system",
                // macOS shares its resolver across apps; a node failure must not break local DNS.
                "dns_mode": "disabled"
            ] as [String: Any]],
            "outbounds": [
                ["type": "direct", "tag": "direct"],
                ["type": "socks", "tag": "selected-apps", "server": "127.0.0.1",
                 "server_port": socksPort, "version": "5", "username": "hopworld",
                 "password": password, "bind_interface": "lo0",
                 "tcp_keep_alive": "30s", "tcp_keep_alive_interval": "15s"]
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "direct",
                "rules": [
                    // Must precede the whitelist, including when HopWorld itself
                    // was selected. Prevent Xray → TUN → Xray recursion.
                    ["process_path": Array(Set(bypassExecutables)).sorted(), "action": "route", "outbound": "direct"],
                    ["port": [53], "action": "route", "outbound": "direct"],
                    ["ip_is_private": true, "action": "route", "outbound": "direct"],
                    ["process_path_regex": Array(Set(applications.map(\.pathRegex))).sorted(),
                     "action": "route", "outbound": "selected-apps"]
                ] as [[String: Any]]
            ] as [String: Any]
        ]
        if captureAll {
            // No process whitelist or private-address fallback in global mode.
            // Proxy cores bypass to prevent recursion; HopWorld is also bypassed
            // so subscription updates stay independent of the current node.
            var tun = (config["inbounds"] as! [[String: Any]])[0]
            tun["tag"] = "global-tun"
            tun["dns_mode"] = "hijack"
            config["inbounds"] = [tun]
            config["route"] = [
                "auto_detect_interface": true,
                "default_domain_resolver": "remote-dns",
                "final": "selected-apps",
                "rules": [
                    ["process_path": Array(Set(bypassExecutables)).sorted(), "action": "route", "outbound": "direct"],
                    ["port": [53], "action": "hijack-dns"]
                ] as [[String: Any]]
            ] as [String: Any]
        }
        guard captureAll else { return config }
        // Bootstrap only the node hostname outside the proxy. Resolving it
        // through Xray itself after a DNS cache expiry would deadlock.
        var dns: [String: Any] = [
            "servers": [
                ["type": "tcp", "tag": "remote-dns", "server": "1.1.1.1", "detour": "selected-apps"],
                // DNS dialers are direct by default; an explicit detour to
                // an empty direct outbound is rejected during core startup.
                ["type": "udp", "tag": "bootstrap-dns", "server": "223.5.5.5"]
            ],
            "final": "remote-dns",
            "strategy": "prefer_ipv4"
        ]
        if !bootstrapDomains.isEmpty {
            dns["rules"] = [["domain": bootstrapDomains, "action": "route", "server": "bootstrap-dns"]]
        }
        config["dns"] = dns
        return config
    }
}
