import XCTest
import Network
import CryptoKit
import Darwin

private final class WebSocketProxyFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "quality.websocket-fixture")
    private let listener: NWListener
    private var peers: [Peer] = []
    let port: Int
    init(closeAfter: TimeInterval? = nil, reject: Bool = false, respondsToPing: Bool = true) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            listener.cancel(); throw NSError(domain: "fixture", code: 1)
        }
        self.port = Int(port.rawValue)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer = Peer(connection: connection, queue: self.queue, closeAfter: closeAfter,
                            reject: reject, respondsToPing: respondsToPing)
            self.peers.append(peer)
            connection.start(queue: self.queue)
            peer.receive()
        }
    }
    var pongs: Int { queue.sync { peers.reduce(0) { $0 + $1.pongs } } }
    func stop() { queue.sync { listener.cancel(); peers.forEach { $0.connection.cancel() }; peers.removeAll() } }

    private final class Peer {
        let connection: NWConnection
        let queue: DispatchQueue
        let closeAfter: TimeInterval?
        let reject: Bool
        let respondsToPing: Bool
        var bytes = Data()
        var upgraded = false
        var pongs = 0
        init(connection: NWConnection, queue: DispatchQueue, closeAfter: TimeInterval?, reject: Bool, respondsToPing: Bool) {
            self.connection = connection; self.queue = queue; self.closeAfter = closeAfter
            self.reject = reject; self.respondsToPing = respondsToPing
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { bytes.append(data); consume() }
                if complete || error != nil { connection.cancel() }
                else { receive() }
            }
        }
        func consume() {
            if !upgraded {
                guard let range = bytes.range(of: Data("\r\n\r\n".utf8)) else { return }
                let request = String(decoding: bytes[..<range.upperBound], as: UTF8.self)
                bytes.removeSubrange(..<range.upperBound)
                if request.hasPrefix("CONNECT ") {
                    send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)); return
                }
                if reject { send(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8)); return }
                guard let keyLine = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { connection.cancel(); return }
                let key = keyLine.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                upgraded = true
                if let closeAfter {
                    queue.asyncAfter(deadline: .now() + closeAfter) { [weak self] in self?.send(Data([0x88, 2, 3, 0xe9])) }
                }
            }
            while bytes.count >= 2 {
                let raw = [UInt8](bytes)
                let opcode = raw[0] & 15
                var size = Int(raw[1] & 127), offset = 2
                if size == 126 {
                    guard raw.count >= 4 else { return }
                    size = Int(raw[2]) * 256 + Int(raw[3]); offset = 4
                }
                guard size <= 4096 else { connection.cancel(); return }
                let masked = raw[1] & 128 != 0
                let payloadOffset = offset + (masked ? 4 : 0)
                guard raw.count >= payloadOffset + size else { return }
                var payload = Array(raw[payloadOffset..<(payloadOffset + size)])
                if masked { for index in payload.indices { payload[index] ^= raw[offset + index % 4] } }
                bytes.removeFirst(payloadOffset + size)
                if opcode == 9, respondsToPing { pongs += 1; send(Data([0x8a, UInt8(payload.count)]) + Data(payload)) }
                if opcode == 8 { connection.cancel(); return }
            }
        }
        func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    }
}

private final class STUNFixture: @unchecked Sendable {
    let port: UInt16
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "quality.stun-fixture")
    init(dropEvery: Int = 0, silent: Bool = false) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NSError(domain: "fixture", code: 2) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &address, {
            Darwin.bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }) == 0 else { close(fd); throw NSError(domain: "fixture", code: 3) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { getsockname(fd, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &length) }
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var count = 0
        source.setEventHandler {
            var request = [UInt8](repeating: 0, count: 4096)
            var sender = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &sender) {
                recvfrom(fd, &request, request.count, 0, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &size)
            }
            guard received >= 20 else { return }
            count += 1
            if silent || (count > 1 && dropEvery > 0 && (count - 1).isMultiple(of: dropEvery)) { return }
            request = Array(request.prefix(20)); request[0] = 1; request[1] = 1
            func reply(_ bytes: [UInt8]) {
                _ = withUnsafePointer(to: &sender) { pointer in
                    bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), size) }
                }
            }
            var wrongTransaction = request; wrongTransaction[8] ^= 255
            reply(wrongTransaction)
            reply(request); reply(request)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    func stop() { queue.sync { source.cancel() } }
}

