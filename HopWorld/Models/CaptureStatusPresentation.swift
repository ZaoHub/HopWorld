import Foundation

/// Saved preferences describe the next connection, never evidence of a live
/// capture. Only ConnectionManager's successful session may supply activeMode.
enum CaptureStatusPresentation {
    static func text(status: ConnectionStatus, activeMode: ConnectionCaptureMode?, cleanupPending: Bool) -> String {
        if cleanupPending { return "停止尚未确认，请重试断开" }
        switch status {
        case .disconnected: return "未连接（跃界未接管）"
        case .connecting: return "连接中，新模式尚未确认生效"
        case .disconnecting: return "正在停止接管…"
        case .error: return "连接异常，未确认接管生效"
        case .connected:
            return activeMode.map { "\($0.displayName)（已生效）" } ?? "接管状态未确认，请重新连接"
        }
    }
}
