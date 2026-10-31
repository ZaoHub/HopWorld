import Foundation

enum IMessageSender {
    enum SendError: LocalizedError {
        case invalidRecipient, invalidMessage, automationDenied, unavailable, timedOut, failed

        var errorDescription: String? {
            switch self {
            case .invalidRecipient: return "收件人账号无效，请检查手机号或 Apple ID 邮箱。"
            case .invalidMessage: return "通知内容为空或过长。"
            case .automationDenied: return "请在系统设置 → 隐私与安全性 → 自动化中，允许跃界控制“信息”。"
            case .unavailable: return "未找到已启用的 iMessage 账号，请先在“信息”中登录 iMessage。"
            case .timedOut: return "提交 iMessage 超时，可能已交给“信息”；为避免重复，不会自动重试。"
            case .failed: return "无法提交 iMessage，请检查“信息”的登录状态与收件人账号。"
            }
        }
    }

    // Recipient and message are argv data, never AppleScript source.
    static let script = """
    on run argv
        set recipientAddress to item 1 of argv
        set messageText to item 2 of argv
        tell application "Messages"
            set availableServices to every service whose service type is iMessage and enabled is true
            if (count of availableServices) is 0 then error "HopWorld:no-iMessage-service" number 1001
            set selectedService to item 1 of availableServices
            set targetBuddy to buddy recipientAddress of selectedService
            send messageText to targetBuddy
        end tell
    end run
    """

    /// Success means Messages accepted the command, not that the recipient received it.
    static func send(
        to address: String,
        message: String,
        run: @Sendable (URL, [String], TimeInterval) async throws -> ProcessRunResult = {
            try await ProcessRunner.run(executable: $0, arguments: $1, timeout: $2, outputLimit: 4096)
        }
    ) async throws {
        let recipient = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty, recipient.utf8.count <= 254,
              recipient.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SendError.invalidRecipient
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 16_384, !message.contains("\0") else {
            throw SendError.invalidMessage
        }
        let result: ProcessRunResult
        do {
            result = try await run(URL(fileURLWithPath: "/usr/bin/osascript"),
                                   ["-l", "AppleScript", "-e", script, "--", recipient, message], 20)
        } catch is CancellationError { throw CancellationError() }
        catch { throw SendError.failed }
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw SendError.timedOut }
        guard result.status != 0 else { return }
        let output = String(decoding: result.output, as: UTF8.self)
        if output.contains("(-1743)") { throw SendError.automationDenied }
        if output.contains("HopWorld:no-iMessage-service") { throw SendError.unavailable }
        throw SendError.failed
    }
}
