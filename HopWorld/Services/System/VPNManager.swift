import Foundation
import NetworkExtension

/// Installs / starts / stops the HopWorld Packet Tunnel (appears under System Settings → Network).
@MainActor
final class VPNManager {
    private var statusObserver: NSObjectProtocol?
    private var onStatusChange: ((NEVPNStatus) -> Void)?
    private var observedConnection: NEVPNConnection?

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func setStatusHandler(_ handler: @escaping (NEVPNStatus) -> Void) {
        onStatusChange = handler
        if statusObserver == nil {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let connection = note.object as? NEVPNConnection else { return }
                Task { @MainActor in
                    guard connection === self?.observedConnection else { return }
                    self?.onStatusChange?(connection.status)
                }
            }
        }
    }

    func currentStatus() async -> NEVPNStatus {
        let manager = try? await loadManager()
        return manager?.connection.status ?? .invalid
    }

    func start(
        httpHost: String,
        httpPort: Int,
        socksHost: String,
        socksPort: Int,
        generation: Int
    ) async throws {
        HopWorldAppGroup.writeEndpoints(
            httpHost: httpHost,
            httpPort: httpPort,
            socksHost: socksHost,
            socksPort: socksPort,
            generation: generation
        )

        let manager = try await prepareManager()
        switch manager.connection.status {
        case .connected:
            return
        case .connecting, .reasserting:
            guard await waitForStatus([.connected], timeout: 20) else { throw VPNManagerError.permissionOrStartFailed }
            return
        default:
            break
        }

        do {
            try manager.connection.startVPNTunnel(options: [
                "generation": NSNumber(value: generation)
            ])
        } catch {
            throw VPNManagerError.startFailed(error.localizedDescription)
        }

        // Wait until connected or failed (user may deny permission).
        let ok = await waitForStatus([.connected], timeout: 20)
        guard ok else { throw VPNManagerError.permissionOrStartFailed }
    }

    func stop() async {
        guard let manager = try? await loadManager() else { return }
        switch manager.connection.status {
        case .disconnected, .invalid:
            return
        default:
            manager.connection.stopVPNTunnel()
        }
        _ = await waitForStatus([.disconnected, .invalid], timeout: 8)
    }

    // MARK: - Preferences

    private func prepareManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first(where: { existing in
            guard let proto = existing.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == HopWorldAppGroup.tunnelBundleIdentifier
        }) ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = HopWorldAppGroup.tunnelBundleIdentifier
        proto.serverAddress = HopWorldAppGroup.vpnDisplayName
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = HopWorldAppGroup.vpnDisplayName
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        observedConnection = manager.connection
        return manager
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first(where: { existing in
            guard let proto = existing.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == HopWorldAppGroup.tunnelBundleIdentifier
        })
        observedConnection = manager?.connection
        return manager
    }

    private func waitForStatus(_ targets: Set<NEVPNStatus>, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled && Date() < deadline {
            let status = await currentStatus()
            if targets.contains(status) {
                return true
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return false }
        }
        return targets.contains(await currentStatus())
    }
}

enum VPNManagerError: LocalizedError {
    case startFailed(String)
    case permissionOrStartFailed

    var errorDescription: String? {
        switch self {
        case .startFailed(let message):
            return "启动系统 VPN 失败：\(message)"
        case .permissionOrStartFailed:
            return "系统 VPN 未能连接。请在「系统设置 → 网络」允许跃界 VPN，并确认已用带 Network Extension 权限的开发者证书签名。"
        }
    }
}
