import Foundation
import CFNetwork
import Darwin

/// Reference endpoints carry only random probe data, never account credentials.
enum WebSocketQualityProbe {
    static let endpoint = URL(string: "wss://ws.postman-echo.com/raw")!
    static let quickObservationSeconds: TimeInterval = 10
    static let deepObservationSeconds: TimeInterval = 360
    static let observationSeconds = deepObservationSeconds

    static func run(proxyPort: Int, endpoint: URL = endpoint,
                    duration: TimeInterval = observationSeconds, timeout: TimeInterval = 8) async throws -> WebSocketQualityResult {
        guard (1...65535).contains(proxyPort), duration.isFinite, (0.01...1800).contains(duration),
              timeout.isFinite, (0.05...30).contains(timeout),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.scheme == "wss" || (endpoint.scheme == "ws" && ["127.0.0.1", "127.0.0.2", "::1"].contains(endpoint.host ?? "")) else {
            throw ProbeError.invalidEndpoint
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = duration + timeout * 3
        config.timeoutIntervalForResource = duration + timeout * 3
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: proxyPort,
            kCFNetworkProxiesExceptionsList as String: [String](),
            kCFNetworkProxiesExcludeSimpleHostnames as String: 0
        ]
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: endpoint)
        return try await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
            try Task.checkCancellation()
            socket.resume()
            var verified = false
            var started = ProcessInfo.processInfo.systemUptime
            do {
                try await ping(socket, timeout: timeout)
                verified = true
                started = ProcessInfo.processInfo.systemUptime
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while true { _ = try await socket.receive() }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        try await ping(socket, timeout: timeout)
                    }
                    defer { socket.cancel(with: .goingAway, reason: nil); group.cancelAll() }
                    _ = try await group.next()
                }
                try Task.checkCancellation()
                return WebSocketQualityResult(verified: true, survived: true,
                    observedSeconds: ProcessInfo.processInfo.systemUptime - started, requestedSeconds: duration,
                    detail: "首尾 ping/pong 通过；观测期间未主动发送应用心跳")
            } catch {
                try Task.checkCancellation()
                let code = socket.closeCode.rawValue
                return WebSocketQualityResult(verified: verified, survived: false,
                    observedSeconds: ProcessInfo.processInfo.systemUptime - started, requestedSeconds: duration,
                    detail: "\(verified ? "观测中断" : "端点握手/首个 pong 未验证")；close=\(code)；error=\((error as NSError).code)")
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }

    private static func ping(_ socket: URLSessionWebSocketTask, timeout: TimeInterval) async throws {
        // sendPing's handler can fire again after cancel/abort; resume at most once.
        let probe = WebSocketPingProbe()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                probe.start(socket: socket, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            probe.cancel()
        }
    }
}

