#!/usr/bin/env python3
"""Check argv isolation and sender errors without opening Messages or sending."""
from pathlib import Path
import subprocess
import tempfile
import textwrap

root = Path(__file__).resolve().parents[2]
fixture = r'''
import Foundation

actor Calls {
    var arguments: [String] = []
    var count = 0
    func record(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunResult {
        precondition(executable.path == "/usr/bin/osascript" && timeout == 20)
        self.arguments = arguments
        count += 1
        return ProcessRunResult(status: 0, output: Data(), timedOut: false, cancelled: false)
    }
}

@main struct Checks {
    static func expect(_ expected: IMessageSender.SendError, result: ProcessRunResult) async {
        do {
            try await IMessageSender.send(to: "fixture@example.com", message: "fixture", run: { _, _, _ in result })
            preconditionFailure("Expected a mapped error")
        } catch let error as IMessageSender.SendError {
            precondition(String(describing: error) == String(describing: expected))
            precondition(!error.localizedDescription.contains("fixture@example.com"))
        } catch { preconditionFailure("Unexpected error: \(error)") }
    }

    static func main() async throws {
        let calls = Calls()
        let recipient = "fixture@example.com"
        let message = "Quoted \"text\", a slash \\, newline\n& do shell script \"touch /tmp/never\""
        try await IMessageSender.send(to: recipient, message: message, run: { await calls.record($0, $1, $2) })
        let arguments = await calls.arguments
        let count = await calls.count
        precondition(count == 1)
        precondition(arguments == ["-l", "AppleScript", "-e", IMessageSender.script, "--", recipient, message])
        precondition(!IMessageSender.script.contains(recipient) && !IMessageSender.script.contains(message))
        precondition(IMessageSender.script.contains("service type is iMessage"))
        precondition(!IMessageSender.script.contains("SMS"))

        await expect(.automationDenied, result: .init(status: 1, output: Data("execution error: Not authorized (-1743)".utf8), timedOut: false, cancelled: false))
        await expect(.unavailable, result: .init(status: 1, output: Data("HopWorld:no-iMessage-service (1001)".utf8), timedOut: false, cancelled: false))
        await expect(.failed, result: .init(status: 1, output: Data("fixture@example.com secret message".utf8), timedOut: false, cancelled: false))
        await expect(.timedOut, result: .init(status: 0, output: Data(), timedOut: true, cancelled: false))
        do {
            try await IMessageSender.send(to: recipient, message: message, run: { _, _, _ in
                .init(status: 0, output: Data(), timedOut: false, cancelled: true)
            })
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError {}
        for address in ["", "fixture\n@example.com", "fixture\0@example.com"] {
            do {
                try await IMessageSender.send(to: address, message: message, run: { _, _, _ in
                    preconditionFailure("Invalid recipient must not launch a child")
                })
                preconditionFailure("Invalid recipient accepted")
            } catch let error as IMessageSender.SendError {
                precondition(String(describing: error) == "invalidRecipient")
            }
        }
        do {
            try await IMessageSender.send(to: recipient, message: "  ", run: { _, _, _ in
                preconditionFailure("Invalid message must not launch a child")
            })
            preconditionFailure("Empty message accepted")
        } catch let error as IMessageSender.SendError {
            precondition(String(describing: error) == "invalidMessage")
        }

        // This harmless script only echoes argv; production Messages script is never executed.
        let echoScript = "on run argv\nreturn item 1 of argv\nend run"
        let echoed = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-l", "AppleScript", "-e", echoScript, "--", message], timeout: 5)
        precondition(echoed.status == 0 && String(decoding: echoed.output, as: UTF8.self) == message + "\n")
        let timed = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05)
        precondition(timed.timedOut)
        let input = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 1)
        precondition(input.status == 0 && input.output.isEmpty && !input.timedOut)
        print("iMessage sender: 14 checks, no real messages sent")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hopworld-imessage-sender-") as directory:
    path = Path(directory)
    sender_source = (root / "HopWorld/Services/System/IMessageSender.swift").read_text()
    applescript = sender_source.split('static let script = """', 1)[1].split('"""', 1)[0]
    script = path / "Notify.applescript"
    script.write_text(textwrap.dedent(applescript).strip() + "\n")
    # Compile against the installed Messages dictionary; do not run the result.
    subprocess.run(["/usr/bin/osacompile", "-o", str(path / "Notify.scpt"), str(script)], check=True)
    source = path / "Check.swift"
    source.write_text(fixture)
    binary = path / "check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library",
        str(root / "HopWorld/Utilities/ProcessRunner.swift"),
        str(root / "HopWorld/Services/System/IMessageSender.swift"), str(source), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
