#!/usr/bin/env python3
"""Check that hover preserves the lift/highlight effects without rebuilding row content."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "HopWorld/Views/WarmCardHover.swift"
hover = source.read_text()
# Expose the production state setter only inside this isolated test app.
hover = hover.replace(
    "@Environment(\\.accessibilityReduceMotion) private var reduceMotion",
    'private var reduceMotion: Bool { CommandLine.arguments.contains("reduced") }',
).replace(
    "@State private var isHovered = false",
    "@Environment(\\.hoverTestID) private var hoverTestID\n    @State private var isHovered = false",
).replace(
    ".onHover { isHovered = $0 }",
    ".onHover { isHovered = $0 }\n        .onAppear { Probe.setHover[hoverTestID] = { isHovered = $0 } }",
)
fixture = r'''
import AppKit
import SwiftUI

private struct HoverTestID: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var hoverTestID: Int {
        get { self[HoverTestID.self] }
        set { self[HoverTestID.self] = newValue }
    }
}
@MainActor enum Probe {
    static var setHover: [Int: (Bool) -> Void] = [:]
    static var frames: [Int: CGRect] = [:]
    static var contentBuilds = 0
}
struct RowContent: View {
    let index: Int
    var body: some View {
        let _ = { Probe.contentBuilds += 1 }()
        HStack {
            Text("节点 \(index)")
            Text("VLESS · example.test:443 · 最后可用：2026/10/27")
            Spacer()
            Text("可用 · 0.15 秒")
        }
        .padding(12)
        .frame(height: 50)
        .background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("rows"))
                Color.clear
                    .onAppear { Probe.frames[index] = frame }
                    .onChange(of: frame) { _, value in Probe.frames[index] = value }
            }
        }
    }
}
@main struct Runner {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dark = CommandLine.arguments.contains("dark")
        let reduced = CommandLine.arguments.contains("reduced")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let rows = VStack(spacing: 8) {
            ForEach(0..<8) { index in
                RowContent(index: index)
                    .modifier(WarmCardHover(fill: index == 2 ? .green.opacity(0.2) : .clear,
                                            baseFill: dark ? Color(white: 0.1) : .white))
                    .environment(\.hoverTestID, index)
            }
        }
        .padding(20)
        .coordinateSpace(name: "rows")
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: rows)
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 900, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        settle(0.3)
        precondition(Probe.setHover.count == 8 && Probe.frames.count == 8)
        let initialFrames = Probe.frames
        let initialBuilds = Probe.contentBuilds
        let before = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: before)
        Probe.setHover[2]!(true)
        settle(0.2)
        let original = initialFrames[2]!
        let lifted = Probe.frames[2]!
        let scale: CGFloat = reduced ? 1 : 1.015
        precondition(abs(lifted.width - original.width * scale) < 0.1 &&
                     abs(lifted.height - original.height * scale) < 0.1,
                     "Hover lift effect changed")
        for index in 0..<8 where index != 2 {
            precondition(Probe.frames[index] == initialFrames[index], "Hover moved another row")
        }
        let during = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: during)
        precondition(before.tiffRepresentation != during.tiffRepresentation, "Hover feedback disappeared")
        let pixelScale = CGFloat(during.pixelsWide) / host.bounds.width
        let shadowX = Int((lifted.minX - 4) * pixelScale)
        let shadowY = Int(lifted.midY * pixelScale)
        let shadowAlpha = max(during.colorAt(x: shadowX, y: shadowY)!.alphaComponent,
                              during.colorAt(x: shadowX, y: during.pixelsHigh - 1 - shadowY)!.alphaComponent)
        precondition(shadowAlpha > 0.01, "Hover shadow was clipped")
        Probe.setHover[2]!(false)
        settle(0.2)
        let start = Date()
        for _ in 0..<20 {
            for index in 0..<8 {
                Probe.setHover[index]!(true)
                settle(0.002)
                Probe.setHover[index]!(false)
            }
        }
        settle(0.2)
        precondition(Probe.frames == initialFrames, "Hover did not restore row geometry")
        precondition(Probe.contentBuilds == initialBuilds, "Hover rebuilt foreground content")
        let after = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: after)
        precondition(before.tiffRepresentation == after.tiffRepresentation,
                     "Hover did not restore the selected row background")
        print("PASS", dark ? "dark" : "light", reduced ? "reduced" : "animated",
              "160 row sweeps; lift/highlight preserved; unchanged foreground builds; restored selection; seconds",
              Date().timeIntervalSince(start))
        window.close()
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-hover-check-") as directory:
    directory = Path(directory)
    swift = directory / "Fixture.swift"
    swift.write_text(hover + "\n" + fixture)
    binary = directory / "Check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    for arguments in [[], ["dark"], ["reduced"], ["dark", "reduced"]]:
        result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=30)
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(result.stderr)