private final class WebSocketPingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func start(socket: URLSessionWebSocketTask, timeout: TimeInterval,
               continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(ProbeError.timeout)
        }
        lock.unlock()
        socket.sendPing(pongReceiveHandler: { [weak self] error in self?.finish(error) })
    }

    func cancel() { finish(CancellationError()) }

    private func finish(_ error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

private enum ProbeError: Error {
    case invalidEndpoint, timeout, invalidResponse, authentication, unsupportedRelay
    case transport(String, Int32)
    case stage(String, String)
}

/// RFC 1928 UDP ASSOCIATE + RFC 8489 Binding, without STUN retransmission.
/// Counts missing round-trip datagrams, not IP packet loss or TCP retransmission.
enum DatagramLossProbe {
    static let host = "stun.cloudflare.com"
    static let port: UInt16 = 3478
    static let quickCount = 30
    static let quickInterval: TimeInterval = 0.05
    static let quickResponseWait: TimeInterval = 1

    static func run(socksPort: Int, password: String, host: String = host, port: UInt16 = port,
                    count: Int = 30, interval: TimeInterval = 0.2, responseWait: TimeInterval = 2,
                    timeout: TimeInterval = 5) async throws -> DatagramLossResult {
        guard (1...65535).contains(socksPort), (1...100).contains(count), !password.isEmpty,
              password.utf8.count <= 255, !host.isEmpty, host.utf8.count <= 255, port > 0,
              interval.isFinite, (0.001...1).contains(interval), responseWait.isFinite,
              (0.01...5).contains(responseWait), timeout.isFinite,
              (0.05...30).contains(timeout) else { throw ProbeError.invalidEndpoint }
        let cancellation = DatagramProbeCancellation()
        return try await withTaskCancellationHandler {
            let result = await Task.detached(priority: .utility) {
                do {
                    return try measure(socksPort: socksPort, password: password, host: host, port: port,
                                       count: count, interval: interval, responseWait: responseWait,
                                       timeout: timeout, cancellation: cancellation)
                } catch {
                    return DatagramLossResult(verified: false, sent: 0, received: 0,
                        detail: "UDP 预检或中继未验证（\(String(describing: error))）；不按 100% 丢包计分")
                }
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    static func bindingRequest(transaction: Data) -> Data {
        Data([0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42]) + transaction
    }

    static func responseTransaction(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0] == 1, bytes[1] == 1,
              Array(bytes[4..<8]) == [0x21, 0x12, 0xa4, 0x42] else { return nil }
        let size = Int(bytes[2]) * 256 + Int(bytes[3])
        guard size.isMultiple(of: 4), bytes.count == 20 + size else { return nil }
        return Data(bytes[8..<20])
    }

    static func unwrapSOCKSDatagram(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0 else { return nil }
        let header: Int
        switch bytes[3] {
        case 1: header = 10
        case 4: header = 22
        case 3:
            guard bytes.count >= 5 else { return nil }
            header = 7 + Int(bytes[4])
        default: return nil
        }
        guard bytes.count >= header else { return nil }
        return Data(bytes.dropFirst(header))
    }

    private static func measure(socksPort: Int, password: String, host: String, port: UInt16,
                                count: Int, interval: TimeInterval, responseWait: TimeInterval,
                                timeout: TimeInterval, cancellation: DatagramProbeCancellation) throws -> DatagramLossResult {
        let control = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard control >= 0 else { throw ProbeError.transport("TCP socket", errno) }
        defer { close(control) }
        var noSignal: Int32 = 1
        guard setsockopt(control, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(control, F_SETFL, O_NONBLOCK) == 0 else { throw ProbeError.transport("TCP options", errno) }
        var address = loopback(port: UInt16(socksPort))
        let connected = withUnsafePointer(to: &address) {
            Darwin.connect(control, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try wait(control, events: Int16(POLLOUT), until: uptime + min(3, timeout), cancellation: cancellation)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(control, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
        let deadline = uptime + timeout
        try sendAll(Data([5, 1, 2]), to: control, until: deadline, cancellation: cancellation)
        guard try read(2, from: control, until: deadline, cancellation: cancellation, stage: "SOCKS method") == Data([5, 2]) else { throw ProbeError.authentication }
        let user = Data("hopworld".utf8), secret = Data(password.utf8)
        try sendAll(Data([1, UInt8(user.count)]) + user + Data([UInt8(secret.count)]) + secret,
                    to: control, until: deadline, cancellation: cancellation)
        guard try read(2, from: control, until: deadline, cancellation: cancellation, stage: "SOCKS authentication") == Data([1, 0]) else { throw ProbeError.authentication }
        try sendAll(Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]), to: control, until: deadline, cancellation: cancellation)
        let reply = [UInt8](try read(4, from: control, until: deadline, cancellation: cancellation, stage: "UDP ASSOCIATE"))
        guard reply[0] == 5, reply[1] == 0, reply[2] == 0 else { throw ProbeError.unsupportedRelay }
        let relay: [UInt8]
        switch reply[3] {
        case 1: relay = [UInt8](try read(4, from: control, until: deadline, cancellation: cancellation))
        case 4:
            let ipv6 = try read(16, from: control, until: deadline, cancellation: cancellation)
            guard ipv6 == Data(repeating: 0, count: 16) || ipv6 == Data(repeating: 0, count: 15) + Data([1]) else { throw ProbeError.unsupportedRelay }
            relay = [127, 0, 0, 1]
        default: throw ProbeError.unsupportedRelay
        }
        // This authenticated control server is local. Never send credentials or datagrams to a foreign relay.
        guard relay == [0, 0, 0, 0] || relay[0] == 127 else { throw ProbeError.unsupportedRelay }
        let portBytes = [UInt8](try read(2, from: control, until: deadline, cancellation: cancellation))
        let relayPort = UInt16(portBytes[0]) * 256 + UInt16(portBytes[1])
        guard relayPort > 0 else { throw ProbeError.invalidResponse }
        let udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard udp >= 0 else { throw ProbeError.transport("UDP socket", errno) }
        defer { close(udp) }
        guard fcntl(udp, F_SETFL, O_NONBLOCK) == 0 else { throw ProbeError.transport("UDP options", errno) }
        var relayAddress = loopback(port: relayPort)
        if relay[0] == 127 { relayAddress.sin_addr.s_addr = relay.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard withUnsafePointer(to: &relayAddress, {
            Darwin.connect(udp, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }) == 0 else { throw ProbeError.transport("UDP relay connect", errno) }
        let header = Data([0, 0, 0, 3, UInt8(host.utf8.count)]) + Data(host.utf8) + Data([UInt8(port >> 8), UInt8(port & 255)])
        func send(_ transaction: Data) throws {
            let packet = header + bindingRequest(transaction: transaction)
            try cancellation.check()
            guard packet.withUnsafeBytes({ Darwin.send(udp, $0.baseAddress, $0.count, 0) }) == packet.count else { throw ProbeError.transport("UDP send", errno) }
        }
        func receive(until: TimeInterval) throws -> Data? {
            do { try wait(udp, events: Int16(POLLIN), until: until, cancellation: cancellation) }
            catch ProbeError.timeout { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let size = recv(udp, &buffer, buffer.count, 0)
            guard size > 0 else { return nil }
            return unwrapSOCKSDatagram(Data(buffer.prefix(size))).flatMap(responseTransaction)
        }
        let preflight = transactionID()
        try send(preflight)
        let preflightEnd = uptime + min(3, timeout)
        var verified = false
        while uptime < preflightEnd {
            if try receive(until: preflightEnd) == preflight { verified = true; break }
        }
        guard verified else { throw ProbeError.timeout }
        let start = uptime
        var sent = Set<Data>(), received = Set<Data>()
        while sent.count < count {
            try cancellation.check()
            let transaction = transactionID()
            try send(transaction)
            sent.insert(transaction)
            let next = start + Double(sent.count) * interval
            while uptime < next {
                if let response = try receive(until: next), sent.contains(response) { received.insert(response) }
            }
        }
        let end = uptime + responseWait
        while received.count < sent.count, uptime < end {
            if let response = try receive(until: end), sent.contains(response) { received.insert(response) }
        }
        try cancellation.check()
        return DatagramLossResult(verified: true, sent: sent.count, received: received.count,
            detail: "STUN UDP 往返数据报；无重传；回包按随机事务标识去重；等待 \(responseWait)s")
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func transactionID() -> Data { Data((0..<12).map { _ in UInt8.random(in: 0...255) }) }
    private static func loopback(port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        return value
    }
    private static func wait(_ fd: Int32, events: Int16, until: TimeInterval, cancellation: DatagramProbeCancellation) throws {
        while uptime < until {
            try cancellation.check()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(50, (until - uptime) * 1000))))
            if result < 0 { if errno == EINTR { continue }; throw ProbeError.transport("poll", errno) }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw ProbeError.transport("poll events", Int32(descriptor.revents)) }
            }
        }
        throw ProbeError.timeout
    }
    private static func sendAll(_ data: Data, to fd: Int32, until: TimeInterval, cancellation: DatagramProbeCancellation) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), until: until, cancellation: cancellation)
            let size = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if size < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
            guard size > 0 else { throw ProbeError.transport("TCP send", errno) }
            offset += size
        }
    }
    private static func read(_ count: Int, from fd: Int32, until: TimeInterval, cancellation: DatagramProbeCancellation, stage: String = "SOCKS relay address") throws -> Data {
        var result = Data()
        while result.count < count {
            do { try wait(fd, events: Int16(POLLIN), until: until, cancellation: cancellation) }
            catch { throw ProbeError.stage(stage, String(describing: error)) }
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let size = recv(fd, &bytes, bytes.count, 0)
            if size < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
            guard size > 0 else { throw ProbeError.transport("TCP receive", size == 0 ? 0 : errno) }
            result.append(contentsOf: bytes.prefix(size))
        }
        return result
    }
}

private final class DatagramProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
