import Foundation

extension AppSettings {
    var supportsApplicationProxy: Bool { routingMode == .rules }

    /// Global always captures every app. Preserve the whitelist across mode
    /// changes; when returning to rules with a saved list, restore application
    /// capture so the visible whitelist is not silently demoted to system-wide proxy.
    mutating func normalizeApplicationProxyMode() {
        if routingMode == .global {
            connectionCaptureMode = .globalTun
        } else if connectionCaptureMode == .globalTun ||
                    (!supportsApplicationProxy && connectionCaptureMode == .applications) {
            connectionCaptureMode = .systemProxy
        }
    }

    mutating func selectRoutingMode(_ mode: RoutingMode) {
        let previous = routingMode
        routingMode = mode
        normalizeApplicationProxyMode()
        // Leaving global/direct with a saved whitelist must not leave rules mode
        // on systemProxy while the UI still shows those apps as configured.
        if mode == .rules, previous != .rules, !proxyApplications.isEmpty,
           connectionCaptureMode == .systemProxy {
            connectionCaptureMode = .applications
        }
    }
}
