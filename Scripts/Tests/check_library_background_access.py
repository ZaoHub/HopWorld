#!/usr/bin/env python3
"""Check encrypted-file protection migration and background activity lifetime."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = (root / "HopWorld/App/AppState.swift").read_text()


def method(signature):
    start = app.index("    " + signature)
    end = app.index("\n    }", start) + len("\n    }")
    return app[start:end]


fixture = r'''
import Foundation
import CryptoKit

struct ProxyNode: Codable, Sendable, Equatable {
    var name: String
    var password: String
}
struct Subscription: Codable, Sendable, Equatable {
    var name: String
}
struct SubscriptionUpdateLog: Codable, Sendable {}
enum KeychainStore {
    static let fixtureKey = Data(repeating: 0x71, count: 32)
    static func libraryEncryptionKey(createIfMissing: Bool) throws -> Data { fixtureKey }
    static func libraryEncryptionKeyCandidates(createIfMissing: Bool) throws -> [Data] { [fixtureKey] }
}
enum LibrarySnapshotMigration {
    static func patchEncryptedLibraryJSON(_ data: Data) throws -> Data { data }
}

@MainActor final class ActivityRecorder {
    static let shared = ActivityRecorder()
    var options: [ProcessInfo.ActivityOptions] = []
    var ended = 0
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
        self.options.append(options)
        precondition(!reason.isEmpty)
        return NSObject()
    }
    func endActivity(_ activity: NSObjectProtocol) { ended += 1 }
}
@MainActor final class Logger {
    func info(_ message: String) {}
}
@MainActor final class AppState {
    var isTerminating = false
    var backgroundActivity: NSObjectProtocol?
    let logger = Logger()
    func start() { startBackgroundActivityIfNeeded() }
    func stop() { stopBackgroundActivity() }
__ACTIVITY__
}

@main struct Checks {
    static func checkProtection(_ directory: URL) throws {
        for name in ["library.enc", "library.previous.enc"] {
            let url = directory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            precondition(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
            let data = try Data(contentsOf: url)
            precondition(data.range(of: Data("fixture-secret".utf8)) == nil)
            _ = try AES.GCM.open(AES.GCM.SealedBox(combined: data),
                                 using: SymmetricKey(data: KeychainStore.fixtureKey))
        }
    }

    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SecureLibraryStore(directory: directory)
        _ = try store.load()
        let original = LibrarySnapshot(nodes: [ProxyNode(name: "Original", password: "fixture-secret")],
                                       subscriptions: [Subscription(name: "Fixture")])
        try store.save(original)
        try checkProtection(directory)

        // Existing encrypted files are reprotected by the next successful atomic save.
        for name in ["library.enc", "library.previous.enc"] {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        let reopened = SecureLibraryStore(directory: directory)
        let existing = try reopened.load()
        precondition(existing.nodes == original.nodes)
        var latest = original
        latest.nodes[0].name = "Updated"
        try reopened.save(latest)
        try checkProtection(directory)
        let migrated = try SecureLibraryStore(directory: directory).load()
        precondition(migrated.nodes == latest.nodes)

        // Keep validating and rotating a closed primary on repeated saves.
        for index in 0..<10 {
            latest.nodes[0].name = "Update \(index)"
            try reopened.save(latest)
            let reread = try SecureLibraryStore(directory: directory).load()
            precondition(reread.nodes == latest.nodes)
        }
        try checkProtection(directory)

        // A damaged primary still recovers the previous authenticated commit.
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("library.enc"))
        let recovered = SecureLibraryStore(directory: directory)
        let recoveredSnapshot = try recovered.load()
        precondition(recoveredSnapshot.nodes.first?.name == "Update 8")
        precondition(recovered.recoveredBackup)
        try checkProtection(directory)

        // The activity is shared and balanced, and allows display and system sleep.
        let activity = AppState()
        activity.start()
        activity.start()
        precondition(activity.backgroundActivity != nil)
        precondition(ActivityRecorder.shared.options == [.userInitiatedAllowingIdleSystemSleep])
        precondition(!ActivityRecorder.shared.options[0].contains(.idleSystemSleepDisabled))
        precondition(!ActivityRecorder.shared.options[0].contains(.idleDisplaySleepDisabled))
        activity.stop()
        activity.stop()
        precondition(activity.backgroundActivity == nil && ActivityRecorder.shared.ended == 1)
        activity.start()
        precondition(ActivityRecorder.shared.options.count == 2)
        activity.stop()
        activity.isTerminating = true
        activity.start()
        precondition(activity.backgroundActivity == nil && ActivityRecorder.shared.options.count == 2)
        print("PASS: encryption, permissions, protection migration, repeated reopen/save, backup recovery, activity lifecycle")
    }
}
'''

activity = "\n".join(method(signature) for signature in [
    "private func startBackgroundActivityIfNeeded()",
    "private func stopBackgroundActivity()",
])
# Observe activity lifetime and flags without altering this test runner's power state.
activity = activity.replace("ProcessInfo.processInfo", "ActivityRecorder.shared")
with tempfile.TemporaryDirectory(prefix="hopworld-background-access-") as temporary:
    directory = Path(temporary)
    check = directory / "Check.swift"
    binary = directory / "check"
    check.write_text(fixture.replace("__ACTIVITY__", activity))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "HopWorld/Services/Persistence/SecureLibraryStore.swift"),
                    str(check), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
