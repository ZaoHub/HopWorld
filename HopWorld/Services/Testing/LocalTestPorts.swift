import Foundation
import Darwin

/// Reserve loopback ports while building a test config, then release them
/// immediately before Xray binds. Each test core gets its own port set.
final class LocalTestPorts {
    private var descriptors: [Int32] = []
    private(set) var ports: [Int] = []

    init(count: Int) throws {
        do {
            for _ in 0..<count {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.EMFILE) }
                descriptors.append(fd)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let read = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                guard read == 0 else { throw POSIXError(.EINVAL) }
                ports.append(Int(UInt16(bigEndian: address.sin_port)))
            }
        } catch {
            release()
            throw error
        }
    }

    func release() {
        descriptors.forEach { close($0) }
        descriptors.removeAll()
    }
    deinit { release() }
}
