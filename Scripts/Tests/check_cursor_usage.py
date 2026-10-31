#!/usr/bin/env python3
"""Exercise Cursor login decoding and usage refresh with local fixtures only."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "HopWorld/Views/Testing/CursorUsageMonitor.swift").read_text()
fixture = r'''
@MainActor final class AppLogger {
    static let shared = AppLogger()
    func warning(_ text: String) {}
}

enum CodexUsageReader {
    static func safeDetail(_ detail: String) -> String { detail }
}

actor Attempts {
    var interactions: [Bool] = []
    func read(_ allowInteraction: Bool) throws -> CursorUsageSnapshot {
        interactions.append(allowInteraction)
        if interactions.count > 1 { throw CursorUsageReader.ReadError.loginExpired }
        return try CursorUsageReader.decodeResponse(Data(
            #"{"planUsage":{"totalPercentUsed":25},"billingCycleEnd":"1700000000000"}"#.utf8), statusCode: 200)
    }
}

@main struct Checks {
    // Generated independently with Python hashlib.pbkdf2_hmac and OpenSSL AES-128-CBC.
    static let password = Data("hopworld-fixture-safe-storage".utf8)
    static let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.fixture-signature"
    static let encrypted = "cursor-safe-storage:v1:djEwcX79MFYI8q01Flo16BIYZWKHcSwFa8OmqVm/7Cydlh5RAhSLmw7vV5z6dOSxtDk2IszD7bm5gz72zzRD4nbzYA=="
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    @MainActor static func expectFailure(_ message: String,
        matching predicate: (CursorUsageReader.ReadError) -> Bool = { _ in true },
        operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure(message)
        } catch let error as CursorUsageReader.ReadError {
            check(predicate(error), message)
        } catch {
            preconditionFailure("Unexpected error type: " + message)
        }
    }
    @MainActor static func run() async throws {
        var keychainLoads = 0
        func expectBackgroundBlocked() {
            expectFailure("Background refresh must not consult Keychain before explicit unlock", matching: {
                if case .keychainAccess(let status) = $0 { return status == errSecInteractionNotAllowed }
                return false
            }) {
                _ = try CursorUsageReader.readSafeStoragePassword(allowInteraction: false, loadPassword: {
                    keychainLoads += 1
                    return Data("must-not-load".utf8)
                })
            }
            check(keychainLoads == 0, "A blocked background read must not call its Keychain loader")
        }
        expectBackgroundBlocked()
        expectFailure("Failed explicit unlock must preserve the Keychain error", matching: {
            if case .keychainAccess(let status) = $0 { return status == errSecAuthFailed }
            return false
        }) {
            _ = try CursorUsageReader.readSafeStoragePassword(allowInteraction: true, loadPassword: {
                throw CursorUsageReader.ReadError.keychainAccess(errSecAuthFailed)
            })
        }
        expectBackgroundBlocked()
        expectFailure("Empty Keychain results must never populate the cache", matching: {
            if case .unsupportedLogin = $0 { return true }; return false
        }) {
            _ = try CursorUsageReader.readSafeStoragePassword(allowInteraction: true, loadPassword: { Data() })
        }
        expectBackgroundBlocked()
        let unlocked = try CursorUsageReader.readSafeStoragePassword(allowInteraction: true, loadPassword: {
            keychainLoads += 1
            return password
        })
        check(unlocked == password && keychainLoads == 1, "Explicit unlock must load and cache the key")
        let cached = try CursorUsageReader.readSafeStoragePassword(allowInteraction: false, loadPassword: {
            keychainLoads += 1
            return Data("must-not-load".utf8)
        })
        check(cached == password && keychainLoads == 1, "Background refresh must use only the in-memory key")
        let replacement = Data("replacement-fixture-password".utf8)
        let reloaded = try CursorUsageReader.readSafeStoragePassword(allowInteraction: true, loadPassword: {
            keychainLoads += 1
            return replacement
        })
        check(reloaded == replacement && keychainLoads == 2, "A later explicit refresh must reload the key")
        let replaced = try CursorUsageReader.readSafeStoragePassword(allowInteraction: false, loadPassword: {
            keychainLoads += 1
            return password
        })
        check(replaced == replacement && keychainLoads == 2, "Background refresh must see the replaced cached key")
        expectFailure("Failed reload must not replace the last unlocked key") {
            _ = try CursorUsageReader.readSafeStoragePassword(allowInteraction: true, loadPassword: {
                throw CursorUsageReader.ReadError.keychainAccess(errSecAuthFailed)
            })
        }
        let retained = try CursorUsageReader.readSafeStoragePassword(allowInteraction: false, loadPassword: {
            preconditionFailure("Cached reads must not reach Keychain")
        })
        check(retained == replacement, "Failed reload must retain the prior cached key")

        var passwordReads = 0
        let plain = try CursorUsageReader.decodeAccessToken(token, password: {
            passwordReads += 1
            return password
        })
        check(plain == token && passwordReads == 0, "Legacy plaintext must bypass Keychain access")
        let decoded = try CursorUsageReader.decodeAccessToken(encrypted, password: {
            passwordReads += 1
            return password
        })
        check(decoded == token && passwordReads == 1, "Chromium v10 must decrypt the independent fixture")
        expectFailure("Denied Keychain access must remain distinguishable", matching: {
            if case .keychainAccess(let status) = $0 { return status == errSecAuthFailed }
            return false
        }) {
            _ = try CursorUsageReader.decodeAccessToken(encrypted, password: {
                throw CursorUsageReader.ReadError.keychainAccess(errSecAuthFailed)
            })
        }
        expectFailure("Wrong keys must not produce a request token") {
            _ = try CursorUsageReader.decodeAccessToken(encrypted, password: { Data("wrong-fixture-password".utf8) })
        }
        for stored in ["", "fixture\r\nInjected: header", "fixture\n", "fixture\r", "fixture\tvalue", "fixture\u{0}value"] {
            expectFailure("Empty values and header controls must be rejected") {
                _ = try CursorUsageReader.decodeAccessToken(stored, password: { password })
            }
        }
        for stored in [
            "cursor-safe-storage:v1:%%%",
            "cursor-safe-storage:v1:",
            "cursor-safe-storage:v1:" + Data("v11".utf8).base64EncodedString(),
            "cursor-safe-storage:v1:" + Data("v10short".utf8).base64EncodedString(),
            "cursor-safe-storage:v2:" + Data("unsupported".utf8).base64EncodedString()
        ] {
            expectFailure("Malformed or unsupported encrypted values must never become bearer tokens") {
                _ = try CursorUsageReader.decodeAccessToken(stored, password: { password })
            }
        }
        var corrupt = Data(base64Encoded: String(encrypted.dropFirst("cursor-safe-storage:v1:".count)))!
        corrupt[corrupt.count - 1] ^= 0xff
        expectFailure("Corrupt ciphertext must be rejected") {
            _ = try CursorUsageReader.decodeAccessToken("cursor-safe-storage:v1:" + corrupt.base64EncodedString(),
                                                       password: { password })
        }
        expectFailure("401 must report failed authentication", matching: {
            if case .loginExpired = $0 { return true }; return false
        }) {
            _ = try CursorUsageReader.decodeResponse(Data("{}".utf8), statusCode: 401)
        }
        expectFailure("403 must preserve permission refusal instead of claiming expired login", matching: {
            if case .httpStatus(403) = $0 { return true }; return false
        }) {
            _ = try CursorUsageReader.decodeResponse(Data("{}".utf8), statusCode: 403)
        }
        check(CursorUsageReader.ReadError.httpStatus(403).errorDescription !=
              CursorUsageReader.ReadError.loginExpired.errorDescription,
              "Permission and expired-login guidance must differ")
        expectFailure("Other HTTP errors must retain their status", matching: {
            if case .httpStatus(500) = $0 { return true }; return false
        }) {
            _ = try CursorUsageReader.decodeResponse(Data("{}".utf8), statusCode: 500)
        }
        expectFailure("Invalid responses must remain unsupported") {
            _ = try CursorUsageReader.decodeResponse(Data("invalid JSON".utf8), statusCode: 200)
        }
        expectFailure("Missing plan data must not publish empty usage") {
            _ = try CursorUsageReader.decodeResponse(Data("{}".utf8), statusCode: 200)
        }
        let snapshot = try CursorUsageReader.decodeResponse(Data(
            #"{"planUsage":{"autoPercentUsed":20,"apiPercentUsed":30,"totalPercentUsed":25},"billingCycleEnd":"1700000000000"}"#.utf8), statusCode: 200)
        check(snapshot.planUsage?.totalRemaining == 75 && snapshot.planUsage?.cursorModelsRemaining == 80 &&
              snapshot.planUsage?.otherModelsRemaining == 70, "Successful responses must retain usage fields")
        check(snapshot.billingCycleEnd == Date(timeIntervalSince1970: 1_700_000_000),
              "Billing-cycle milliseconds must decode correctly")

        let attempts = Attempts()
        let monitor = CursorUsageMonitor(refreshInterval: 3600, readSnapshot: { allowInteraction in
            try await attempts.read(allowInteraction)
        })
        await monitor.refresh()
        check(monitor.snapshot?.planUsage?.totalRemaining == 75 && monitor.message == nil,
              "Successful refresh must publish the snapshot")
        let updatedAt = monitor.updatedAt
        await monitor.refresh(allowKeychainInteraction: true)
        check(monitor.snapshot?.planUsage?.totalRemaining == 75 && monitor.updatedAt == updatedAt &&
              monitor.message != nil && !monitor.isRefreshing,
              "Failed manual refresh must retain prior data and timestamp, and finish refreshing")
        await monitor.refresh()
        let interactions = await attempts.interactions
        check(interactions == [false, true, false],
              "Only explicit manual refresh may allow Keychain interaction")
        let failed = CursorUsageMonitor(refreshInterval: 3600, readSnapshot: { _ in
            throw CursorUsageReader.ReadError.loginExpired
        })
        await failed.refresh()
        check(failed.snapshot == nil && failed.updatedAt == nil && failed.message != nil && !failed.isRefreshing,
              "Initial failure must not fabricate cached usage")
        print("Cursor usage: \(checks) checks, 0 failures; no real account, Keychain or network access")
        exit(0)
    }
    static func main() {
        Task { @MainActor in
            do { try await run() }
            catch { preconditionFailure("Unexpected fixture failure") }
        }
        RunLoop.main.run()
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-cursor-usage-") as temporary:
    directory = Path(temporary)
    swift = directory / "Check.swift"
    swift.write_text(source + fixture)
    binary = directory / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
