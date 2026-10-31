import Foundation
import CryptoKit

enum SingBoxInstaller {
    static let version = "1.14.2"
    static let approvedVersion = "1.14.4"
    private static let selectedVersionKey = "singBox.selectedVersion"

    // Only application-pinned archives may become administrator-run TUN executables.
    static var selectedVersion: String {
        UserDefaults.standard.string(forKey: selectedVersionKey) == approvedVersion ? approvedVersion : version
    }

    static var installedVersion: String? {
        let selected = selectedVersion
        let cache = archiveURL(version: selected)
        return (try? digest(cache)) == expectedDigest(version: selected) ? selected : nil
    }

    static func expectedDigest(version requested: String) -> String {
        guard requested == approvedVersion else { return archiveSHA256 }
        #if arch(arm64)
        return "0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838"
        #else
        return "eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25"
        #endif
    }

    private static func archiveURL(version: String) -> URL {
        XrayInstaller.supportDirectory.appendingPathComponent("sing-box-\(version)-darwin-\(architecture).tar.gz")
    }

    static func installApprovedRelease(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-singbox-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try await prepare(in: directory, version: approvedVersion, onProgress: onProgress)
        try await validateCompatibility(binary: binary)
        try Task.checkCancellation()
        UserDefaults.standard.set(approvedVersion, forKey: selectedVersionKey)
    }

    static func validateCompatibility(binary: URL) async throws {
        let directory = binary.deletingLastPathComponent()
        let info = try await ProcessRunner.run(executable: binary, arguments: ["version"], timeout: 5)
        let text = String(decoding: info.output, as: UTF8.self)
        guard info.status == 0, !info.timedOut, !info.cancelled,
              text.split(whereSeparator: \.isWhitespace).contains(Substring(approvedVersion)) else {
            throw ApplicationProxyError.failed("sing-box 版本或架构校验失败。")
        }
        let app = try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))
        var configs: [[String: Any]] = try [false, true].map {
            try ApplicationProxyConfig.build(applications: [app], socksPort: 12001, password: "compatibility-check",
                bypassExecutables: [binary.path], captureAll: $0, bootstrapDomains: ["node.example"])
        }
        var nodes = [
            ProxyNode(name: "VLESS", protocolType: .vless, server: "node.example", port: 443,
                      uuid: "11111111-1111-4111-8111-111111111111"),
            ProxyNode(name: "TUIC", protocolType: .tuic, server: "node.example", port: 443,
                      uuid: "11111111-1111-4111-8111-111111111111", password: "fixture", security: .tls),
            ProxyNode(name: "AnyTLS", protocolType: .anytls, server: "node.example", port: 443,
                      password: "fixture", security: .tls, sni: "tls.example", fingerprint: "chrome", alpn: "http/1.1", allowInsecure: true),
            ProxyNode(name: "Hysteria2", protocolType: .hysteria2, server: "node.example", port: 443,
                      password: "fixture", security: .tls, allowInsecure: true),
            ProxyNode(name: "Shadowsocks", protocolType: .shadowsocks, server: "node.example", port: 443,
                      password: "fixture", method: "rc4-md5")
        ]
        for transport in [TransportType.ws, .grpc, .httpupgrade, .h2, .http] {
            var node = nodes[0]
            node.transport = transport
            node.path = "/compatibility"
            node.serviceName = "compatibility"
            nodes.append(node)
        }
        for protocolType in [ProxyProtocolType.vmess, .trojan] {
            var node = nodes[0]
            node.protocolType = protocolType
            node.transport = .h2
            node.password = "fixture"
            nodes.append(node)
        }
        for method in SingBoxConnectionConfig.legacyShadowsocksMethods.sorted() where method != "rc4-md5" {
            nodes.append(ProxyNode(name: method, protocolType: .shadowsocks, server: "node.example", port: 443,
                                   password: "fixture", method: method))
        }
        configs.append([
            "dns": ["servers": [["type": "local", "tag": "local-dns"]]],
            "route": ["default_domain_resolver": "local-dns"],
            "outbounds": try nodes.enumerated().map { index, node -> [String: Any] in
                var outbound = try SingBoxConnectionConfig.outbound(node)
                outbound["tag"] = "check-\(index)"
                return outbound
            }
        ])
        for (index, config) in configs.enumerated() {
            let file = directory.appendingPathComponent("compatibility-\(index).json")
            try XrayConfigBuilder.writeJSON(config, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try await ProcessRunner.run(executable: binary, arguments: ["check", "-c", file.path], timeout: 15)
            guard result.status == 0, !result.timedOut, !result.cancelled else {
                throw ApplicationProxyError.failed("sing-box 配置兼容性检查失败：" + String(decoding: result.output.prefix(1200), as: UTF8.self))
            }
        }
    }
    #if arch(arm64)
    static let architecture = "arm64"
    static let archiveSHA256 = "925c5382eca8492b0150f868a6db20b18290a38700e621724b3703fd453e032d"
    #else
    static let architecture = "amd64"
    static let archiveSHA256 = "b0bfb0dc70a5fc708710b9f5ea98b9ee76d40fa4169928d25d73edc4331df2fe"
    #endif

    static func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// Always extract from a hash-verified release archive; never elevate an
    /// arbitrary binary found on PATH or trust a user-writable hash receipt.
    static func prepare(in directory: URL) async throws -> URL {
        try await prepare(in: directory, version: selectedVersion)
    }

    static func prepare(
        in directory: URL,
        version: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let folder = "sing-box-\(version)-darwin-\(architecture)"
        let cache = archiveURL(version: version)
        let expected = expectedDigest(version: version)
        if (try? digest(cache)) != expected {
            let url = URL(string: "https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(folder).tar.gz")!
            let (download, response) = try await XrayInstaller.downloadFile(
                from: XrayInstaller.preferredDownloadMirror.rewrite(url),
                timeoutRequest: 20,
                timeoutResource: 120,
                onProgress: onProgress
            )
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, try digest(download) == expected else {
                throw ApplicationProxyError.failed("sing-box 下载失败或 SHA-256 校验不符，未启动管理员进程。")
            }
            onProgress?(1)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: download).write(to: cache, options: .atomic)
        } else {
            onProgress?(1)
        }
        // Copy the validated bytes first, then verify that private snapshot to
        // close the cache replacement race before archive extraction.
        let archive = directory.appendingPathComponent("release.tar.gz")
        try Data(contentsOf: cache).write(to: archive, options: .atomic)
        guard try digest(archive) == expected else { throw ApplicationProxyError.failed("核心缓存校验失败。") }
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", directory.path, "\(folder)/sing-box", "\(folder)/LICENSE"], timeout: 20)
        guard result.status == 0, !result.timedOut, !result.cancelled else {
            throw ApplicationProxyError.failed("解压 sing-box 失败。")
        }
        return directory.appendingPathComponent(folder).appendingPathComponent("sing-box")
    }
}
