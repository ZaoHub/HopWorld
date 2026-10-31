#!/usr/bin/env python3
"""Render the production subscription editor with inert service stubs.

Exercise scrollbars during scrolling, keyboard focus and both appearances without
loading the user's library, fetching subscriptions or changing system preferences.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src=(root/'HopWorld/Views/Subscriptions/SubscriptionListView.swift').read_text()
editor=src[src.index('private struct SubscriptionTimeWheel:'):src.index('\nstruct ImportLinksView:')]
editor=editor.replace('.onAppear { scrollValue = value }', '.onAppear { scrollValue = value; Driver.values[label] = value }')
editor=editor.replace('.onChange(of: value) { _, number in scrollValue = number }', '.onChange(of: value) { _, number in scrollValue = number; Driver.values[label] = number }')
editor=editor.replace('.focused($isFocused)', """.focused($isFocused)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FocusWheel"))) { _ in
            isFocused = label == "更新小时"
        }""")
editor=editor.replace('.accessibilityIdentifier("subscription-update-time")', '.accessibilityIdentifier("subscription-update-time").background(ButtonProbe(id: "time", text: String(format: "%02d:%02d", updateHour, updateMinute)))')
editor=editor.replace('.accessibilityIdentifier("subscription-update-time-done")', '.accessibilityIdentifier("subscription-update-time-done").background(ButtonProbe(id: "done"))')
editor=editor.replace('.accessibilityIdentifier("subscription-interval-count")', '.accessibilityIdentifier("subscription-interval-count").background(ButtonProbe(id: "count", text: "\\(updateIntervalCountText)|\\(canSave)"))')
editor=editor.replace('.onAppear(perform: load)', '''.onAppear(perform: load)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FixtureShareLinks"))) { note in
                shareLinksText = note.object as? String ?? ""
            }''')
editor=editor.replace('.disabled(!canSave)', '.disabled(!canSave).background(ButtonProbe(id: "save", text: String(canSave)))')
editor=editor.replace('dismiss()', 'Driver.dismissCalls += 1')
stubs=r'''
import AppKit
import SwiftUI
@MainActor enum Driver {
    static var values: [String: Int] = [:]
    static var probes: [String: NSView] = [:]
    static var texts: [String: String] = [:]
    static var saveCalls = 0
    static var dismissCalls = 0
    static var pastedLinks: [(UUID, String)] = []
    static let fixtureLink = "trojan://fixture@example.com:443#Fixture"
}
struct ButtonProbe: NSViewRepresentable {
    let id: String
    var text = ""
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Driver.probes[id] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { Driver.texts[id] = text }
}
struct FixtureSettings {
    var defaultUpdateHour=21; var defaultUpdateMinute=30; var defaultTimeZoneID="Asia/Shanghai"
    var defaultFallbackDays=3; var defaultUpdateMode:SubscriptionUpdateMode = .smartMerge
}
struct ParsedLinks {
    var validNodes:[Int]=[]
    var skippedLinksSummary:String { "" }
}
@MainActor enum NodeLinkParser {
    static func extractShareLinks(from text:String)->[String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == Driver.fixtureLink || trimmed == Data(Driver.fixtureLink.utf8).base64EncodedString()
            ? [Driver.fixtureLink] : []
    }
    static func parseLines(_ text:String)->ParsedLinks {
        ParsedLinks(validNodes: extractShareLinks(from: text).isEmpty ? [] : [1])
    }
}
@MainActor final class AppState:ObservableObject {
    var settings=FixtureSettings()
    var subscriptions:[Subscription]=[]
    var statusBanner=""
    let subscriptionManager=SubscriptionManager()
    func subscription(for id:UUID)->Subscription? {subscriptions.first {$0.id == id}}
    func addShareLinkSubscription(name:String,shareText:String) {}
    func addSubscription(name:String,url:String,urlMode:SubscriptionURLMode,template:String?,autoUpdate:Bool,fetchAfterInsert:Bool) { Driver.saveCalls += 1 }
    func updateSubscription(_ sub:Subscription,refreshAfterSave:Bool=false) { Driver.saveCalls += 1 }
    func refreshSubscription(_ id:UUID,fetchYesterdayFirst:Bool=false) async {}
    func cleanupUnavailableNodes(subscriptionID:UUID,automatic:Bool) {}
    func applyShareLinkPaste(subscriptionID:UUID,pastedText:String) async { Driver.pastedLinks.append((subscriptionID, pastedText)) }
}
struct SubscriptionManager {
    func detectDateTemplate(for value:String)->DateTemplateDetection {SubscriptionDateTemplateDetector.detect(from:value)}
}
@main struct Checks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        // These settings apply only to this disposable fixture process.
        UserDefaults.standard.setVolatileDomain(["AppleShowScrollBars":"Always"],forName:UserDefaults.argumentDomain)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let state=AppState()
        var subscription=Subscription(name:"示例订阅",originalURL:"https://example.com/subscription",updateHour:21,updateMinute:30)
        let shareCase = CommandLine.arguments.first { $0.hasPrefix("share-") }
        if shareCase != nil {
            subscription.sourceKind = .shareLinks
            subscription.originalURL = "share://links"
            subscription.shareLinksText = "trojan://existing@example.com:443#Existing"
            subscription.autoUpdate = false
        }
        if CommandLine.arguments.contains("hours") { subscription.updateInterval = .hours(10) }
        subscription.lastSuccessAt=Date()
        state.subscriptions=[subscription]
        let mode:SubscriptionEditorMode=CommandLine.arguments.contains("create") ? .create : .edit(subscription)
        let host=NSHostingView(rootView:SubscriptionEditorView(mode:mode).environmentObject(state))
        host.frame=CGRect(x:0,y:0,width:580,height:670)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="订阅编辑器 · 交互验证"
        window.isReleasedWhenClosed=false
        window.contentView=host
        window.center()
        window.makeKeyAndOrderFront(nil)
        func settle(_ seconds:Double=0.35) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
        func scrolls(_ view:NSView)->[NSScrollView] {
            ((view as? NSScrollView).map{[$0]} ?? [])+view.subviews.flatMap(scrolls)
        }
        func click(_ id: String, offset: CGPoint = .zero) {
            let view = Driver.probes[id]!
            let window = view.window!
            let point = view.convert(CGPoint(x:view.bounds.midX+offset.x,y:view.bounds.midY+offset.y),to:nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],
                    timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,
                    context:nil,eventNumber:1,clickCount:1,pressure:1)!
                NSApp.postEvent(event,atStart:true)
                if let queued=NSApp.nextEvent(matching:[.leftMouseDown,.leftMouseUp],until:Date(),inMode:.default,dequeue:true) {
                    NSApp.sendEvent(queued)
                }
            }
        }
        func visibleWheels()->[NSScrollView] {
            NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(scrolls).filter{abs($0.frame.height-84)<1}
        }
        func capture(_ suffix:String,view:NSView) throws {
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/hopworld-editor-\(suffix).png"))
        }
        settle()
        if let shareCase {
            let input: String
            switch shareCase {
            case "share-blank": input = " \n\t "
            case "share-invalid": input = "invalid-base64?!"
            case "share-valid": input = " \n" + Driver.fixtureLink + "\r\n "
            case "share-base64": input = Data(Driver.fixtureLink.utf8).base64EncodedString()
            default: fatalError("Unknown share editor case")
            }
            NotificationCenter.default.post(name: Notification.Name("FixtureShareLinks"), object: input)
            settle()
            click("save")
            settle()
            switch shareCase {
            case "share-invalid":
                precondition(Driver.saveCalls == 0, "Invalid pasted text must not silently save settings")
                precondition(Driver.pastedLinks.isEmpty, "Invalid pasted text must not be appended")
                precondition(Driver.dismissCalls == 0, "Invalid pasted text must leave the editor open")
                precondition(state.statusBanner == "未解析到有效节点", "Invalid pasted text must report its validation failure")
            case "share-blank":
                precondition(Driver.saveCalls == 1, "Blank pasted text must still save settings")
                precondition(Driver.pastedLinks.isEmpty, "Blank pasted text must not replace the saved links")
                precondition(Driver.dismissCalls == 1, "Settings-only save must dismiss the editor")
            default:
                precondition(Driver.saveCalls == 1, "Valid pasted text must save settings")
                precondition(Driver.pastedLinks.count == 1, "Valid pasted text must be appended once")
                precondition(Driver.pastedLinks[0].0 == subscription.id, "Pasted links must go to the edited group")
                precondition(Driver.pastedLinks[0].1 == input.trimmingCharacters(in: .whitespacesAndNewlines), "Pasted text must reach the append action unchanged except for surrounding whitespace")
                precondition(Driver.dismissCalls == 1, "Valid pasted text must dismiss the editor")
            }
            window.close()
            print("PASS: \(shareCase) exercises the production editor save action")
            return
        }
        let outer=scrolls(host).max(by:{$0.frame.height < $1.frame.height})!
        var point=outer.contentView.bounds.origin
        point.y=310
        outer.contentView.scroll(to:point)
        outer.reflectScrolledClipView(outer.contentView)
        settle()
        precondition(visibleWheels().isEmpty,"Time wheels must be collapsed initially")
        for action in ["return", "escape", "blank"] {
            let previous=Driver.texts["count"]
            click("count")
            settle()
            let editor=window.firstResponder as! NSTextView
            precondition(editor.isEditable,"Clicking inside the number must allow editing")
            if action == "blank" {
                click("count", offset:CGPoint(x:-100,y:0))
            } else {
                let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,characters:action == "return" ? "\r" : "\u{1B}",
                    charactersIgnoringModifiers:action == "return" ? "\r" : "\u{1B}",isARepeat:false,keyCode:action == "return" ? 36 : 53)!
                window.sendEvent(key)
            }
            settle()
            precondition(window.firstResponder !== editor,"Number editing must end after \(action)")
            precondition(Driver.texts["count"] == previous,"Ending editing must preserve the number")
            precondition(Driver.saveCalls == 0,"Return must end editing without saving the subscription")
        }
        try capture("number-finished",view:host)
        print("PASS: number click enters editing; Return, Escape and blank click release the field editor")
        if CommandLine.arguments.contains("hours") {
            precondition(Driver.probes["time"]?.window == nil,"Hourly schedules must not show a time picker")
            precondition(Driver.texts["count"] == "10|true")
            for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                NSApp.appearance=NSAppearance(named:appearance)
                host.appearance=NSAppearance(named:appearance)
                settle()
                try capture("hours-10-\(appearance.rawValue)",view:host)
            }
            window.close()
            print("PASS: custom 10-hour editor, compact layout, no fixed-time picker, light/dark")
            return
        }
        for value in ["10", "0", "abc", "1000", "1"] {
            click("count")
            let field=window.firstResponder as! NSTextView
            field.selectAll(nil)
            field.insertText(value,replacementRange:field.selectedRange())
            settle()
            let valid=(Int(value).map { SubscriptionInterval.validCounts.contains($0) } ?? false) && !CommandLine.arguments.contains("create")
            precondition(Driver.texts["count"] == "\(value)|\(valid)","Numeric input must update validation")
        }
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            NSApp.appearance=NSAppearance(named:appearance)
            host.appearance=NSAppearance(named:appearance)
            settle()
            let prefix=CommandLine.arguments.contains("create") ? "create" : "edit"
            try capture("\(prefix)-\(appearance.rawValue)-collapsed",view:host)
            click("time")
            settle()
            let wheels=visibleWheels()
            precondition(wheels.count==2,"Clicking time must show two wheels")
            let popoverWindow=wheels[0].window!
            for wheel in wheels {
                wheel.flashScrollers()
                let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-28,wheel2:0,wheel3:0)!
                wheel.scrollWheel(with:NSEvent(cgEvent:event)!)
            }
            settle(0.02)
            popoverWindow.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name:Notification.Name("FocusWheel"),object:nil)
            settle()
            let hourBefore=Driver.values["更新小时"]!
            let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                     windowNumber:popoverWindow.windowNumber,context:nil,characters:"\u{F700}",charactersIgnoringModifiers:"\u{F700}",isARepeat:false,keyCode:126)!
            popoverWindow.sendEvent(key)
            settle()
            precondition(Driver.values["更新小时"] == hourBefore-1,"Focused hour must respond to the up arrow")
            for wheel in wheels {
                precondition(!wheel.hasVerticalScroller,"Wheel must never display a vertical scrollbar")
                precondition(!wheel.hasHorizontalScroller)
            }
            try capture("\(prefix)-\(appearance.rawValue)-expanded",view:popoverWindow.contentView!)
            let chosenHour=Driver.values["更新小时"]!
            let chosenMinute=Driver.values["更新分钟"]!
            click("done")
            settle()
            precondition(visibleWheels().isEmpty,"Done must collapse the picker")
            let expected=String(format:"%02d:%02d",chosenHour,chosenMinute)
            precondition(Driver.texts["time"] == expected,
                         "Collapsed button must show the selected time")
            // A second click must reopen at the saved selection.
            click("time")
            settle()
            precondition(Driver.values["更新小时"] == chosenHour && Driver.values["更新分钟"] == chosenMinute)
            click("done")
            settle()
            precondition(visibleWheels().isEmpty)
        }
        window.close()
        print("PASS: create/edit collapsed state, click to open, scrolling/keyboard, Done dismiss/reopen, selected time, light/dark")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-editor-check-") as directory:
    directory = Path(directory)
    swift = directory / "Fixture.swift"
    swift.write_text(stubs + "\n" + editor)
    binary = directory / "Check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "HopWorld/Models/Subscription.swift"),
                    str(root / "HopWorld/Services/Subscription/SubscriptionDateTemplate.swift"),
                    str(swift), "-o", str(binary)], check=True)
    for mode in ["edit", "create", "hours", "share-blank", "share-invalid", "share-valid", "share-base64"]:
        subprocess.run([str(binary), mode], check=True, timeout=30)

