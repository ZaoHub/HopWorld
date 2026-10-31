#!/usr/bin/env python3
"""Check the production drag attachment without reading the user's subscriptions."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "HopWorld/Views/Countries/CountryListView.swift").read_text()
attachment = source[source.index("private struct SubscriptionGroupDragScroll:"):
                    source.index("struct NodeGroupLabel:")]

fixture = r'''
import AppKit
import SwiftUI

struct Fixture: View {
    let count: Int
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(0..<count, id: \.self) { index in
                    Button("Subscription \(index)") {}.fixedSize()
                }
            }
            .background(SubscriptionGroupDragScroll())
        }
    }
}

@main struct Check {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: AnyView(Fixture(count: 30)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        settle()
        let scroll = findScroll(host)!
        let gestures = scroll.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }
            .filter { $0.delegate is SubscriptionGroupDragScroll.DragAnchor }
        precondition(gestures.count == 1, "Attach one drag recognizer to the horizontal scroll view")
        let pan = gestures[0]
        precondition(pan.delaysPrimaryMouseButtonEvents, "Dragging must not also click a chip")
        // AppKit may ask to begin before updating the recognizer's translation.
        pan.setTranslation(.zero, in: scroll)
        precondition(pan.delegate!.gestureRecognizerShouldBegin!(pan),
                     "Overflow must allow dragging even when the initial translation is zero")
        host.rootView = AnyView(Fixture(count: 2))
        settle()
        precondition(!pan.delegate!.gestureRecognizerShouldBegin!(pan),
                     "Short content must keep normal mouse handling")
        SubscriptionGroupDragScroll.dismantleNSView(
            pan.delegate as! SubscriptionGroupDragScroll.DragAnchor, coordinator: ())
        precondition(!scroll.gestureRecognizers.contains { $0 === pan },
                     "Remove the drag recognizer when its view is dismantled")
        print("PASS: attachment, click delay, zero-translation start, short content, cleanup")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hopworld-subscription-drag-") as temp:
    folder = Path(temp)
    swift_file = folder / "Check.swift"
    binary = folder / "check"
    swift_file.write_text("import AppKit\nimport SwiftUI\n" + attachment + fixture)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift_file), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
