#!/usr/bin/env python3
"""Check production view-setting commits without launching network services."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "HopWorld/App/AppState.swift").read_text()


def method(signature):
    start = source.index("    " + signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


commit = method("func updateSettings(_ mutate: (inout AppSettings) -> Void)")
# Keep production mutation, validation and equality checks; replace service effects.
commit = commit[:commit.index("        let probeTargetsChanged")]
commit += "        _ = previousLaunchAtLogin\n        settings = updated\n        commits += 1\n    }"

fixture = r'''
import Foundation
import Combine

struct AppSettings: Equatable {
    var launchAtLogin = false
    var autoAppProbeUsableNodes = true
    var screenLockDisconnectDelayMinutes = 5
    var scheduledTestIntervalMinutes = 60
    var connectTimeoutSeconds = 15
    var missingExitIPTimeoutSeconds = 10
    static func normalizedMissingExitIPTimeout(_ seconds: Int) -> Int {
        [0, 5, 10, 15, 20].contains(seconds) ? seconds : 10
    }
    var theme = "system"
}
@MainActor final class AppState {
    @Published var settings = AppSettings()
    var commits = 0
__METHODS__
}

@main struct Checks {
    @MainActor static func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor static func main() async {
        let state = AppState()
        var insideViewUpdate = true
        var publications = 0
        let observation = state.$settings.dropFirst().sink { _ in
            precondition(!insideViewUpdate, "A view binding published synchronously")
            publications += 1
        }

        state.updateSettingsFromView { $0.theme = "dark" }
        precondition(state.settings.theme == "system")
        precondition(publications == 0)
        insideViewUpdate = false
        await drain()
        precondition(state.settings.theme == "dark" && publications == 1)

        // Reconciliation can resubmit the current value; it must not publish again.
        state.updateSettingsFromView { $0.theme = "dark" }
        await drain()
        precondition(publications == 1 && state.commits == 1)

        // Each queued edit applies to the latest settings, preserving other edits.
        state.updateSettingsFromView { $0.autoAppProbeUsableNodes = false }
        state.updateSettingsFromView { $0.theme = "light" }
        state.updateSettings { $0.launchAtLogin = true }
        await drain()
        precondition(state.settings.launchAtLogin)
        precondition(!state.settings.autoAppProbeUsableNodes)
        precondition(state.settings.theme == "light")

        state.updateSettingsFromView { $0.theme = "dark" }
        state.updateSettingsFromView { $0.theme = "system" }
        await drain()
        precondition(state.settings.theme == "system")

        // Programmatic updates remain immediate, and validation still runs.
        state.updateSettings {
            $0.screenLockDisconnectDelayMinutes = -1
            $0.scheduledTestIntervalMinutes = 1
            $0.connectTimeoutSeconds = 999
        }
        precondition(state.settings.connectTimeoutSeconds == 99)
        precondition(state.settings.screenLockDisconnectDelayMinutes == 0)
        precondition(state.settings.scheduledTestIntervalMinutes == 5)
        let previousPublications = publications
        state.updateSettings {
            $0.screenLockDisconnectDelayMinutes = -1
            $0.scheduledTestIntervalMinutes = 1
        }
        precondition(publications == previousPublications)
        state.updateSettings { $0.connectTimeoutSeconds = -1 }
        precondition(state.settings.connectTimeoutSeconds == 1)
        state.updateSettings { $0.connectTimeoutSeconds = 15 }
        precondition(state.settings.connectTimeoutSeconds == 15)

        var released: AppState? = AppState()
        let isReleased = { [weak released] in released == nil }
        released?.updateSettingsFromView { _ in preconditionFailure("Released state was mutated") }
        released = nil
        await drain()
        precondition(isReleased())
        withExtendedLifetime(observation) {}
        print("View settings checks passed: deferred publications, no-op suppression, latest-value edits, ordering, validation and released state")
    }
}
'''
fixture = fixture.replace("__METHODS__", method("func updateSettingsFromView(") + "\n" + commit)
with tempfile.TemporaryDirectory(prefix="hopworld-view-settings-") as directory:
    swift = Path(directory) / "Check.swift"
    executable = Path(directory) / "check"
    swift.write_text(fixture)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
