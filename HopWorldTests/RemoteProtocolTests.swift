import XCTest
import CryptoKit

@MainActor
final class RemoteProtocolTests: XCTestCase {
    private let uuid = "11111111-1111-4111-8111-111111111111"
    private func wgNode(server: String = "example.com", port: Int = 51820) -> ProxyNode {
        ProxyNode(name: "WG fixture", protocolType: .wireguard, server: server, port: port,
                  wireGuardOptions: WireGuardOptions(privateKey: Data(repeating: 3, count: 32).base64EncodedString(),
                    addresses: ["10.88.0.2/32", "fd88::2/128"], peerPublicKey: Data(repeating: 5, count: 32).base64EncodedString(),
                    preSharedKey: Data(repeating: 7, count: 32).base64EncodedString(), allowedIPs: ["0.0.0.0/0", "::/0"],
                    reserved: [0, 1, 255], mtu: 1420, keepAlive: 25, remoteDNS: ["1.1.1.1"]))
    }

    func testAnyTLSLinksYAMLAndTLSParametersRoundTrip() throws {
        let link = "anytls://p%2540%3A%40@example.com:443?insecure=1&security=tls&sni=tls.example.com&fp=chrome&alpn=h2%2Chttp%2F1.1&type=tcp&headerType=none#%E6%B5%8B%E8%AF%95"
        for body in [link, Data(link.utf8).base64EncodedString()] {
            let node = try XCTUnwrap(SubscriptionContentParser.parse(data: Data(body.utf8)).validNodes.first)
            XCTAssertEqual(node.protocolType, .anytls)
            XCTAssertEqual(node.password, "p%40:@")
            XCTAssertEqual(node.sni, "tls.example.com")
            XCTAssertEqual(node.name, "测试")
            XCTAssertEqual(node.allowInsecure, true)
            XCTAssertEqual(node.fingerprint, "chrome")
            XCTAssertEqual(node.alpn, "h2,http/1.1")
            XCTAssertFalse(node.usesUDPTransport)
            XCTAssertTrue(NodeConfigChecker.validate(node).0)
            XCTAssertTrue(SingBoxConnectionConfig.requiresSingBox(node))
            let outbound = try SingBoxConnectionConfig.outbound(node)
            XCTAssertEqual(outbound["type"] as? String, "anytls")
            XCTAssertEqual(outbound["password"] as? String, "p%40:@")
            let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
            XCTAssertEqual(tls["server_name"] as? String, "tls.example.com")
            XCTAssertEqual(tls["insecure"] as? Bool, true)
            XCTAssertEqual(tls["alpn"] as? [String], ["h2", "http/1.1"])
            XCTAssertEqual((tls["utls"] as? [String: Any])?["fingerprint"] as? String, "chrome")
            let exported = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: node))
            let restored = try NodeLinkParser.parse(exported)
            XCTAssertEqual(NodeFingerprint.make(from: restored), NodeFingerprint.make(from: node))
            XCTAssertEqual(try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node)), node)
            XCTAssertFalse(LogRedactor.redact(exported).contains("p%2540"))
            XCTAssertFalse(LogRedactor.redact(exported).contains("example.com"))
        }
        let yaml = """
        proxies:
          - {name: AnyTLS, type: anytls, server: example.com, port: 443, password: 'p%40:@', sni: tls.example.com, skip-cert-verify: true, client-fingerprint: chrome, alpn: [h2, http/1.1], udp: true}
        """
        let node = try XCTUnwrap(ClashYAMLParser.parse(yaml).validNodes.first)
        XCTAssertEqual(NodeFingerprint.make(from: node), NodeFingerprint.make(from: try NodeLinkParser.parse(link)))
        let defaultNode = try NodeLinkParser.parse("anytls://fixture@[::1]#Default")
        XCTAssertEqual(defaultNode.port, 443)
        XCTAssertEqual(defaultNode.server, "::1")
        let tls = try XCTUnwrap(SingBoxConnectionConfig.outbound(defaultNode)["tls"] as? [String: Any])
        XCTAssertEqual(tls["insecure"] as? Bool, false)
        XCTAssertNil(tls["utls"])
    }

    func testAnyTLSRejectsUnsupportedOptionsAndTracksTLSChanges() throws {
        let prefix = "anytls://fixture@example.com:443"
        for suffix in ["?security=none", "?type=ws", "?headerType=http", "?insecure=maybe", "?insecure=1&insecure=0", "?insecure=1&allowInsecure=0",
                       "?alpn=", "?ech=unsupported", "?idle_session_timeout=10s", "?pinSHA256=ignored", "/path"] {
            XCTAssertThrowsError(try NodeLinkParser.parse(prefix + suffix), suffix)
        }
        XCTAssertThrowsError(try NodeLinkParser.parse("anytls://example.com:443"))
        XCTAssertThrowsError(try ClashYAMLParser.parse("proxies: [{type: anytls, server: example.com, port: 443, password: fixture, tls: false}]"))
        let node = try NodeLinkParser.parse(prefix)
        for query in ["?insecure=1", "?fp=chrome", "?alpn=http%2F1.1", "?sni=tls.example"] {
            XCTAssertNotEqual(NodeFingerprint.make(from: node), NodeFingerprint.make(from: try NodeLinkParser.parse(prefix + query)))
        }
        var missing = node
        missing.password = nil
        XCTAssertFalse(NodeConfigChecker.validate(missing, loadCredential: { _ in nil }).0)
        XCTAssertThrowsError(try SingBoxConnectionConfig.outbound(missing))
    }

    func testAnyTLSBackupAndCredentialRotation() throws {
        var old = try NodeLinkParser.parse("anytls://old-password@example.com:443#Stable")
        old.isFavorite = true
        old.credentialKey = "old-key-reference"
        let incoming = try NodeLinkParser.parse("anytls://new-password@example.com:443?insecure=1&fp=chrome#Stable")
        let merged = try XCTUnwrap(SubscriptionMerger.buildPlan(mode: .smartMerge, oldNodes: [old], newNodes: [incoming], missingLimit: 3).resultingNodes.first)
        XCTAssertEqual(merged.id, old.id)
        XCTAssertTrue(merged.isFavorite)
        XCTAssertEqual(merged.password, "new-password")
        XCTAssertNil(merged.credentialKey)
        XCTAssertEqual(merged.allowInsecure, true)
        let snapshot = LibrarySnapshot(nodes: [incoming])
        let redacted = try LibraryBackup.export(snapshot: snapshot, passphrase: "fixture", includeCredentials: false)
        XCTAssertNil(try LibraryBackup.importBackup(from: redacted, passphrase: "fixture").nodes.first?.password)
        let full = try LibraryBackup.export(snapshot: snapshot, passphrase: "fixture", includeCredentials: true)
        XCTAssertEqual(try LibraryBackup.importBackup(from: full, passphrase: "fixture").nodes.first, incoming)
        var stored = incoming
        stored.password = nil
        stored.credentialKey = "fixture-key"
        KeychainStore.hydrateCredentials(&stored, loadCredential: { _ in #"{"password":"restored-password"}"# })
        XCTAssertEqual(stored.password, "restored-password")
    }

    func testAnyTLSCoreConfigCompatibility() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodes = try ["anytls://fixture@example.com:443", "anytls://fixture@example.com:443?insecure=1&fp=chrome&alpn=http%2F1.1"].map(NodeLinkParser.parse)
        let file = directory.appendingPathComponent("check.json")
        try XrayConfigBuilder.writeJSON(["outbounds": try nodes.enumerated().map { index, node -> [String: Any] in
            var outbound = try SingBoxConnectionConfig.outbound(node)
            outbound["tag"] = "check-\(index)"
            return outbound
        }], to: file)
        for version in [SingBoxInstaller.version, SingBoxInstaller.approvedVersion] {
            let binary = try await SingBoxInstaller.prepare(in: directory, version: version)
            let result = try await ProcessRunner.run(executable: binary, arguments: ["check", "-c", file.path], timeout: 5)
            XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
        }
    }

    func testLinksAndBase64RoundTripForEveryNewProtocol() throws {
        var tuic = try NodeLinkParser.parse("tuic://\(uuid):p%2540%3A%40@example.com:443?congestion_control=bbr&udp_relay_mode=quic&zero_rtt_handshake=false")
        XCTAssertEqual(tuic.password, "p%40:@")
        XCTAssertEqual(tuic.tuicOptions?.congestionControl, "bbr")
        tuic.allowInsecure = false
        let nodes = [tuic, wgNode(), try NodeLinkParser.parse("socks5://user:p%2540%3A%40@[::1]:1080#SOCKS"),
                     try NodeLinkParser.parse("http://example.com:8080"),
                     try NodeLinkParser.parse("https://user:pass@example.com:8443?sni=proxy.example.com&pinSHA256=\(String(repeating: "ab", count: 32))")]
        for node in nodes {
            let link = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: node))
            let parsed = try NodeLinkParser.parse(link)
            XCTAssertEqual(parsed.protocolType, node.protocolType)
            XCTAssertEqual(parsed.server, node.server)
            XCTAssertEqual(NodeFingerprint.make(from: parsed), NodeFingerprint.make(from: node), link)
            XCTAssertEqual(try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node)), node)
            let data = Data(Data(link.utf8).base64EncodedString().utf8)
            XCTAssertEqual(try SubscriptionContentParser.parse(data: data).validNodes.first?.protocolType, node.protocolType)
            XCTAssertFalse(LogRedactor.redact(link).contains("example.com"))
        }
        var defaultTuic = tuic
        defaultTuic.tuicOptions = nil
        defaultTuic.allowInsecure = true
        let insecureLink = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: defaultTuic))
        XCTAssertEqual(try NodeLinkParser.parse(insecureLink).allowInsecure, true)
    }

    func testWireGuardConfigAndYAMLImport() throws {
        let original = wgNode()
        let options = original.wireGuardOptions!
        let config = """
        # Test client, not a shell script.
        [Interface]
        PrivateKey = \(options.privateKey!)
        Address = 10.88.0.2/32, fd88::2/128
        DNS = 1.1.1.1
        MTU = 1420
        [Peer]
        PublicKey = \(options.peerPublicKey)
        PresharedKey = \(options.preSharedKey!)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = example.com:51820
        PersistentKeepalive = 25
        """
        let parsed = try NodeLinkParser.parse(config)
        XCTAssertEqual(parsed.wireGuardOptions?.privateKey, options.privateKey)
        XCTAssertEqual(parsed.wireGuardOptions?.addresses, options.addresses)
        XCTAssertEqual(try SubscriptionContentParser.parse(data: Data(config.utf8)).validNodes.count, 1)
        XCTAssertEqual(NodeLinkParser.parseLines(config).validNodes.count, 1)
        XCTAssertTrue(try XCTUnwrap(NodeLinkParser.extractShareLinks(from: config).first).hasPrefix("wireguard://"))
        XCTAssertThrowsError(try NodeLinkParser.parse(config + "\nPostUp = touch /tmp/never-execute"))
        XCTAssertThrowsError(try NodeLinkParser.parse(config + "\n[Peer]\nPublicKey = \(options.peerPublicKey)"))
        let yaml = """
        proxies:
          - {name: t, type: tuic, server: example.com, port: 443, uuid: \(uuid), password: pass, congestion-controller: bbr, heartbeat-interval: 10000, alpn: [h3]}
          - {name: w, type: wireguard, server: example.com, port: 51820, private-key: '\(options.privateKey!)', public-key: '\(options.peerPublicKey)', ip: 10.88.0.2/32, ipv6: fd88::2/128, allowed-ips: [0.0.0.0/0, '::/0'], reserved: [0, 1, 255]}
          - {name: s, type: socks5, server: example.com, port: 1080}
          - {name: h, type: http, server: example.com, port: 443, tls: true, username: user, password: pass, sni: proxy.example.com, headers: {X-Token: custom}}
        """
        let nodes = try ClashYAMLParser.parse(yaml).validNodes
        XCTAssertEqual(nodes.map(\.protocolType), [.tuic, .wireguard, .socks5, .http])
        XCTAssertEqual(nodes.first?.tuicOptions?.heartbeat, "10000ms")
        XCTAssertEqual(nodes.last?.security, .tls)
        XCTAssertEqual(nodes.last?.httpHeaders?["x-token"], "custom")
    }

    func testSubscriptionURLsAndUnsupportedParametersAreNotSilentlyImported() throws {
        for link in ["https://example.com/sub?token=secret", "https://example.com:8443/subscription", "https://example.com/docs", "https://example.com"] {
            XCTAssertTrue(NodeLinkParser.extractShareLinks(from: link).isEmpty, link)
        }
        XCTAssertEqual(NodeLinkParser.parseLines("socks5://example.com:1080" + "http://example.com:8080").validNodes.count, 2)
        for link in ["tuic://token@example.com:443", "tuic://\(uuid):pass@example.com?token=v4", "tuic://\(uuid):pass@example.com?congestion_control=unknown",
                     "tuic://\(uuid):pass@example.com?udp_over_stream=true&udp_relay_mode=quic", "tuic://\(uuid):pass@example.com?insecure=maybe",
                     "socks5://user@example.com:1080", "socks5://user:pass@example.com:1080?tls=true",
                     "http://user:pass@example.com:8080/sub", "https://example.com:443?insecure=1", "https://example.com:443?alpn=h2",
                     "wireguard://key@example.com:51820?public-key=bad&addresses=10.0.0.1"] {
            XCTAssertThrowsError(try NodeLinkParser.parse(link), link)
        }
        let header = #"{"Proxy-Authorization":"Bearer a"}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertThrowsError(try NodeLinkParser.parse("http://user:pass@example.com:8080?headers=\(header)"))
        XCTAssertThrowsError(try ClashYAMLParser.parse("proxies: [{name: t, type: tuic, server: example.com, port: 443, uuid: \(uuid), password: pass, unknown: option}]"))
        XCTAssertThrowsError(try ClashYAMLParser.parse("proxies: [{name: t, type: tuic, server: example.com, port: 443, uuid: \(uuid), password: pass, username: ignored}]"))
    }

    func testHTTPExtractionKeepsWebsiteURLsInsideExistingNodeNames() throws {
        let link = "trojan://password@example.com:443#Node-https://help.example.com/page"
        XCTAssertEqual(NodeLinkParser.extractShareLinks(from: link + "\n" + link), [link])
        let joined = link + "socks5://example.com:1080"
        let parsed = NodeLinkParser.parseLines(joined).validNodes
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first?.name, "Node-https://help.example.com/page")
        XCTAssertEqual(parsed.last?.protocolType, .socks5)
    }

    func testCredentialBackupAndRefreshDoNotResurrectSecrets() throws {
        let wg = wgNode()
        let secretLink = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: wg))
        let subscription = Subscription(name: "WG", originalURL: "share-links://fixture", shareLinksText: secretLink)
        let snapshot = LibrarySnapshot(nodes: [wg], subscriptions: [subscription])
        let encoded = try LibraryBackup.export(snapshot: snapshot, passphrase: "fixture", includeCredentials: false)
        let restored = try LibraryBackup.importBackup(from: encoded, passphrase: "fixture")
        XCTAssertNil(restored.nodes[0].wireGuardOptions?.privateKey)
        XCTAssertNil(restored.nodes[0].wireGuardOptions?.preSharedKey)
        XCTAssertEqual(restored.nodes[0].wireGuardOptions?.peerPublicKey, wg.wireGuardOptions?.peerPublicKey)
        XCTAssertNil(restored.subscriptions[0].shareLinksText)
        let full = try LibraryBackup.export(snapshot: snapshot, passphrase: "fixture", includeCredentials: true)
        XCTAssertEqual(try LibraryBackup.importBackup(from: full, passphrase: "fixture").nodes.first, wg)
        var old = try NodeLinkParser.parse("http://old:password@example.com:8080#Stable")
        old.lastTestStatus = .fast
        old.lastLatency = 100
        old.isFavorite = true
        old.credentialKey = "old-key-reference"
        let incoming = try NodeLinkParser.parse("http://example.com:8080#Stable")
        let merged = try XCTUnwrap(SubscriptionMerger.buildPlan(mode: .smartMerge, oldNodes: [old], newNodes: [incoming], missingLimit: 3).resultingNodes.first)
        XCTAssertEqual(merged.id, old.id)
        XCTAssertTrue(merged.isFavorite)
        XCTAssertNil(merged.password)
        XCTAssertNil(merged.username)
        XCTAssertNil(merged.credentialKey)
        XCTAssertEqual(merged.lastTestStatus, .untested)
        var changed = wg
        changed.wireGuardOptions?.preSharedKey = Data(repeating: 8, count: 32).base64EncodedString()
        XCTAssertNotEqual(NodeFingerprint.make(from: changed), NodeFingerprint.make(from: wg))
        XCTAssertFalse(LogRedactor.redact("PrivateKey = \(wg.wireGuardOptions!.privateKey!)").contains(wg.wireGuardOptions!.privateKey!))
    }

    func testWireGuardNetworkParametersAndSOCKSUsername() throws {
        var node = wgNode()
        node.wireGuardOptions?.mtu = 576
        XCTAssertThrowsError(try RemoteProtocolParser.validate(node))
        node.wireGuardOptions?.mtu = 1420
        node.wireGuardOptions?.reserved = [0, 0, 256]
        XCTAssertThrowsError(try RemoteProtocolParser.validate(node))
        node.wireGuardOptions?.reserved = [0, 0, 0]
        node.wireGuardOptions?.allowedIPs = ["192.0.2.0/99"]
        XCTAssertThrowsError(try RemoteProtocolParser.validate(node))
        let socks = try NodeLinkParser.parse("socks5://user%3Aname:pass@example.com:1080")
        XCTAssertEqual(socks.username, "user:name")
        XCTAssertThrowsError(try NodeLinkParser.parse("http://user%3Aname:pass@example.com:8080"))
    }

    func testUDPProtocolsSkipTCPAndNeedCore() async throws {
        let tuic = try NodeLinkParser.parse("tuic://\(uuid):pass@127.0.0.1:1")
        XCTAssertEqual(tuic.transportDisplayName, "QUIC / UDP")
        XCTAssertEqual(wgNode().transportDisplayName, "UDP")
        for node in [tuic, wgNode(server: "127.0.0.1", port: 1)] {
            XCTAssertTrue(node.usesUDPTransport)
            let result = await NodeProbeEngine.tcpOnly(node: node, timeout: 0.1)
            XCTAssertFalse(result.success)
            XCTAssertEqual(result.failureStage, .config)
            let probe = await NodeProbeEngine.batchProxyProbe(node: node, localPort: 1, testURL: URL(string: "https://fixture.invalid/"), tcpTimeout: 0.1, httpsTimeout: 2)
            XCTAssertEqual(probe?.failureStage, .http)
            XCTAssertNil(probe?.tcpLatency)
        }
        for link in ["anytls://fixture@127.0.0.1:1", "socks5://127.0.0.1:1", "http://127.0.0.1:1"] {
            let node = try NodeLinkParser.parse(link)
            let result = await NodeProbeEngine.tcpOnly(node: node, timeout: 0.1)
            XCTAssertFalse(result.success)
            XCTAssertEqual(result.failureStage, .config)
        }
    }

    func testMixedCoreConfigurations() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        let nodes = [wgNode(), try NodeLinkParser.parse("socks5://user:pass@example.com:1080"),
                     try NodeLinkParser.parse("https://user:pass@example.com:443"),
                     try NodeLinkParser.parse("tuic://\(uuid):pass@example.com:443"),
                     try NodeLinkParser.parse("anytls://fixture@example.com:443?insecure=1&fp=chrome")]
        let ports = XrayConfigBuilder.LocalPorts(socksHost: "127.0.0.1", socksPort: 29001, httpHost: "127.0.0.1", httpPort: 29002)
        for node in nodes {
            XCTAssertTrue(NodeConfigChecker.validate(node).0)
            for mode in RoutingMode.allCases {
                let config = try XrayConfigBuilder.build(node: node, ports: ports, routingMode: mode)
                XCTAssertNotNil(config["outbounds"])
            }
        }
        let config = try XrayConfigBuilder.buildTestConfig(nodes: Array(zip(nodes, [29001, 29002, 29003, 29004, 29005])))
        let file = directory.appendingPathComponent("mixed.json")
        try XrayConfigBuilder.writeJSON(config, to: file)
        let client = XrayProcessManager(binaryURL: binary)
        defer { Task { await client.stop() } }
        try await client.start(configURL: file)
        let running = await client.isRunning()
        XCTAssertTrue(running)
        await client.stop()
    }

    func testRealSOCKS5AnonymousAndAuthenticatedForwarding() async throws {
        try await transfer(.socks5, authenticated: false)
        try await transfer(.socks5, authenticated: true)
    }
    func testRealHTTPAnonymousAndAuthenticatedForwarding() async throws {
        try await transfer(.http, authenticated: false)
        try await transfer(.http, authenticated: true)
    }
    func testRealHTTPSForwardingAndCertificateRejection() async throws { try await transfer(.http, tls: true) }
    func testRealTUICForwardingAndAuthenticationRejection() async throws { try await transfer(.tuic) }
    func testRealAnyTLSForwardingAuthenticationAndCertificateRejection() async throws { try await transfer(.anytls) }
    func testRealWireGuardForwardingAndKeyRejection() async throws { try await transfer(.wireguard) }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func transfer(_ proto: ProxyProtocolType, tls secureHTTP: Bool = false, authenticated: Bool = true) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        let reservation = try LocalTestPorts(count: 5)
        let ports = reservation.ports
        let cert = directory.appendingPathComponent("cert.pem")
        let key = directory.appendingPathComponent("key.pem")
        let certificateConfig = directory.appendingPathComponent("openssl.cnf")
        try "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n".write(to: certificateConfig, atomically: true, encoding: .utf8)
        let generated = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "1", "-config", certificateConfig.path
        ], timeout: 5)
        XCTAssertEqual(generated.status, 0)
        let der = directory.appendingPathComponent("cert.der")
        _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path], timeout: 5)
        let pin = CryptoUtil.sha256Hex(try Data(contentsOf: der))
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let psk = Data(repeating: 9, count: 32).base64EncodedString()
        var node = ProxyNode(name: proto.displayName, protocolType: proto, server: "127.0.0.1", port: ports[0])
        let inbound: [String: Any]
        var serverConfig: [String: Any]
        var serverExecutable = binary
        if proto == .tuic || proto == .anytls {
            serverExecutable = try await SingBoxInstaller.prepare(in: directory)
            inbound = ["type": proto.rawValue, "listen": "127.0.0.1", "listen_port": ports[0],
                "users": [proto == .tuic ? ["uuid": uuid, "password": "fixture-password"] : ["name": "fixture", "password": "fixture-password"]],
                "tls": ["enabled": true, "alpn": [proto == .tuic ? "h3" : "http/1.1"], "certificate_path": cert.path, "key_path": key.path]]
            serverConfig = ["inbounds": [inbound], "outbounds": [["type": "direct"]]]
            node.password = "fixture-password"
            node.security = .tls
            node.sni = "localhost"
            if proto == .tuic {
                node.uuid = uuid
                node.alpn = "h3"
                node.tuicOptions = TuicOptions(certificate: try String(contentsOf: cert, encoding: .utf8))
            } else {
                node.alpn = "http/1.1"
                node.fingerprint = "chrome"
                node.allowInsecure = true
            }
        } else {
            if proto == .wireguard {
                inbound = ["listen": "127.0.0.1", "port": ports[0], "protocol": "wireguard", "settings": [
                    "secretKey": serverKey.rawRepresentation.base64EncodedString(),
                    "peers": [["publicKey": clientKey.publicKey.rawRepresentation.base64EncodedString(), "preSharedKey": psk, "allowedIPs": ["10.88.0.2/32"]]]]]
                node.wireGuardOptions = WireGuardOptions(privateKey: clientKey.rawRepresentation.base64EncodedString(), addresses: ["10.88.0.2/32"],
                    peerPublicKey: serverKey.publicKey.rawRepresentation.base64EncodedString(), preSharedKey: psk)
            } else {
                var settings: [String: Any] = [:]
                if proto == .socks5 { settings = ["auth": authenticated ? "password" : "noauth", "udp": true, "ip": "127.0.0.1"] }
                if authenticated { settings["accounts"] = [["user": "fixture-user", "pass": "fixture-password"]] }
                var stream: [String: Any] = ["network": "tcp", "security": secureHTTP ? "tls" : "none"]
                if secureHTTP { stream["tlsSettings"] = ["alpn": ["http/1.1"], "certificates": [["certificateFile": cert.path, "keyFile": key.path]]] }
                inbound = ["listen": "127.0.0.1", "port": ports[0], "protocol": proto == .socks5 ? "socks" : "http", "settings": settings, "streamSettings": stream]
                if authenticated { node.username = "fixture-user"; node.password = "fixture-password" }
                if secureHTTP { node.security = .tls; node.sni = "localhost"; node.pinnedCertSHA256 = pin }
            }
            var freedom: [String: Any] = ["finalRules": [["action": "allow", "network": "tcp", "ip": ["127.0.0.1", "203.0.113.7"], "port": "\(ports[1])"]]]
            var udpFreedom: [String: Any] = ["finalRules": [["action": "allow", "network": "udp", "ip": ["127.0.0.1", "203.0.113.7"], "port": "\(ports[3])"]]]
            if proto == .wireguard { freedom["redirect"] = "127.0.0.1:\(ports[1])" }
            if proto == .wireguard { udpFreedom["redirect"] = "127.0.0.1:\(ports[3])" }
            serverConfig = ["log": ["loglevel": "info"], "inbounds": [inbound],
                "outbounds": [["tag": "tcp-target", "protocol": "freedom", "settings": freedom], ["tag": "udp-target", "protocol": "freedom", "settings": udpFreedom]],
                "routing": ["rules": [["type": "field", "network": "udp", "outboundTag": "udp-target"]]]]
        }
        let serverFile = directory.appendingPathComponent("server.json")
        try XrayConfigBuilder.writeJSON(serverConfig, to: serverFile)
        let payload = Data("real \(proto.displayName) transfer".utf8)
        try payload.write(to: directory.appendingPathComponent("probe.txt"))
        reservation.release()
        let serverLog = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: serverLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: serverLog)
        defer { try? log.close() }
        let server = Process()
        server.executableURL = serverExecutable
        server.arguments = proto == .tuic || proto == .anytls ? ["run", "-c", serverFile.path] : ["run", "-config", serverFile.path]
        server.standardOutput = log
        server.standardError = log
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        target.arguments = ["-m", "http.server", "\(ports[1])", "--bind", "127.0.0.1", "--directory", directory.path]
        target.standardOutput = FileHandle.nullDevice
        target.standardError = FileHandle.nullDevice
        try target.run()
        defer { if target.isRunning { target.terminate(); target.waitUntilExit() } }
        for _ in 0..<30 {
            if await TCPTester.measure(host: "127.0.0.1", port: ports[1], timeout: 0.1) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(server.isRunning, (try? String(contentsOf: serverLog)) ?? "")
        let clientFile = directory.appendingPathComponent("client.json")
        var config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, ports[2])])
        if proto != .http {
            var inbounds = config["inbounds"] as! [[String: Any]]
            inbounds.append(["tag": "udp-test", "listen": "127.0.0.1", "port": ports[4], "protocol": "socks", "settings": ["udp": true, "auth": "noauth"]])
            config["inbounds"] = inbounds
            var routing = config["routing"] as! [String: Any]
            var rules = routing["rules"] as! [[String: Any]]
            rules.insert(["type": "field", "inboundTag": ["udp-test"], "outboundTag": "proxy-0"], at: 0)
            routing["rules"] = rules
            config["routing"] = routing
        }
        try XrayConfigBuilder.writeJSON(config, to: clientFile)
        let client = XrayProcessManager(binaryURL: binary)
        defer { Task { await client.stop() } }
        try await client.start(configURL: clientFile)
        func waitForProxy() async throws {
            for _ in 0..<30 {
                if await TCPTester.measure(host: "127.0.0.1", port: ports[2], timeout: 0.1) != nil { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("测试代理入口未就绪，不能把端口未监听误当成认证被拒绝")
            throw NSError(domain: "fixture-not-ready", code: 1)
        }
        try await waitForProxy()
        let output = directory.appendingPathComponent("received.txt")
        let destination = proto == .wireguard ? "203.0.113.7" : "127.0.0.1"
        func request(timeout: String = "5") async throws -> ProcessRunResult {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                "--silent", "--fail", "--noproxy", "", "--max-time", timeout, "--proxy", "http://127.0.0.1:\(ports[2])",
                "http://\(destination):\(ports[1])/probe.txt", "-o", output.path
            ], timeout: 7)
        }
        let response = try await request()
        if response.status != 0 {
            print((try? String(contentsOf: serverLog)) ?? "")
            print(await client.readRecentOutput())
        }
        XCTAssertEqual(response.status, 0)
        XCTAssertEqual(try Data(contentsOf: output), payload)
        if proto != .http {
            let echo = Process()
            echo.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            echo.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',int(sys.argv[1]))); s.settimeout(10); d,a=s.recvfrom(4096); s.sendto(d,a)", "\(ports[3])"]
            echo.standardOutput = FileHandle.nullDevice
            echo.standardError = FileHandle.nullDevice
            try echo.run()
            defer { if echo.isRunning { echo.terminate(); echo.waitUntilExit() } }
            let udpScript = #"""
            import socket, struct, sys
            with socket.create_connection(('127.0.0.1', int(sys.argv[1])), 5) as control:
                control.sendall(b'\x05\x01\x00')
                reader = control.makefile('rb')
                assert reader.read(2) == b'\x05\x00'
                control.sendall(b'\x05\x03\x00\x01' + bytes(6))
                reply = reader.read(10)
                assert reply[:4] == b'\x05\x00\x00\x01', reply
                relay = (socket.inet_ntoa(reply[4:8]), struct.unpack('!H', reply[8:10])[0])
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                    udp.bind(('127.0.0.1', 0))
                    udp.settimeout(5)
                    packet = b'\x00\x00\x00\x01' + socket.inet_aton(sys.argv[3]) + struct.pack('!H', int(sys.argv[2])) + b'udp-fixture'
                    udp.sendto(packet, relay)
                    response = udp.recvfrom(4096)[0]
                    assert response == packet, response
            """#
            let udp = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", udpScript, "\(ports[4])", "\(ports[3])", destination], timeout: 7)
            if udp.status != 0 { print(await client.readRecentOutput()) }
            XCTAssertEqual(udp.status, 0, String(decoding: udp.output, as: UTF8.self))
        }
        await client.stop()
        if authenticated {
            var invalid = node
            if proto == .wireguard { invalid.wireGuardOptions?.preSharedKey = Data(repeating: 6, count: 32).base64EncodedString() }
            else { invalid.password = "incorrect-password" }
            try XrayConfigBuilder.writeJSON(XrayConfigBuilder.buildTestConfig(nodes: [(invalid, ports[2])]), to: clientFile)
            try await client.start(configURL: clientFile)
            try await waitForProxy()
            let denied = try await request(timeout: "1")
            XCTAssertNotEqual(denied.status, 0, "Wrong authentication must fail")
            await client.stop()
        }
        if secureHTTP || proto == .tuic || proto == .anytls {
            var invalid = node
            if secureHTTP { invalid.pinnedCertSHA256 = String(repeating: "00", count: 32) }
            else if proto == .anytls { invalid.allowInsecure = false }
            else { invalid.tuicOptions?.certificate = nil }
            try XrayConfigBuilder.writeJSON(XrayConfigBuilder.buildTestConfig(nodes: [(invalid, ports[2])]), to: clientFile)
            try await client.start(configURL: clientFile)
            try await waitForProxy()
            let denied = try await request(timeout: "1")
            XCTAssertNotEqual(denied.status, 0, "Wrong certificate pin must fail")
            await client.stop()
        }
    }
}
