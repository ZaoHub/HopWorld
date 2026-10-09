import Foundation

extension AppSettings {
    var supportsApplicationProxy: Bool { routingMode == .rules }

    /// Global always captures every app. Preserve the whitelist, but require
    /// explicit opt-in when returning to application routing in rules mode.
    mutating func normalizeApplicationProxyMode() {
        if routingMode == .global {
            connectionCaptureMode = .globalTun
        } else if connectionCaptureMode == .globalTun ||
                    (!supportsApplicationProxy && connectionCaptureMode == .applications) {
            connectionCaptureMode = .systemProxy
        }
    }

    mutating func selectRoutingMode(_ mode: RoutingMode) {
        routingMode = mode
        normalizeApplicationProxyMode()
    }
}
