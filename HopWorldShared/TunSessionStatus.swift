import Foundation
import Darwin

enum TunStopReason: String, Codable, Sendable {
    case requested
    case systemSignal
    case leaseExpired
}

struct TunSessionStatus: Codable, Sendable {
    var state: String
    var message: String
    var updatedAt: Date = Date()
    var stopReason: TunStopReason? = nil
    var signal: Int32? = nil
    var signalSenderPID: Int32? = nil
    var signalSenderUID: UInt32? = nil
    var signalSenderName: String? = nil

    var allowsAutomaticRecovery: Bool {
        guard state == "stopped" else { return true }
        if let stopReason { return stopReason == .leaseExpired }
        // Older helpers only reported a text reason.
        return !message.contains("停止信号") && !message.contains("停止请求")
    }
}

/// Fixed messages for the in-session root helper. The helper never receives a shell.
struct TunHelperRequest: Codable, Sendable, Equatable {
    var op: String
    var binary: String?
    var config: String?
    var lease: String?
    var status: String?
    var binaryDigest: String?
    var configDigest: String?
}

struct TunHelperResponse: Codable, Sendable, Equatable {
    var ok: Bool
    var message: String
}

enum TunHelperChannel {
    static let socketPath = "/private/var/run/hopworld-tun.sock"
    static let maxMessageBytes = 8192

    static func frame<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maxMessageBytes else { throw CocoaError(.fileWriteUnknown) }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    static func payload(from framed: Data) throws -> Data {
        guard framed.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
        let length = framed.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maxMessageBytes, framed.count == 4 + Int(length) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Data(framed.dropFirst(4))
    }
}

enum TunHelperSocket {
    static func bind(_ fd: Int32, _ path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard setPath(path, &address) else { return false }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 }
        }
    }

    static func connect(_ fd: Int32, _ path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard setPath(path, &address) else { return false }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) == 0 }
        }
    }

    static func accept(_ fd: Int32, timeout: TimeInterval) -> Int32? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&pollFD, 1, 200)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { continue }
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 {
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                return client
            }
            if errno == EINTR { continue }
            return nil
        }
        return nil
    }

    static func readRequest(_ fd: Int32, timeout: TimeInterval) -> TunHelperRequest? {
        guard let data = readFrame(fd, timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(TunHelperRequest.self, from: data)
    }

    static func write(_ response: TunHelperResponse, _ fd: Int32) -> Bool {
        send(response, fd)
    }

    static func send<T: Encodable>(_ value: T, _ fd: Int32) -> Bool {
        guard let framed = try? TunHelperChannel.frame(value) else { return false }
        return writeAll(framed, fd)
    }

    static func readResponse(_ fd: Int32, timeout: TimeInterval) -> TunHelperResponse? {
        guard let data = readFrame(fd, timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(TunHelperResponse.self, from: data)
    }

    static func readFrame(_ fd: Int32, timeout: TimeInterval) -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard let header = readCount(4, fd, deadline: deadline) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= TunHelperChannel.maxMessageBytes else { return nil }
        return readCount(Int(length), fd, deadline: deadline)
    }

    private static func readCount(_ count: Int, _ fd: Int32, deadline: TimeInterval) -> Data? {
        var data = Data()
        while data.count < count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waited = poll(&pollFD, 1, Int32(min(remaining, 1) * 1000))
            if waited < 0 && errno == EINTR { continue }
            guard waited > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        return data
    }

    private static func writeAll(_ data: Data, _ fd: Int32) -> Bool {
        var written = 0
        let bytes = [UInt8](data)
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            written += count
        }
        return true
    }

    private static func setPath(_ path: String, _ address: inout sockaddr_un) -> Bool {
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        return path.withCString { source in
            let length = strlen(source)
            guard length + 1 <= capacity else { return false }
            withUnsafeMutablePointer(to: &address.sun_path) { tuple in
                let raw = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: CChar.self)
                raw.update(from: source, count: length + 1)
            }
            return true
        }
    }
}