final class ProxyQualityProbeTests: XCTestCase {
    func testQuickWebSocketFinishesAfterTenSecondsAndKeepsItsActualObservationWindow() async throws {
        let proxy = try WebSocketProxyFixture()
        defer { proxy.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await WebSocketQualityProbe.run(proxyPort: proxy.port,
            endpoint: URL(string: "ws://127.0.0.2:9/fixture")!,
            duration: WebSocketQualityProbe.quickObservationSeconds, timeout: 1)
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertTrue(result.survived, result.detail)
        XCTAssertEqual(result.requestedSeconds, 10)
        XCTAssertGreaterThanOrEqual(result.observedSeconds, 10)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 15)
        XCTAssertEqual(proxy.pongs, 2)
    }

    func testWebSocketWithoutPongStopsAtTheRequestedTimeout() async throws {
        let proxy = try WebSocketProxyFixture(respondsToPing: false)
        defer { proxy.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await WebSocketQualityProbe.run(proxyPort: proxy.port,
            endpoint: URL(string: "ws://127.0.0.2:9/fixture")!,
            duration: WebSocketQualityProbe.quickObservationSeconds, timeout: 0.2)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.survivalRate)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testWebSocketUsesExplicitProxyAndSurvivesIdleObservation() async throws {
        let proxy = try WebSocketProxyFixture()
        defer { proxy.stop() }
        let result = try await WebSocketQualityProbe.run(proxyPort: proxy.port,
            endpoint: URL(string: "ws://127.0.0.2:9/fixture")!, duration: 0.2, timeout: 1)
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertTrue(result.survived, result.detail)
        XCTAssertGreaterThanOrEqual(result.observedSeconds, 0.2)
        XCTAssertEqual(proxy.pongs, 2)
    }

    func testWebSocketEarlyCloseAndHandshakeRejectionHaveDifferentCoverage() async throws {
        let closing = try WebSocketProxyFixture(closeAfter: 0.1)
        defer { closing.stop() }
        let interrupted = try await WebSocketQualityProbe.run(proxyPort: closing.port,
            endpoint: URL(string: "ws://127.0.0.2:9/fixture")!, duration: 1, timeout: 1)
        XCTAssertTrue(interrupted.verified, interrupted.detail)
        XCTAssertFalse(interrupted.survived)
        XCTAssertLessThan(interrupted.observedSeconds, 1)
        let rejecting = try WebSocketProxyFixture(reject: true)
        defer { rejecting.stop() }
        let rejected = try await WebSocketQualityProbe.run(proxyPort: rejecting.port,
            endpoint: URL(string: "ws://127.0.0.2:9/fixture")!, duration: 1, timeout: 0.5)
        XCTAssertFalse(rejected.verified)
        XCTAssertNil(rejected.survivalRate)
    }

    func testWebSocketCancellationStopsWithoutWaitingSixMinutes() async throws {
        let proxy = try WebSocketProxyFixture()
        defer { proxy.stop() }
        let task = Task { try await WebSocketQualityProbe.run(proxyPort: proxy.port,
            endpoint: URL(string: "ws://127.0.0.2:9/fixture")!, duration: 360, timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("取消不能生成成功/失败观测") }
        catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    private func startCore(upstreamPort: Int? = nil) async throws -> (XrayProcessManager, Int, Int, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        let ports = try LocalTestPorts(count: 3)
        let socks = ports.ports[2], http = ports.ports[1]
        let node = ProxyNode(name: "fixture", protocolType: .vless, server: "127.0.0.1", port: 9,
                             uuid: "11111111-1111-4111-8111-111111111111")
        var config = try XrayConfigBuilder.build(node: node,
            ports: .init(socksHost: "127.0.0.1", socksPort: ports.ports[0], httpHost: "127.0.0.1", httpPort: http),
            routingMode: .rules, qualityProxy: (socks, "test-password"))
        config["inbounds"] = (config["inbounds"] as? [[String: Any]])?.filter { $0["tag"] as? String != "api" }
        config.removeValue(forKey: "api")
        config["outbounds"] = [["protocol": "freedom", "tag": "proxy"], ["protocol": "freedom", "tag": "direct"], ["protocol": "blackhole", "tag": "blocked"]]
        if let upstreamPort {
            config["outbounds"] = [["protocol": "socks", "tag": "proxy", "settings": [
                "servers": [["address": "127.0.0.1", "port": upstreamPort]]]]]
            config["routing"] = ["domainStrategy": "AsIs", "rules": [[
                "type": "field", "network": "tcp,udp", "outboundTag": "proxy"]]]
        }
        config["log"] = ["loglevel": "debug"]
        let file = directory.appendingPathComponent("config.json")
        try XrayConfigBuilder.writeJSON(config, to: file)
        let manager = XrayProcessManager(binaryURL: binary)
        addTeardownBlock {
            await manager.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        ports.release()
        try await manager.start(configURL: file)
        let deadline = Date().addingTimeInterval(10)
        while await TCPTester.measure(host: "127.0.0.1", port: socks, timeout: 0.1) == nil {
            guard Date() < deadline, await manager.isRunning() else {
                let diagnostic = await manager.readRecentOutput()
                await manager.stop()
                throw ApplicationProxyError.failed("Fixture core not ready: " + diagnostic)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (manager, socks, http, directory)
    }

    func testActualSOCKSUDPCountsDroppedAndDuplicateDatagrams() async throws {
        let fixture = try STUNFixture(dropEvery: 5)
        defer { fixture.stop() }
        let (core, port, _, directory) = try await startCore()
        let result = try await DatagramLossProbe.run(socksPort: port, password: "test-password",
            host: "127.0.0.1", port: fixture.port, count: 30, interval: 0.01, responseWait: 0.2)
        if !result.verified { print(await core.readRecentOutput()) }
        await core.stop()
        try? FileManager.default.removeItem(at: directory)
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertEqual(result.sent, 30)
        XCTAssertEqual(result.received, 24)
        XCTAssertEqual(try XCTUnwrap(result.lossRate), 0.2, accuracy: 0.0001)
    }

    func testQuickUDPCollectsThirtyUniquePacketsWithoutWaitingForDeepSampling() async throws {
        let fixture = try STUNFixture(dropEvery: 5)
        defer { fixture.stop() }
        let (_, port, _, _) = try await startCore()
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await DatagramLossProbe.run(socksPort: port, password: "test-password",
            host: "127.0.0.1", port: fixture.port, count: DatagramLossProbe.quickCount,
            interval: DatagramLossProbe.quickInterval, responseWait: DatagramLossProbe.quickResponseWait,
            timeout: 1)
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertEqual(result.sent, DatagramLossProbe.quickCount)
        XCTAssertEqual(result.received, 24)
        XCTAssertEqual(try XCTUnwrap(result.lossRate), 0.2, accuracy: 0.0001)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4)
    }

    func testSilentUDPPreflightUsesRequestedTimeoutInsteadOfFixedThreeSeconds() async throws {
        let fixture = try STUNFixture(silent: true)
        defer { fixture.stop() }
        let (_, port, _, _) = try await startCore()
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await DatagramLossProbe.run(socksPort: port, password: "test-password",
            host: "127.0.0.1", port: fixture.port, count: DatagramLossProbe.quickCount,
            interval: DatagramLossProbe.quickInterval, responseWait: DatagramLossProbe.quickResponseWait,
            timeout: 0.2)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.lossRate)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testUDPDoesNotWaitAfterEveryMeasuredPacketHasReturned() async throws {
        let fixture = try STUNFixture()
        defer { fixture.stop() }
        let (_, port, _, _) = try await startCore()
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await DatagramLossProbe.run(socksPort: port, password: "test-password",
            host: "127.0.0.1", port: fixture.port, count: DatagramLossProbe.quickCount,
            interval: DatagramLossProbe.quickInterval, responseWait: 4, timeout: 1)
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertEqual(result.sent, DatagramLossProbe.quickCount)
        XCTAssertEqual(result.received, DatagramLossProbe.quickCount)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testUDPAuthenticationFailureDoesNotBecomeHundredPercentLoss() async throws {
        let (core, port, _, directory) = try await startCore()
        let result = try await DatagramLossProbe.run(socksPort: port, password: "wrong-password")
        await core.stop()
        try? FileManager.default.removeItem(at: directory)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.lossRate)
    }

    func testUDPSilentPreflightAndCancellationDoNotInventLossRate() async throws {
        let fixture = try STUNFixture(silent: true)
        defer { fixture.stop() }
        let (_, port, _, _) = try await startCore()
        let unverified = try await DatagramLossProbe.run(socksPort: port, password: "test-password",
            host: "127.0.0.1", port: fixture.port)
        XCTAssertFalse(unverified.verified)
        XCTAssertNil(unverified.lossRate)
        let task = Task { try await DatagramLossProbe.run(socksPort: port, password: "test-password",
            host: "127.0.0.1", port: fixture.port) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("取消不能生成丢包观测") }
        catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    func testQualityInboundIsAuthenticatedAndPrecedesDirectRules() throws {
        let node = ProxyNode(name: "fixture", protocolType: .vless, server: "127.0.0.1", port: 9,
                             uuid: "11111111-1111-4111-8111-111111111111")
        for mode in RoutingMode.allCases {
            let config = try XrayConfigBuilder.build(node: node,
                ports: .init(socksHost: "127.0.0.1", socksPort: 12001, httpHost: "127.0.0.1", httpPort: 12002),
                routingMode: mode, qualityProxy: (12003, "fixture-secret"))
            let inbound = try XCTUnwrap((config["inbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "quality-in" })
            XCTAssertEqual(inbound["listen"] as? String, "127.0.0.1")
            XCTAssertEqual((inbound["settings"] as? [String: Any])?["auth"] as? String, "password")
            let first = ((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])?.first
            XCTAssertEqual(first?["inboundTag"] as? [String], ["quality-in"])
            XCTAssertEqual(first?["outboundTag"] as? String, mode == .direct ? "direct" : "proxy")
        }
    }

    func testMalformedAndFragmentedSTUNRepliesAreIgnored() {
        let id = Data(repeating: 7, count: 12)
        var response = DatagramLossProbe.bindingRequest(transaction: id)
        response[0] = 1; response[1] = 1
        XCTAssertEqual(DatagramLossProbe.responseTransaction(response), id)
        XCTAssertNil(DatagramLossProbe.responseTransaction(Data(response.dropLast())))
        var badCookie = response; badCookie[4] = 0
        XCTAssertNil(DatagramLossProbe.responseTransaction(badCookie))
        XCTAssertNil(DatagramLossProbe.unwrapSOCKSDatagram(Data([0, 0, 1, 1]) + Data(repeating: 0, count: 6) + response))
    }

    func testMeasuredDimensionsExpireAndDoNotBecomeClaudeStreamingEvidence() throws {
        var quality = AIConnectionQuality()
        for _ in 0..<10 { quality.record(latencyMs: 100) }
        let now = Date()
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 360, requestedSeconds: 360, detail: "fixture", measuredAt: now)
        quality.datagrams = .init(verified: true, sent: 30, received: 30, detail: "fixture", measuredAt: now)
        var settings = AppSettings()
        let appData = Data(#"{"path":"/Applications/Claude.app","name":"Claude","isBundle":true}"#.utf8)
        settings.proxyApplications = [try JSONDecoder().decode(ProxyApplication.self, from: appData)]
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 100, coverage: 100))
        XCTAssertEqual(quality.score(for: .claude, settings: settings, now: now), AINodeScore(points: 65, coverage: 65))
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: now.addingTimeInterval(1900)),
                     "HTTPS and specialized observations have both expired")
        quality.webSocket = .init(verified: false, survived: false, observedSeconds: 0, requestedSeconds: 360, detail: "unverified", measuredAt: now)
        quality.datagrams = .init(verified: false, sent: 30, received: 0, detail: "unverified", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 50, coverage: 50))
    }

    func testPublicWSSAndSTUNThroughLocalCore() async throws {
        guard ProcessInfo.processInfo.environment["HOPWORLD_PUBLIC_QUALITY_TEST"] == "1" else { throw XCTSkip("公开端点实测需显式启用") }
        let upstream = ProcessInfo.processInfo.environment["HOPWORLD_PUBLIC_UPSTREAM_SOCKS_PORT"].flatMap(Int.init)
        let (core, socks, http, directory) = try await startCore(upstreamPort: upstream)
        async let webSocket = WebSocketQualityProbe.run(proxyPort: http)
        let datagrams = try await DatagramLossProbe.run(socksPort: socks, password: "test-password")
        print("PUBLIC_UDP verified=\(datagrams.verified) sent=\(datagrams.sent) received=\(datagrams.received) detail=\(datagrams.detail)")
        let result = try await webSocket
        print("PUBLIC_WSS verified=\(result.verified) survived=\(result.survived) observed=\(result.observedSeconds) detail=\(result.detail)")
        await core.stop()
        try? FileManager.default.removeItem(at: directory)
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertTrue(result.survived, result.detail)
        XCTAssertTrue(datagrams.verified, datagrams.detail)
    }

    func testPublicWebSocketThroughExistingProxy() async throws {
        guard let raw = ProcessInfo.processInfo.environment["HOPWORLD_PUBLIC_HTTP_PORT"],
              let port = Int(raw) else { throw XCTSkip("需显式指定现有本地代理端口") }
        let result = try await WebSocketQualityProbe.run(proxyPort: port)
        print("PUBLIC_EXISTING_WSS verified=\(result.verified) survived=\(result.survived) observed=\(result.observedSeconds) detail=\(result.detail)")
        XCTAssertTrue(result.verified, result.detail)
        XCTAssertTrue(result.survived, result.detail)
        XCTAssertGreaterThanOrEqual(result.observedSeconds, 360)
    }
}
