#!/usr/bin/env python3
"""Exercise production List filter resets, scrolling, and lazy menus in a macOS fixture.

Uses 5,000 synthetic rows; never loads the user's library or changes network settings.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "HopWorld/Views/Countries/CountryListView.swift").read_text()
start = source.index("struct NodeListView: View")
body_start = source.index("    var body: some View {", start)
body = source[body_start:source.index("\n        .onChange(of: appState.preferredNodeCategory)", body_start)] + "\n    }"
body = body.replace(".background { FleetBackdrop(palette: palette) }", """.background { FleetBackdrop(palette: palette) }.background { Measure(viewport: true) }
                .onChange(of: highlightActive) { _, active in
                    if active {
                        Driver.highlights += 1
                        precondition(Driver.rect.map { Driver.viewport.contains($0) } ?? false,
                                     "Highlight started before target became visible")
                    }
                }""")
menu = source[source.index("private struct NodeRowContextMenu:"):source.index("\nstruct NodeRow: View")]
menu = menu.replace("private func makeMenu()", "fileprivate func makeMenu()")
fixture = r'''
import SwiftUI
import AppKit
struct Node: Identifiable {let id=UUID(); let index:Int}
struct Bay:Identifiable {var id:Int {startingNumber};var nodes:[Node]; var startingNumber:Int;var title:String {"Subscription"}}
enum Filter:String {case all,hidden,flat,favorites,smallSource}
struct Settings {
    var scope:Filter = .all
    var source:Filter = .all
    var nodeListCategoryRaw:String {"\(scope.rawValue)@@\(source.rawValue)"}
}
final class AppState:ObservableObject {
    @Published var focusNodeID:UUID?
    @Published var settings=Settings()
    var nodes:[Node]=(0..<5000).map{Node(index:$0)}
}
struct Palette {var subtext:Color {.secondary}}
struct FleetBayHeader:View {
    var index:Int;var title:String;var count:Int;var palette:Palette
    var body:some View {Text("\(index) \(title) \(count)").frame(height:29)}
}
struct FleetBackdrop:View {var palette:Palette;var body:some View {Color.gray.opacity(0.1)}}
@MainActor enum Driver {
    static var rowBuilds = 0
    static var locate:(()->Void)?
    static var rect:CGRect?
    static var viewport:CGRect = .zero
    static var highlights=0
}
struct Measure:View {
    var viewport=false
    var body:some View {GeometryReader {p in
        let frame=p.frame(in:.global)
        Color.clear.onAppear {record(frame)}.onChange(of:frame) {_,v in record(v)}
    }}
    func record(_ rect:CGRect) {if viewport {Driver.viewport=rect} else {Driver.rect=rect}}
}
struct Fixture:View {
    @EnvironmentObject var appState:AppState
    var reduceMotion:Bool {CommandLine.arguments.contains("reduced")}
    @State var search=""
    @State var selectedIDs:Set<UUID>=[]
    @State var highlightedNodeID:UUID?
    @State var highlightActive=false
    @State var locationRequestID:UUID?
    var palette:Palette {Palette()}
    var scope:Filter {appState.settings.scope}
    var source:Filter {appState.settings.source}
    var activeNodes:[Node] {appState.nodes}
    var filtered:[Node] {
        if scope == .hidden || source == .hidden || !search.isEmpty {return []}
        if scope == .favorites || source == .smallSource {return Array(activeNodes.suffix(6))}
        return activeNodes
    }
    var visibleNodeIDs:[UUID] {filtered.map(\.id)}
    var subscriptionSections:[Bay] {
        stride(from:0,to:activeNodes.count,by:250).map {
            Bay(nodes:Array(activeNodes[$0..<min($0+250,activeNodes.count)]),startingNumber:$0+1)
        }
    }
    func sorted(_ nodes:[Node])->[Node] {nodes}
    func persistFilter(scope:Filter,source:Filter) {
        DispatchQueue.main.async {appState.settings=Settings(scope:scope,source:source)}
    }
    var emptyNodeList:some View {Text("Empty")}
    var filterDeck:some View {Text("Filters").frame(height:100)}
    var header:some View {
        Button("Locate") {appState.focusNodeID=appState.nodes[target].id}
        .onAppear {Driver.locate={appState.focusNodeID=appState.nodes[target].id}}
        .frame(height:50)
    }
    let target:Int
    func nodeRow(for node:Node,sequenceNumber:Int,striped:Bool)->some View {
        let _ = { Driver.rowBuilds += 1 }()
        return Text("Node \(sequenceNumber)").frame(maxWidth:.infinity,alignment:.leading)
            .padding(.vertical,node.index % 3 == 0 ? 12:7)
            .background {if node.index == target {Measure()}}
            .listRowInsets(EdgeInsets(top:8,leading:16,bottom:8,trailing:16))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
    REPLACE_BODY
}
@main struct Runner {
    @MainActor static func main() {
        setbuf(stdout,nil)
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let args=CommandLine.arguments
        let target=Int(args[1])!
        checkMenu()
        let state=AppState()
        if args.contains("filtered") {state.settings.scope = .hidden}
        if args.contains("flat") {state.settings.source = .flat}
        if args.contains("transitions") {state.settings.scope = .favorites}
        if args.contains("favorites") {state.settings.scope = .favorites}
        if args.contains("smallSource") {state.settings.source = .smallSource}
        let host=NSHostingView(rootView:Fixture(target:target).environmentObject(state))
        host.frame=CGRect(x:0,y:0,width:980,height:640)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.setFrameOrigin(CGPoint(x:-2000,y:-2000));window.orderFrontRegardless()
        func settle(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
        settle(0.5)
        let initialBuilds = Driver.rowBuilds
        precondition(initialBuilds < state.nodes.count / 2, "List eagerly built offscreen rows: \(initialBuilds)")
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView($0) }.first
        }
        if args.contains("transitions") {
            for cycle in 1...3 {
                for smallFilter in [Settings(scope:.favorites), Settings(source:.smallSource)] {
                    state.settings = smallFilter
                    settle(0.15)
                    let previousTable = findScrollView(host)!.documentView as! NSTableView
                    precondition(previousTable.numberOfRows == 6, "Small filter lost its six nodes")
                    let before = Driver.rowBuilds
                    state.settings = Settings()
                    settle(0.15)
                    let table = findScrollView(host)!.documentView as! NSTableView
                    precondition(table.numberOfRows == state.nodes.count + 20,
                                 "All filter lost nodes or subscription headers")
                    let builds = Driver.rowBuilds - before
                    print("FILTER", smallFilter.nodeListCategoryRaw, "to all", "cycle", cycle,
                          "row builds", builds)
                    precondition(builds < state.nodes.count / 2,
                                 "Filter switch eagerly built offscreen rows: \(builds)")
                }
            }
        }
        let beforeScrollBuilds = Driver.rowBuilds
        if let scroll = findScrollView(host), state.settings.scope != .favorites,
           state.settings.source != .smallSource {
            let start = Date()
            for step in 1...12 {
                let y = min(CGFloat(step * 180), max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(0.02)
            }
            precondition(scroll.contentView.bounds.minY > 1000, "Scroll steps did not move the list")
            precondition(Driver.rowBuilds - beforeScrollBuilds < state.nodes.count / 2,
                         "Scrolling rebuilt the entire library")
            print("SCROLL", "initial row builds", initialBuilds, "after 12 scroll steps", Driver.rowBuilds,
                  "elapsed", Date().timeIntervalSince(start))
        } else if !args.contains("filtered") && !args.contains("favorites") && !args.contains("smallSource") {
            fatalError("Native list scroll view missing")
        }
        Driver.locate!()
        for _ in 0..<12 { settle(0.25) }
        guard let rect=Driver.rect else {fatalError("Target row never rendered")}
        let visible=Driver.viewport
        guard visible.contains(rect) else {fatalError("Target outside viewport after ONE click: \(rect)")}
        precondition(Driver.highlights == (args.contains("reduced") ? 1:3),"Wrong flash count: \(Driver.highlights)")
        print("PASS target",target,"one click + visible before highlight + flash count",Driver.highlights,rect)
        window.close()
    }
}
@MainActor private func checkMenu() {
    let button = NodeRowContextMenu.MenuButton()
    var builds = 0
    var actionCount = 0
    var favorite = false
    button.items = {
        builds += 1
        return [.action(favorite ? "取消收藏" : "收藏") { actionCount += 1 }, .separator]
    }
    precondition(builds == 0, "Menu should wait until opened")
    let first = button.makeMenu()
    precondition(builds == 1 && first.items[0].title == "收藏" && first.items[1].isSeparatorItem)
    precondition(NSApp.sendAction(first.items[0].action!, to: first.items[0].target, from: first.items[0]))
    favorite = true
    precondition(button.makeMenu().items[0].title == "取消收藏", "Menu must use current state")
    precondition(actionCount == 1)
}

'''
with tempfile.TemporaryDirectory(prefix="hopworld-scroll-check-") as directory:
    directory = Path(directory)
    swift = directory / "Fixture.swift"
    swift.write_text(fixture.replace("REPLACE_BODY", body) + "\n" + menu)
    binary = directory / "Check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    for arguments in [["5"], ["2500"], ["4999"], ["4500", "flat"],
                      ["4500", "filtered"], ["4500", "reduced"], ["4500", "transitions"],
                      ["4500", "favorites"], ["4500", "smallSource"]]:
        result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=30)
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(result.stderr)
print("PASS: lazy row creation, filter transitions, scrolling, distant location, filtered/flat lists, reduced motion, and menu actions")
