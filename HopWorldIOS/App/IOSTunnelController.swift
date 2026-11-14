import Foundation
import NetworkExtension

@MainActor
protocol IOSTunnelControlling: AnyObject {
    var status: NEVPNStatus { get }
    var onStatus: ((NEVPNStatus) -> Void)? { get set }
    func reload() async
    func start(config: String, server: String, name: String) async throws
    func stop()
}

@MainActor
final class IOSTunnelController: ObservableObject, IOSTunnelControlling {
    @Published private(set) var status: NEVPNStatus = .invalid
    var onStatus: ((NEVPNStatus) -> Void)?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let connection = note.object as? NEVPNConnection
            Task { @MainActor in
                guard let self else { return }
                if let connection {
                    self.status = connection.status
                    self.onStatus?(connection.status)
                }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() async {
        if let managers = try? await NETunnelProviderManager.loadAllFromPreferences() {
            manager = managers.first
            status = managers.first?.connection.status ?? .invalid
            onStatus?(status)
        }
    }

    func start(config: String, server: String, name: String) async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = IOSAppGroup.tunnelBundleIdentifier
        proto.serverAddress = server
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = name
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw TunnelSetupError(underlying: error)
        }
        self.manager = manager
        status = manager.connection.status
        onStatus?(status)
        try manager.connection.startVPNTunnel(options: ["configContent": config as NSString])
        status = manager.connection.status
        onStatus?(status)
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }
}

private struct TunnelSetupError: LocalizedError {
    var underlying: Error

    var errorDescription: String? {
        let ns = underlying as NSError
        if ns.domain == NEVPNErrorDomain {
            return "系统没有允许建立隧道（\(underlying.localizedDescription)）。需要付费的 Apple Developer Program，并在 Configs/Signing.local.xcconfig 里启用 iOS 的 Network Extension。"
        }
        return underlying.localizedDescription
    }
}
