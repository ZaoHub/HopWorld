#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
task_build=$(mktemp -d "${TMPDIR:-/tmp}/hopworld-isolation-build.XXXXXXXX")
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -parse-as-library \
    "$task_root/HopWorld/Utilities/ProcessRunner.swift" \
    "$task_root/HopWorldShared/TunSessionStatus.swift" \
    "$task_root/HopWorldTunSupervisor/TunSupervisor.swift" \
    "$task_root/Scripts/Tests/TunProcessIsolationCheck.swift" \
    -o "$task_build/check"
"$task_build/check"
