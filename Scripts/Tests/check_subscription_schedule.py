#!/usr/bin/env python3
"""Check actual subscription scheduling and time wheels without loading the user's library."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
manager = (root / "HopWorld/Services/Subscription/SubscriptionManager.swift").read_text()
start = manager.index("    func computeNextUpdateAt(")
method = manager[start:manager.index("\n    }", start) + len("\n    }")]
view = (root / "HopWorld/Views/Subscriptions/SubscriptionListView.swift").read_text()
wheel = view[view.index("private struct SubscriptionTimeWheel:"):view.index("\nenum SubscriptionEditorMode")]
# Observe the actual rendered rows, without changing their layout or behavior.
wheel = wheel.replace(".id(number)", """.id(number)
                    .background(GeometryReader { proxy in
                        let rect = proxy.frame(in: .global)
                        Color.clear.onAppear { Driver.rows[label, default: [:]][number] = rect }
                            .onChange(of: rect) { _, rect in Driver.rows[label, default: [:]][number] = rect }
                    })""")
wheel = wheel.replace(".frame(width: 56, height: 84)", """.frame(width: 56, height: 84)
        .background(GeometryReader { proxy in
            let rect = proxy.frame(in: .global)
            Color.clear.onAppear { Driver.viewports[label] = rect }
                .onChange(of: rect) { _, rect in Driver.viewports[label] = rect }
        })""")
fixture = r'''
import SwiftUI
import AppKit
@MainActor struct Scheduler {
__METHOD__
}
@MainActor enum Driver {
    static var rows: [String: [Int: CGRect]] = [:]
    static var viewports: [String: CGRect] = [:]
}
@MainActor final class Values: ObservableObject {
    @Published var hour = 8
    @Published var minute = 30
}
struct Fixture: View {
    @ObservedObject var values: Values
    var body: some View {
        Form {
            LabeledContent("更新时间") {
                HStack(spacing: 8) {
                    SubscriptionTimeWheel(value: $values.hour, range: 0...23, label: "更新小时")
                    Text("时")
                    SubscriptionTimeWheel(value: $values.minute, range: 0...59, label: "更新分钟")
                    Text("分")
                }
            }
        }.formStyle(.grouped).padding().frame(width: 580, height: 180)
    }
}
@main struct Checks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let scheduler = Scheduler()
        let now = ISO8601DateFormatter().date(from: "2026-10-27T04:12:34Z")!
        var sub = Subscription(name: "Fixture", originalURL: "https://example.com", updateInterval: .hourly)
        for (interval, hours) in [(SubscriptionInterval.hourly, 1), (.every6Hours, 6), (.every12Hours, 12), (.hours(10), 10), (.hours(999), 999)] {
            sub.updateInterval = interval
            precondition(scheduler.computeNextUpdateAt(for: sub, from: now) == now.addingTimeInterval(Double(hours) * 3600))
            precondition(!interval.usesTimeOfDay)
            precondition(tryRoundTrip(sub) == sub)
        }
        for (raw, expected) in [("hourly", SubscriptionInterval.hourly), ("every6Hours", .every6Hours),
                                ("every12Hours", .every12Hours), ("daily", .daily),
                                ("every2Days", .every2Days), ("weekly", .weekly), ("manual", .manual)] {
            let data = Data("\"\(raw)\"".utf8)
            let interval = try JSONDecoder().decode(SubscriptionInterval.self, from: data)
            precondition(interval == expected)
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sub)) as! [String: Any]
            json["updateInterval"] = raw
            let restored = try JSONDecoder().decode(Subscription.self, from: JSONSerialization.data(withJSONObject: json))
            precondition(restored.updateInterval == expected)
        }
        for json in [#"{"count":0,"unit":"hours"}"#, #"{"count":-1,"unit":"days"}"#,
                     #"{"count":1000,"unit":"weeks"}"#, #"{"count":1.5,"unit":"hours"}"#,
                     #"{"count":1,"unit":"invalid"}"#, #""unknown""#] {
            do {
                _ = try JSONDecoder().decode(SubscriptionInterval.self, from: Data(json.utf8))
                preconditionFailure("Invalid interval was accepted")
            } catch { }
        }
        for (interval, days) in [(SubscriptionInterval.daily, 1), (.every2Days, 2), (.weekly, 7), (.days(10), 10), (.weeks(2), 14)] {
            sub.updateInterval = interval
            precondition(interval.usesTimeOfDay)
            let expected = ISO8601DateFormatter().date(from: "2026-10-27T00:30:00Z")!.addingTimeInterval(Double(days) * 86400)
            precondition(scheduler.computeNextUpdateAt(for: sub, from: now) == expected)
            precondition(tryRoundTrip(sub) == sub)
            let early = ISO8601DateFormatter().date(from: "2026-10-26T23:00:00Z")!
            precondition(scheduler.computeNextUpdateAt(for: sub, from: early) == ISO8601DateFormatter().date(from: "2026-10-27T00:30:00Z")!)
        }
        sub.timeZoneID = "America/Los_Angeles"
        sub.updateInterval = .days(1)
        let dst = ISO8601DateFormatter().date(from: "2026-03-07T17:00:00Z")!
        precondition(scheduler.computeNextUpdateAt(for: sub, from: dst) == ISO8601DateFormatter().date(from: "2026-03-08T15:30:00Z")!)
        sub.autoUpdate = false
        precondition(scheduler.computeNextUpdateAt(for: sub, from: now) == nil)
        sub.autoUpdate = true
        sub.updateInterval = .manual
        precondition(scheduler.computeNextUpdateAt(for: sub, from: now) == nil)
        print("PASS: custom hours/days/weeks, legacy libraries, persistence, invalid data, calendar/DST, disabled/manual")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let values = Values()
        let host = NSHostingView(rootView: Fixture(values: values))
        host.frame = CGRect(x: 0, y: 0, width: 580, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -2000, y: -2000))
        window.orderFrontRegardless()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
        }
        func check(_ hour: Int, _ minute: Int) {
            settle()
            precondition(values.hour == hour && values.minute == minute, "Wheel changed loaded value: \(values.hour):\(values.minute)")
            let rows = [Driver.rows["更新小时"]?[hour], Driver.rows["更新分钟"]?[minute]]
            precondition(rows.allSatisfy { $0 != nil }, "Selected rows must be rendered")
            let wheels = scrolls(host).filter { abs($0.frame.height - 84) < 1 }
            precondition(wheels.count == 2, "Expected two wheels, got \(scrolls(host).map { $0.frame })")
            for (label, row) in zip(["更新小时", "更新分钟"], rows) {
                let centerY = Driver.viewports[label]!.midY
                precondition(abs(row!.midY - centerY) < 2, "Selected row is not centered: \(row!) vs \(centerY)")
            }
        }
        check(8, 30)
        values.hour = 23; values.minute = 59; check(23, 59)
        values.hour = 0; values.minute = 0; check(0, 0)
        values.hour = 12; values.minute = 45; check(12, 45)
        let wheels = scrolls(host).filter { abs($0.frame.height - 84) < 1 }
        for wheel in wheels {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                wheel1: -28, wheel2: 0, wheel3: 0)!
            wheel.scrollWheel(with: NSEvent(cgEvent: event)!)
        }
        check(13, 46)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            settle()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/hopworld-time-wheel-\(appearance.rawValue).png"))
        }
        window.close()
        print("PASS: initial/edit values, 00:00/23:59 bounds, scroll binding, light/dark rendering")
    }
    static func tryRoundTrip(_ sub: Subscription) -> Subscription {
        try! JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(sub))
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-schedule-check-") as directory:
    directory = Path(directory)
    swift = directory / "Fixture.swift"
    swift.write_text(fixture.replace("__METHOD__", method) + "\n" + wheel)
    binary = directory / "Check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(root / "HopWorld/Models/Subscription.swift"), str(swift), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(result.stderr)
