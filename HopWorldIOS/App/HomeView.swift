import SwiftUI
import Combine
import UIKit
import ImageIO
import NetworkExtension
import UniformTypeIdentifiers

private final class DefaultsObserver: ObservableObject {
    static let shared = DefaultsObserver()
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@propertyWrapper
private struct LegacyAppStorage<Value>: DynamicProperty {
    @ObservedObject private var observer = DefaultsObserver.shared
    private let key: String
    private let defaultValue: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

private struct MotionTimeline<Content: View>: View {
    let moving: Bool
    let content: (Date) -> Content

    init(moving: Bool, @ViewBuilder content: @escaping (Date) -> Content) {
        self.moving = moving
        self.content = content
    }

    @ViewBuilder var body: some View {
        if #available(iOS 15.0, *) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving)) { timeline in
                content(timeline.date)
            }
        } else {
            LegacyMotionTimeline(moving: moving, content: content)
        }
    }
}

private struct LegacyLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }
    var body: some View { HStack { Image(systemName: systemImage); Text(title) } }
}

private struct LegacyMotionTimeline<Content: View>: View {
    let moving: Bool
    let content: (Date) -> Content
    @State private var date = Date()
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        content(date).onReceive(timer) { date in
            if moving { self.date = date }
        }
    }
}

private struct GoldCutPanel: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = min(12, rect.height / 4, rect.width / 8)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }
}

private enum HopGold {
    static let gold = Color(red: 0.78, green: 0.58, blue: 0.30)
    static let light = Color(red: 1.0, green: 0.87, blue: 0.62)
    static let background = Color(red: 0.025, green: 0.024, blue: 0.022)
    static let metal = LinearGradient(colors: [light, gold, Color(red: 0.28, green: 0.18, blue: 0.09), light, gold], startPoint: .topLeading, endPoint: .bottomTrailing)
    static var row: some View { HopThemeRow() }
}

private struct HopThemeRow: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    var body: some View {
        if IOSTheme(rawValue: themeValue) == .xianxia {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.44), Color(red: 0.04, green: 0.25, blue: 0.27), Color(red: 0.025, green: 0.13, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HopGold.metal, lineWidth: 1.5))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(HopGold.light.opacity(0.35), lineWidth: 0.6).padding(3))
                .shadow(color: Color(red: 0, green: 0.5, blue: 0.5).opacity(0.2), radius: 4, y: 1)
                .padding(4)
        } else {
            GoldCutPanel()
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(red: 0.10, green: 0.09, blue: 0.075), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(GoldCutPanel().stroke(HopGold.metal, lineWidth: 2))
                .overlay(GoldCutPanel().stroke(HopGold.light.opacity(0.4), lineWidth: 0.6).padding(4))
                .shadow(color: HopGold.gold.opacity(0.25), radius: 4, y: 1)
                .padding(4)
        }
    }
}

private struct HopGoldBackdrop: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let xianxia = IOSTheme(rawValue: themeValue) == .xianxia
            let background = xianxia ? Color(red: 0.025, green: 0.10, blue: 0.13) : HopGold.background
            ZStack(alignment: .bottom) {
                background
                Image(xianxia ? "XianxiaBackdrop" : "BlackGoldBackdrop")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width)
                    .overlay(background.opacity(xianxia ? 0.65 : 0.35))
            }
        }
        .edgesIgnoringSafeArea(.all)
        .legacyAccessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private extension View {
    func legacyAccessibilityHidden(_ hidden: Bool) -> some View { accessibility(hidden: hidden) }
    func legacyAccessibilityLabel(_ label: String) -> some View { accessibility(label: Text(label)) }
    func legacyAccessibilityHint(_ hint: String) -> some View { accessibility(hint: Text(hint)) }
    func legacyAccessibilityValue(_ value: String) -> some View { accessibility(value: Text(value)) }
    func legacyAccessibilitySortPriority(_ priority: Double) -> some View { accessibility(sortPriority: priority) }
    func legacyAccessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { accessibility(addTraits: traits) }

    @ViewBuilder
    func hopGoldPage() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
                .background(HopGoldBackdrop())
                .accentColor(HopGold.light)
        } else {
            background(HopGoldBackdrop())
                .accentColor(HopGold.light)
        }
    }

    @ViewBuilder
    func homeListTopMargin() -> some View {
        if #available(iOS 17.0, *) {
            contentMargins(.top, 8, for: .scrollContent)
        } else {
            self
        }
    }

    func hopPageTitle(_ title: Text) -> some View {
        navigationBarTitle(title, displayMode: .inline)
            .background(HomeNavigationBar())
            .homeListTopMargin()
    }
}

/// Inline title still leaves the large-title gap unless the bar opts out.
private struct HomeNavigationBar: UIViewRepresentable {
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.theme = IOSTheme(rawValue: themeValue) ?? .blackGold
        uiView.updateNavigationBar()
    }

    final class Probe: UIView {
        var theme: IOSTheme = .blackGold
        private weak var configuredBar: UINavigationBar?
        private var configuredTheme: IOSTheme?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateNavigationBar()
        }

        func updateNavigationBar() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   let bar = controller.navigationController?.navigationBar {
                    bar.prefersLargeTitles = false
                    if configuredBar !== bar || configuredTheme != theme {
                        HopWorldIOSApp.configureNavigationBar(bar, theme: theme)
                        configuredBar = bar
                        configuredTheme = theme
                    }
                    return
                }
                responder = current.next
            }
        }
    }
}

private enum HomePage: String, Identifiable, CaseIterable {
    case countries = "国家"
    case nodes = "节点"
    case subscriptions = "订阅"

    var id: String { rawValue }
}

private struct ConnectingOrb: UIViewRepresentable {
    let animate: Bool

    private static let frames: [UIImage] = {
        guard let data = NSDataAsset(name: "XianxiaConnecting")?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            CGImageSourceCreateImageAtIndex(source, index, nil).map { UIImage(cgImage: $0) }
        }
    }()

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.image = Self.frames.first
        view.animationImages = Self.frames
        view.animationDuration = Double(Self.frames.count) * 0.14
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if animate && !view.isAnimating { view.startAnimating() }
        if !animate && view.isAnimating { view.stopAnimating() }
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: IOSLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSceneActive = UIApplication.shared.applicationState == .active
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue
    @State private var presentedPage: HomePage?
    @State private var showingTestTargets = false
    @State private var showingNodeDetails = false
    @State private var startingConnection = false
    @State private var simulatedConnection = false
    @State private var simulatedConnecting = false
    @State private var previewGeneration = 0

    private var isMotionPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--motion-preview")
        #else
        false
        #endif
    }

    private var displayStatus: NEVPNStatus {
        isMotionPreview ? (simulatedConnecting ? .connecting : (simulatedConnection ? .connected : .disconnected)) : library.status
    }

    private var theme: IOSTheme { IOSTheme(rawValue: themeValue) ?? .blackGold }
    private static let jadeDiscTexture: UIImage? = {
        guard let source = UIImage(named: "HomeXianxia")?.cgImage,
              let texture = source.cropping(to: CGRect(x: 250, y: 700, width: 80, height: 140)) else { return nil }
        return UIImage(cgImage: texture)
    }()

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        referenceHome(width: min(geometry.size.width, 520))
                    }
                    .frame(maxWidth: .infinity)
                }
                .background(statusBarBackground(width: min(geometry.size.width, 520), height: geometry.safeAreaInsets.top)
                    .offset(y: -geometry.safeAreaInsets.top), alignment: .top)
                .background((theme == .xianxia ? Color(red: 0.025, green: 0.10, blue: 0.13) : Color.black).edgesIgnoringSafeArea(.all))
            }
            .navigationBarHidden(true)
            .sheet(item: $presentedPage) { page in
                NavigationView {
                    Group {
                        switch page {
                        case .countries: CountryListView(onDone: { presentedPage = nil })
                        case .nodes: AllNodesView()
                        case .subscriptions: ImportView()
                        }
                    }
                    .hopPageTitle(Text(page.rawValue))
                    .navigationBarItems(trailing: Button { presentedPage = nil } label: {
                        if page == .subscriptions {
                            Image(systemName: "xmark")
                        } else {
                            Text("完成")
                        }
                    }.legacyAccessibilityLabel("完成"))
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .overlay(notice)
            }
            .sheet(isPresented: $showingTestTargets) {
                TestTargetPicker { Task { await library.measureSelected() } }
            }
            .sheet(isPresented: $showingNodeDetails) {
                NavigationView {
                    List {
                        nodeDetails
                    }
                    .hopGoldPage()
                    .hopPageTitle(Text("节点详情"))
                    .navigationBarItems(trailing: Button("完成") { showingNodeDetails = false })
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
            .onAppear {
                Task {
                    await library.tunnel.reload()
                    await library.refreshSelectedExit()
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in isSceneActive = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in isSceneActive = false }
        .overlay(notice)
    }

    private func statusBarBackground(width: CGFloat, height: CGFloat) -> some View {
        let scale = width / 863
        return ZStack(alignment: .topLeading) {
            Image(theme.assetName)
                .resizable()
                .frame(width: width, height: 1822 * scale)
                .offset(y: -75 * scale)
        }
        .frame(width: width, height: 1, alignment: .topLeading)
        .clipped()
        .scaleEffect(x: 1, y: max(height, 1), anchor: .bottom)
        .frame(width: width, height: height, alignment: .bottom)
        .blur(radius: theme == .xianxia ? 10 : 0, opaque: true)
        .clipped()
        .overlay(LinearGradient(colors: [Color.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
        .legacyAccessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func referenceHome(width: CGFloat) -> some View {
        let scale = width / 863
        let top: CGFloat = 75
        let height = (1822 - top) * scale
        let xianxia = theme == .xianxia
        let connectionY: CGFloat = xianxia ? 785 : 810
        let testY: CGFloat = xianxia ? 1333 : 1372
        return ZStack(alignment: .topLeading) {
            Image(xianxia ? "HomeXianxiaNoExamples" : "HomeReferenceNoExamples")
                .resizable()
                .frame(width: width, height: 1822 * scale)
                .offset(y: -top * scale)
                .legacyAccessibilityHidden(true)

            if xianxia || (isConnectionAnimating && !reduceMotion && isSceneActive) {
                connectionMotion(scale: scale, top: top, xianxia: xianxia, connectionY: connectionY)
                    .legacyAccessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            // The reference's disconnected artwork is accurate only in these states.
            if xianxia || (displayStatus != .disconnected && displayStatus != .invalid) {
            Group {
                if xianxia && isConnectionAnimating {
                    ConnectingOrb(animate: !reduceMotion && isSceneActive)
                        .frame(width: 445 * scale, height: 445 * scale)
                        .clipShape(Circle())
                } else if xianxia, let texture = Self.jadeDiscTexture {
                    Image(uiImage: texture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: (xianxia ? 440 : 410) * scale, height: (xianxia ? 440 : 410) * scale)
                        .clipped()
                        .clipShape(Circle())
                        .overlay(Circle().fill(Color(red: 0.02, green: 0.22, blue: 0.22).opacity(0.28)))
                } else {
                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.065), .black, Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
                .overlay(Circle().stroke(Color(red: 0.72, green: 0.52, blue: 0.25), lineWidth: max(0.5, scale)))
                .frame(width: (xianxia ? (isConnectionAnimating ? 445 : 440) : 410) * scale,
                       height: (xianxia ? (isConnectionAnimating ? 445 : 440) : 410) * scale)
                .position(x: 431 * scale, y: (connectionY - top) * scale)
                .legacyAccessibilityHidden(true)

            if xianxia {
                xianxiaClouds(scale: scale, top: top, connectionY: connectionY)
                    .allowsHitTesting(false)
                    .legacyAccessibilityHidden(true)
            }

            VStack(spacing: 12 * scale) {
                Image(systemName: "link")
                    .font(.system(size: 130 * scale, weight: .bold))
                Text(statusText)
                    .font(.system(size: 70 * scale, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(connectTitle)
                    .font(.system(size: max(12, 24 * scale), weight: .medium))
            }
            .foregroundColor(Color(red: 1, green: 0.88, blue: 0.63))
            .shadow(color: Color.orange.opacity(0.35), radius: 7 * scale)
            .frame(width: 390 * scale, height: 310 * scale)
            .position(x: 431 * scale, y: (connectionY - top) * scale)
            .legacyAccessibilityHidden(true)

            }

            if !isMotionPreview && library.selectedNode == nil && (displayStatus == .disconnected || displayStatus == .invalid) {
                Text("请先选择节点")
                    .font(.system(size: max(11, 23 * scale), weight: .medium))
                    .foregroundColor(Color(red: 1, green: 0.88, blue: 0.63))
                    .position(x: 431 * scale, y: ((xianxia ? 950 : 968) - top) * scale)
                    .legacyAccessibilityHidden(true)
            }

            metrics(scale: scale)
                .frame(width: 750 * scale, height: 60 * scale)
                .position(x: 431 * scale, y: ((xianxia ? 1230 : 1272) - top) * scale)
                .legacyAccessibilitySortPriority(2)

            ForEach(Array(HomePage.allCases.enumerated()), id: \.element.id) { index, page in
                Button { presentedPage = page } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .frame(width: 245 * scale, height: max(44, 94 * scale))
                .position(x: (165 + CGFloat(index) * 267) * scale, y: ((xianxia ? 414 : 419) - top) * scale)
                .legacyAccessibilityLabel(page.rawValue)
                .legacyAccessibilitySortPriority(4)
            }

            Button {
                if isMotionPreview {
                    previewGeneration += 1
                    let generation = previewGeneration
                    if simulatedConnection || simulatedConnecting {
                        simulatedConnection = false
                        simulatedConnecting = false
                    } else {
                        simulatedConnecting = true
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            guard previewGeneration == generation else { return }
                            simulatedConnecting = false
                            simulatedConnection = true
                        }
                    }
                    return
                }
                Task {
                    if displayStatus == .connected || displayStatus == .connecting || displayStatus == .reasserting {
                        library.disconnect()
                    } else {
                        startingConnection = true
                        await library.connect()
                        startingConnection = false
                    }
                }
            } label: {
                Color.clear.contentShape(Circle())
            }
            .frame(width: 460 * scale, height: 460 * scale)
            .position(x: 431 * scale, y: (connectionY - top) * scale)
            .disabled(connectDisabled)
            .legacyAccessibilityLabel("\(statusText)，\(connectTitle)")
            .legacyAccessibilityHint(!isMotionPreview && library.selectedNode == nil ? "请先选择节点" : "")
            .legacyAccessibilitySortPriority(3)

            HStack(spacing: 12 * scale) {
                if library.selectedNode?.lastTestStatus != .testing {
                    Image(systemName: "speedometer")
                        .font(.system(size: 40 * scale, weight: .semibold))
                }
                Text(library.selectedNode?.lastTestStatus == .testing ? "测试中" : "测延迟")
                    .font(.system(size: max(14, 40 * scale), weight: .bold))
            }
            .foregroundColor(Color(red: 1, green: 0.88, blue: 0.63))
            .opacity(library.selectedNode == nil ? 0.55 : 1)
            .position(x: 431 * scale, y: (testY - top) * scale)
            .legacyAccessibilityHidden(true)

            Button {
                if IOSSettings.selectedTestURLs.isEmpty {
                    showingTestTargets = true
                } else {
                    Task { await library.measureSelected() }
                }
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .frame(width: 330 * scale, height: max(44, 82 * scale))
            .position(x: 431 * scale, y: (testY - top) * scale)
            .disabled(library.selectedNode == nil || library.selectedNode?.lastTestStatus == .testing)
            .legacyAccessibilityLabel(library.selectedNode?.lastTestStatus == .testing ? "测试中" : "测延迟")
            .legacyAccessibilitySortPriority(1)

            Button { showingNodeDetails = true } label: {
                Image(systemName: "info")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(red: 1, green: 0.88, blue: 0.63))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill((xianxia ? Color(red: 0.02, green: 0.24, blue: 0.26) : Color.black).opacity(0.8)))
                    .overlay(Circle().stroke(Color(red: 0.72, green: 0.52, blue: 0.25), lineWidth: 1))
            }
            .position(x: 28, y: 25)
            .legacyAccessibilityLabel("节点详情")
            .legacyAccessibilitySortPriority(5)

            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Color(red: 1, green: 0.88, blue: 0.63))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill((xianxia ? Color(red: 0.02, green: 0.24, blue: 0.26) : Color.black).opacity(0.8)))
                    .overlay(Circle().stroke(Color(red: 0.72, green: 0.52, blue: 0.25), lineWidth: 1))
            }
            .position(x: width - 28, y: 25)
            .legacyAccessibilityLabel("设置")
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }

    private func metrics(scale: CGFloat) -> some View {
        let exit = library.selectedNode.map { library.exitPresentation(for: $0) }
        let values = [exit?.country ?? "—", library.selectedNode?.lastTestStatus == .testing ? "测试中" : (library.selectedNode?.latencyText ?? "—"), exit?.kind ?? "—"]
        let titles = ["出口国家", "延迟", "IP 属性"]
        return HStack(spacing: 0) {
            ForEach(0..<3) { index in
                Text(values[index])
                    .font(.system(size: max(14, 43 * scale), weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4 * scale)
                    .legacyAccessibilityLabel("\(titles[index])，\(values[index])")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var nodeDetails: some View {
        if let node = library.selectedNode {
            Section {
                detailRow("名称", node.displayTitle)
                detailRow("协议", node.protocolType.displayName)
                detailRow("节点地址", "\(node.server):\(node.port)")
                detailRow("传输", node.transportDisplayName)
                detailRow("安全", node.protocolType == .wireguard ? "WireGuard 内置加密" : node.security.displayName)
                detailRow("国家", "\(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node))) \(CountryResolver.effectiveCountry(for: node).name)")
                detailRow("出口 IP", library.exitPresentation(for: node).ip)
                detailRow("出口 IP 属性", library.exitPresentation(for: node).kind)
                detailRow("出口城市", exitDetails?.city ?? "未知")
                detailRow("出口运营商", exitDetails?.networkOperator ?? "未知")
                detailRow("ASN", exitDetails?.asn ?? "未知")
                detailRow("订阅", node.groupName(subscriptions: library.subscriptions))
            }
            .listRowBackground(theme == .xianxia ? Color(red: 0.04, green: 0.23, blue: 0.25) : Color(white: 0.12))
        } else {
            Text("还没有选择节点，请先前往节点或订阅")
                .font(.footnote)
                .foregroundColor(Color(red: 0.8, green: 0.7, blue: 0.53))
                .multilineTextAlignment(.center)
        }
    }

    private var exitDetails: IOSExitLookup.ExitIP? {
        if case .found(let exit) = library.exitQuery { return exit }
        return nil
    }

    private var notice: some View {
        VStack {
            Spacer()
            if library.lastError != nil {
                Text(library.lastError ?? "")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.9))
                    .cornerRadius(10)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
            }
        }
        .allowsHitTesting(false)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundColor(Color(red: 0.8, green: 0.7, blue: 0.53))
                .fixedSize(horizontal: true, vertical: false)
            Text(value).foregroundColor(.white).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }

    private var isConnectionAnimating: Bool {
        startingConnection || displayStatus == .connecting || displayStatus == .connected || displayStatus == .reasserting
    }

    private func connectionMotion(scale: CGFloat, top: CGFloat, xianxia: Bool, connectionY: CGFloat) -> some View {
        let moving = isConnectionAnimating && !reduceMotion && isSceneActive
        return MotionTimeline(moving: moving) { date in
            let time = moving ? date.timeIntervalSinceReferenceDate : 0
            let diameter: CGFloat = 700
            ZStack {
                if xianxia {
                    Image("XianxiaBackdrop")
                        .resizable()
                        .frame(width: 863 * scale, height: 1822 * scale)
                        .offset(x: (863 / 2 - 431) * scale, y: (1822 / 2 - connectionY) * scale)
                        .frame(width: diameter * scale, height: 650 * scale)
                        .mask(Ellipse().blur(radius: 8 * scale))

                    Image("XianxiaRing")
                        .resizable()
                        .frame(width: 660 * scale, height: 660 * scale)
                        .opacity(0.8)
                        .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 18) * 20))


                } else {
                    Image(theme.assetName)
                        .resizable()
                        .frame(width: 863 * scale, height: 1822 * scale)
                        .offset(x: (863 / 2 - 431) * scale, y: (1822 / 2 - connectionY) * scale)
                        .frame(width: 610 * scale, height: 610 * scale)
                        .clipped()
                        .mask(Circle().strokeBorder(lineWidth: 75 * scale))
                        .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 36) * 10))
                }
            }
            .frame(width: diameter * scale, height: diameter * scale)
            .position(x: 431 * scale, y: (connectionY - top) * scale)
        }
    }

    private func xianxiaClouds(scale: CGFloat, top: CGFloat, connectionY: CGFloat) -> some View {
        let moving = isConnectionAnimating && !reduceMotion && isSceneActive
        return MotionTimeline(moving: moving) { date in
            let time = moving ? date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Image("XianxiaCloudUpper")
                    .resizable()
                    .opacity(0.95)
                    .frame(width: 225 * scale, height: 225 * scale)
                    .scaleEffect(x: 1 + CGFloat(sin(time / 2.5)) * 0.08, y: 1 - CGFloat(sin(time / 2.5)) * 0.045)
                    .rotationEffect(.degrees(sin(time / 2.5) * 4))
                    .offset(x: (228 - 431) * scale, y: (645 - connectionY) * scale)
                Image("XianxiaCloudLower")
                    .resizable()
                    .opacity(0.95)
                    .frame(width: 275 * scale, height: 275 * scale)
                    .scaleEffect(x: 1 + CGFloat(sin(time / 2.8 + 1)) * 0.08, y: 1 - CGFloat(sin(time / 2.8 + 1)) * 0.045)
                    .rotationEffect(.degrees(sin(time / 2.8 + 1) * 4))
                    .offset(x: (605 - 431) * scale, y: (925 - connectionY) * scale)
            }
            .frame(width: 700 * scale, height: 700 * scale)
            .position(x: 431 * scale, y: (connectionY - top) * scale)
        }
    }

    private var connectDisabled: Bool {
        !isMotionPreview && (library.isBusy || (library.selectedNode == nil && displayStatus != .connected && displayStatus != .connecting && displayStatus != .reasserting))
    }

    private var statusText: String {
        switch displayStatus {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnecting: return "断开中"
        case .reasserting: return "重新连接"
        case .disconnected, .invalid: return "未连接"
        @unknown default: return "未知"
        }
    }

    private var connectTitle: String {
        switch displayStatus {
        case .connected, .connecting, .reasserting: return "点击断开"
        case .disconnecting: return "正在断开"
        default: return !isMotionPreview && library.selectedNode == nil ? "请先选择节点" : "点击连接"
        }
    }
}

struct CountryListView: View {
    @EnvironmentObject private var library: IOSLibrary
    let onDone: () -> Void

    var body: some View {
        List {
            if library.countries.isEmpty {
                LegacyLabel("还没有节点。先到订阅页导入。", systemImage: "globe")
                    .foregroundColor(HopGold.light)
                    .listRowBackground(HopGold.row)
            }
            ForEach(library.countries) { country in
                NavigationLink(destination: NodeListView(code: country.code, onDone: onDone)) {
                    HStack(spacing: 12) {
                        Text(country.flag).font(.title)
                        Text(country.name).fontWeight(.semibold)
                        Spacer()
                        Text("\(country.nodes.count) 个节点")
                            .font(.subheadline)
                            .foregroundColor(HopGold.light)
                    }
                    .padding(.vertical, 5)
                }
                .listRowBackground(HopGold.row)
            }
        }
        .hopGoldPage()
    }
}

struct AllNodesView: View {
    @EnvironmentObject private var library: IOSLibrary
    @State private var scope: IOSNodeScope = .available
    @State private var sourceID: UUID?
    @State private var sourceOpen = false
    @State private var showingTestTargets = false
    @State private var pendingTestIDs: [UUID] = []

    var body: some View {
        List {
            Button {
                if library.batchTotal > 0 {
                    library.stopBatch()
                } else if IOSSettings.selectedTestURLs.isEmpty {
                    pendingTestIDs = shown.map(\.id)
                    showingTestTargets = true
                } else {
                    library.startBatch(shown.map(\.id))
                }
            } label: {
                LegacyLabel(library.batchTotal > 0 ? "停止 \(library.batchDone)/\(library.batchTotal)" : "测试 \(shown.count)", systemImage: library.batchTotal > 0 ? "stop.circle" : "speedometer")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(shown.isEmpty && library.batchTotal == 0)
            .listRowBackground(HopGold.row)
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { sourceOpen.toggle() }) {
                            HStack(spacing: 4) {
                                Text(sourceTitle).lineLimit(1)
                                Image(systemName: sourceOpen ? "chevron.up" : "chevron.down").font(.caption)
                            }
                            .font(.subheadline)
                            .foregroundColor(HopGold.light)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .overlay(Capsule().stroke(HopGold.gold.opacity(0.7), lineWidth: 1))
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .legacyAccessibilityValue(sourceOpen ? "已展开" : "已收起")
                        statusChip(.available)
                        statusChip(.unavailable)
                        statusChip(.failed)
                    }
                }
                if sourceOpen {
                    sourceChoice(nil, title: "全部")
                    ForEach(library.subscriptions) { subscription in
                        sourceChoice(subscription.id, title: subscription.name)
                    }
                }
            }
            .listRowBackground(HopGold.row)
            if library.connectableNodes.isEmpty {
                Text("还没有节点。先到订阅页导入。")
                    .foregroundColor(.secondary)
                    .listRowBackground(HopGold.row)
            } else if shown.isEmpty {
                Text("这个筛选下没有节点。")
                    .foregroundColor(.secondary)
                    .listRowBackground(HopGold.row)
            }
            ForEach(sections) { section in
                Section(header: Text("\(section.title) · \(section.nodes.count)")) {
                    ForEach(section.nodes) { node in
                        NodeRow(node: node, selected: library.selectedNodeID == node.id) {
                            library.select(node)
                        }
                    }
                }
                .listRowBackground(HopGold.row)
            }
        }
        .hopGoldPage()
        .sheet(isPresented: $showingTestTargets) {
            TestTargetPicker { library.startBatch(pendingTestIDs) }
        }
    }

    private var sourceTitle: String {
        guard let sourceID else { return "全部" }
        return library.subscriptions.first { $0.id == sourceID }?.name ?? "全部"
    }

    private func sourceChoice(_ id: UUID?, title: String) -> some View {
        Button(action: {
            sourceID = id
            sourceOpen = false
        }) {
            HStack {
                Text("\(title) \(matching(source: id, scope: scope).count)")
                    .foregroundColor(.primary)
                Spacer()
                if sourceID == id {
                    Image(systemName: "checkmark")
                        .foregroundColor(HopGold.light)
                }
            }
        }
        .buttonStyle(BorderlessButtonStyle())
    }

    private var shown: [ProxyNode] {
        matching(source: sourceID, scope: scope)
    }

    private func matching(source: UUID?, scope: IOSNodeScope) -> [ProxyNode] {
        library.connectableNodes.filter { node in
            (source == nil || node.subscriptionID == source) && scope.matches(node)
        }
    }

    private func statusChip(_ item: IOSNodeScope) -> some View {
        Button(action: { scope = scope == item ? .all : item }) {
            chipLabel("\(item.title) \(matching(source: sourceID, scope: item).count)", selected: scope == item)
        }
        .buttonStyle(BorderlessButtonStyle())
        .legacyAccessibilityAddTraits(scope == item ? .isSelected : [])
    }

    private func chipLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.subheadline)
            .lineLimit(1)
            .foregroundColor(selected ? Color.black : HopGold.light)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Capsule().fill(selected ? HopGold.light : Color.black.opacity(0.5)))
            .overlay(Capsule().stroke(HopGold.gold.opacity(0.7), lineWidth: 1))
    }

    private var sections: [NodeSection] {
        var grouped: [String: [ProxyNode]] = [:]
        for node in shown {
            let key = node.subscriptionID?.uuidString ?? "manual"
            grouped[key, default: []].append(node)
        }
        var result: [NodeSection] = library.subscriptions.compactMap { subscription in
            let rows = grouped.removeValue(forKey: subscription.id.uuidString) ?? []
            guard !rows.isEmpty else { return nil }
            return NodeSection(id: subscription.id.uuidString, title: subscription.name, nodes: sorted(rows))
        }
        let leftover = grouped.values.flatMap { $0 }
        if !leftover.isEmpty {
            result.append(NodeSection(id: "manual", title: "手动导入", nodes: sorted(leftover)))
        }
        return result
    }

    private func sorted(_ nodes: [ProxyNode]) -> [ProxyNode] {
        IOSNodeSort.byLatency(nodes)
    }
}

struct SubscriptionNodesView: View {
    @EnvironmentObject private var library: IOSLibrary
    @LegacyAppStorage(IOSSettings.showSubscriptionNoticesKey) private var showSubscriptionNotices = false
    @State private var showingTestTargets = false
    @State private var pendingTestIDs: [UUID] = []
    var subscriptionID: UUID

    var body: some View {
        List {
            Section {
                Text(IOSNodeTally.make(rows).line)
                    .font(.footnote)
                    .foregroundColor(HopGold.light)
            }
            .listRowBackground(HopGold.row)
            if let subscription = library.subscriptions.first(where: { $0.id == subscriptionID }) {
                Section(header: Text("更新方式"), footer: Text(subscription.updateMode.helpText)) {
                    Picker("更新方式", selection: Binding(
                        get: { subscription.updateMode },
                        set: { library.setUpdatePolicy(subscriptionID, mode: $0) }
                    )) {
                        ForEach(SubscriptionUpdateMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if subscription.updateMode == .smartMerge {
                        Stepper("连续缺失 \(subscription.smartMergeMissingLimit) 次后删除", value: Binding(
                            get: { subscription.smartMergeMissingLimit },
                            set: { library.setUpdatePolicy(subscriptionID, missingLimit: $0) }
                        ), in: 1...10)
                    }
                }
                .listRowBackground(HopGold.row)
            }
            if showSubscriptionNotices && !notices.isEmpty {
                Section(header: Text("订阅信息")) {
                    ForEach(notices) { notice in
                        Text(notice.displayTitle)
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(HopGold.row)
            }
            if rows.isEmpty {
                Text("这个订阅组还没有节点。")
                    .foregroundColor(.secondary)
                    .listRowBackground(HopGold.row)
            }
            ForEach(rows) { node in
                NodeRow(node: node, selected: library.selectedNodeID == node.id) {
                    library.select(node)
                }
                .listRowBackground(HopGold.row)
            }
        }
        .hopGoldPage()
        .hopPageTitle(Text(title))
        .navigationBarItems(trailing: Button(library.batchTotal > 0 ? "停止 \(library.batchDone)/\(library.batchTotal)" : "测试") {
            if library.batchTotal > 0 {
                library.stopBatch()
            } else if IOSSettings.selectedTestURLs.isEmpty {
                pendingTestIDs = rows.map(\.id)
                showingTestTargets = true
            } else {
                library.startBatch(rows.map(\.id))
            }
        }
        .disabled(rows.isEmpty && library.batchTotal == 0))
        .sheet(isPresented: $showingTestTargets) {
            TestTargetPicker { library.startBatch(pendingTestIDs) }
        }
    }

    private var title: String {
        library.subscriptions.first { $0.id == subscriptionID }?.name ?? "订阅"
    }

    private var notices: [ProxyNode] {
        library.nodes.filter { $0.subscriptionID == subscriptionID && IOSSubscriptionNotice.matches($0) }
    }

    private var rows: [ProxyNode] {
        IOSNodeSort.byLatency(library.connectableNodes.filter { $0.subscriptionID == subscriptionID })
    }
}

struct NodeListView: View {
    @EnvironmentObject private var library: IOSLibrary
    var code: String
    let onDone: () -> Void

    var body: some View {
        List(library.nodes(in: code)) { node in
            NodeRow(node: node, selected: library.selectedNodeID == node.id) {
                library.select(node)
            }
            .listRowBackground(HopGold.row)
        }
        .hopGoldPage()
        .hopPageTitle(Text(library.countries.first { $0.code == code }?.name ?? "节点"))
        .navigationBarItems(trailing: Button("完成", action: onDone))
    }
}

private struct NodeSection: Identifiable {
    let id: String
    let title: String
    let nodes: [ProxyNode]
}

private struct NodeRow: View {
    let node: ProxyNode
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.displayTitle)
                        .foregroundColor(.primary)
                        .fontWeight(.semibold)
                    Text("\(node.protocolType.displayName) · \(node.server):\(String(node.port))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    if let error = node.lastTestErrorMessage, !error.isEmpty {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                }
                Spacer(minLength: 4)
                Text(node.latencyText)
                    .font(.subheadline)
                    .foregroundColor(HopGold.light)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(HopGold.light)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .legacyAccessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ImportView: View {
    @EnvironmentObject private var library: IOSLibrary
    @State private var showingAdd = false

    var body: some View {
        List {
            if library.subscriptions.isEmpty {
                Section {
                    Text("还没有订阅组。请添加订阅。")
                        .foregroundColor(.secondary)
                }
                .listRowBackground(HopGold.row)
            }
            ForEach(Array(library.subscriptions.enumerated()), id: \.element.id) { index, subscription in
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        NavigationLink(destination: SubscriptionNodesView(subscriptionID: subscription.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                (Text("\(index + 1). ").foregroundColor(.secondary)
                                 + Text(subscription.name).foregroundColor(.primary)
                                 + Text(" · \(subscription.sourceKind.displayName)").font(.subheadline).foregroundColor(.secondary))
                                    .font(.headline)
                                Text(IOSNodeTally.make(library.connectableNodes.filter { $0.subscriptionID == subscription.id }).line)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                if let status = subscription.statusMessage, !status.isEmpty {
                                    Text(status)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        Button {
                            Task { await library.refreshSubscription(subscription.id) }
                        } label: {
                            Text(library.refreshingSubscriptionID == subscription.id ? "更新中" : "更新")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(HopGold.light)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .disabled(library.refreshingSubscriptionID != nil)
                    }
                }
                .listRowBackground(HopGold.row)
            }
            .onDelete { offsets in
                let ids = offsets.map { library.subscriptions[$0].id }
                ids.forEach(library.deleteSubscription)
            }
        }
        .hopGoldPage()
        .navigationBarItems(leading: Button { showingAdd = true } label: {
            Image(systemName: "plus")
        }.legacyAccessibilityLabel("添加订阅"))
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionView().environmentObject(library)
        }
    }
}

private struct AddSubscriptionView: View {
    @EnvironmentObject private var library: IOSLibrary
    @Environment(\.presentationMode) private var presentation
    @State private var name = ""
    @State private var kind: SubscriptionSourceKind = .remoteURL
    @State private var urlText = ""
    @State private var shareText = ""
    @State private var message: String?
    @State private var updateMode: SubscriptionUpdateMode = .smartMerge
    @State private var missingLimit = 3
    @State private var importedNodeIDs: [UUID] = []
    @State private var imported = false
    @State private var showingTestPrompt = false
    @State private var showingTestTargets = false
    @State private var startAfterTargetSelection = false

    var body: some View {
        NavigationView {
            Form {
                if library.isBusy {
                    Section { Text("正在添加订阅，请稍候…").foregroundColor(HopGold.light) }
                        .listRowBackground(HopGold.row)
                }
                if let message {
                    Section { Text(message).foregroundColor(.red) }
                        .listRowBackground(HopGold.row)
                }
                Section(header: Text("类型")) {
                    Picker("类型", selection: $kind) {
                        Text("订阅地址").tag(SubscriptionSourceKind.remoteURL)
                        Text("分享链接").tag(SubscriptionSourceKind.shareLinks)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                .listRowBackground(HopGold.row)
                Section(header: Text("名称")) {
                    TextField("订阅组名称", text: $name)
                        .disableAutocorrection(true)
                }
                .listRowBackground(HopGold.row)
                if kind == .remoteURL {
                    Section(header: Text("订阅地址")) {
                        HStack(spacing: 12) {
                            TextField("https://", text: $urlText)
                                .autocapitalization(.none)
                                .keyboardType(.URL)
                                .disableAutocorrection(true)
                            if #available(iOS 16.0, *) {
                                PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
                                    pasteAddress(providers)
                                }
                                .labelStyle(.titleOnly)
                            } else {
                                Button("粘贴") {
                                    applyPastedAddress(UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                    .listRowBackground(HopGold.row)
                } else {
                    Section(header: Text("分享链接")) {
                        ShareTextEditor(text: $shareText)
                            .frame(minHeight: 160)
                    }
                    .listRowBackground(HopGold.row)
                }
                Section(header: Text("更新方式"), footer: Text(updateMode.helpText)) {
                    Picker("更新方式", selection: $updateMode) {
                        ForEach(SubscriptionUpdateMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if updateMode == .smartMerge {
                        Stepper("连续缺失 \(missingLimit) 次后删除", value: $missingLimit, in: 1...10)
                    }
                }
                .listRowBackground(HopGold.row)
            }
            .hopGoldPage()
            .hopPageTitle(Text("添加订阅"))
            .navigationBarItems(
                leading: Button("取消") { presentation.wrappedValue.dismiss() },
                trailing: Button(library.isBusy ? "添加中…" : "添加") { Task { await save() } }
                    .disabled(library.isBusy || imported)
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert(isPresented: $showingTestPrompt) {
            if !imported {
                return Alert(title: Text("添加失败"), message: Text(message ?? "请检查订阅内容后重试。"), dismissButton: .default(Text("确定")))
            }
            let message: String
            if importedNodeIDs.isEmpty {
                message = "已添加，但没有可测试的节点。"
            } else if library.batchTotal > 0 {
                message = "已添加 \(importedNodeIDs.count) 个节点。当前已有测速任务，请稍后再测试。"
            } else {
                message = "已添加 \(importedNodeIDs.count) 个节点，是否立即测试延迟？"
            }
            if !importedNodeIDs.isEmpty && library.batchTotal == 0 {
                return Alert(title: Text("添加成功"), message: Text(message), primaryButton: .default(Text("立即测试"), action: beginTesting), secondaryButton: .cancel(Text("暂不测试")) { presentation.wrappedValue.dismiss() })
            }
            return Alert(title: Text("添加成功"), message: Text(message), dismissButton: .default(Text("确定")) { presentation.wrappedValue.dismiss() })
        }
        .sheet(isPresented: $showingTestTargets, onDismiss: {
            if startAfterTargetSelection { library.startBatch(importedNodeIDs) }
            presentation.wrappedValue.dismiss()
        }) {
            TestTargetPicker { startAfterTargetSelection = true }
        }
    }

    @available(iOS 16.0, *)
    private func pasteAddress(_ providers: [NSItemProvider]) {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) else {
            message = "无法读取剪贴板中的网址，请尝试复制网址文本。"
            return
        }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.url.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
            let text: String?
            if let url = value as? URL {
                if url.isFileURL {
                    text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
                } else {
                    text = url.absoluteString
                }
            } else if let string = value as? String {
                text = string
            } else if let data = value as? Data {
                text = String(data: data, encoding: .utf8)
            } else {
                text = nil
            }
            DispatchQueue.main.async { applyPastedAddress(text) }
        }
    }

    private func applyPastedAddress(_ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            message = "无法读取剪贴板中的网址，请尝试复制网址文本。"
            return
        }
        guard URL(string: value)?.isFileURL != true else {
            message = "剪贴板中是文件地址，请复制订阅网址文本后重试。"
            return
        }
        urlText = value
        message = nil
    }

    private var canSave: Bool {
        switch kind {
        case .remoteURL:
            return !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .shareLinks:
            return !shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() async {
        guard canSave else {
            message = kind == .remoteURL ? "请输入订阅地址。" : "请输入分享链接。"
            showingTestPrompt = true
            return
        }
        message = nil
        do {
            let subscriptionID: UUID
            switch kind {
            case .remoteURL:
                subscriptionID = try await library.importSubscription(urlString: urlText, name: name, mode: updateMode, missingLimit: missingLimit)
            case .shareLinks:
                subscriptionID = try library.importShareText(shareText, name: name, mode: updateMode, missingLimit: missingLimit)
            }
            importedNodeIDs = library.connectableNodes.filter { $0.subscriptionID == subscriptionID }.map(\.id)
            imported = true
            showingTestPrompt = true
        } catch {
            message = error.localizedDescription
            showingTestPrompt = true
        }
    }

    private func beginTesting() {
        if IOSSettings.selectedTestURLs.isEmpty {
            startAfterTargetSelection = false
            showingTestTargets = true
        } else {
            library.startBatch(importedNodeIDs)
            presentation.wrappedValue.dismiss()
        }
    }
}

struct SettingsView: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var selectedTheme = IOSTheme.blackGold.rawValue
    @LegacyAppStorage(IOSSettings.showSubscriptionNoticesKey) private var showSubscriptionNotices = false
    @LegacyAppStorage(IOSSettings.selectedTargetsKey) private var selectedTargetsData = ""
    @LegacyAppStorage(IOSSettings.customTargetsKey) private var customTargetsData = ""
    @State private var timeout = IOSSettings.timeoutSeconds
    @State private var batchTimeout = IOSSettings.batchTimeoutSeconds

    var body: some View {
        List {
            Section(header: Text("外观").foregroundColor(HopGold.light)) {
                NavigationLink(destination: ThemeSettingsView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "paintpalette")
                            .foregroundColor(HopGold.light)
                            .frame(width: 24)
                            .legacyAccessibilityHidden(true)
                        Text("主题设置")
                        Spacer()
                        Text((IOSTheme(rawValue: selectedTheme) ?? .blackGold).title).foregroundColor(.secondary)
                    }
                }
            }
            .listRowBackground(HopGold.row)
            Section(header: Text("订阅").foregroundColor(HopGold.light), footer: Text("在订阅详情中显示服务商提供的公告和账户信息。")) {
                Toggle("显示订阅信息", isOn: $showSubscriptionNotices)
            }
            .listRowBackground(HopGold.row)
            Section(header: Text("测速超时").foregroundColor(HopGold.light), footer: Text("每个节点的网页请求超时时间；批量测速不自动重试。慢握手节点可调高或单独复测。")) {
                Stepper("单测超时：\(timeout) 秒", value: Binding(get: { timeout }, set: {
                    timeout = $0
                    IOSSettings.timeoutSeconds = $0
                }), in: IOSSettings.timeoutRange)
                Stepper("批量测速超时：\(batchTimeout) 秒", value: Binding(get: { batchTimeout }, set: {
                    batchTimeout = $0
                    IOSSettings.batchTimeoutSeconds = $0
                }), in: IOSSettings.timeoutRange)
            }
            .listRowBackground(HopGold.row)
            Section(header: Text("测试目标").foregroundColor(HopGold.light), footer: Text("测速会检查所有选中目标，全部成功才算可用；延迟显示最慢的一项。")) {
                targetLink("网页")
                targetLink("App")
            }
            .listRowBackground(HopGold.row)
        }
        .hopGoldPage()
        .hopPageTitle(Text("设置"))
    }

    private var selectedURLs: [String] { IOSSettings.selectedTestURLs(from: selectedTargetsData) }
    private var availableTargets: [IOSSettings.Target] {
        _ = customTargetsData
        return IOSSettings.targets
    }

    private func targetLink(_ kind: String) -> some View {
        NavigationLink(destination: TestTargetsView(kind: kind)) {
            HStack {
                Image(systemName: kind == "网页" ? "globe" : "square.grid.2x2")
                    .foregroundColor(HopGold.light)
                    .frame(width: 24)
                    .legacyAccessibilityHidden(true)
                Text(kind)
                Spacer()
                let count = availableTargets.filter { $0.kind == kind && selectedURLs.contains($0.url) }.count
                Text(count == 0 ? "未选择" : "已选 \(count) 项").foregroundColor(.secondary)
            }
        }
    }

}

private struct ThemeSettingsView: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var selectedTheme = IOSTheme.blackGold.rawValue

    private var theme: IOSTheme { IOSTheme(rawValue: selectedTheme) ?? .blackGold }

    var body: some View {
        List {
            Section(header: Text("选择主题").foregroundColor(HopGold.light)) {
                ForEach(IOSTheme.allCases) { item in
                    Button {
                        selectedTheme = item.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item == .blackGold ? "sparkles" : "cloud.fill")
                                .foregroundColor(HopGold.light)
                                .frame(width: 24)
                                .legacyAccessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline).foregroundColor(.primary)
                                Text(item.description)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if item == theme {
                                LegacyLabel("已启用", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundColor(HopGold.light)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityElement(children: .combine)
                    .legacyAccessibilityAddTraits(item == theme ? .isSelected : [])
                }
            }
            .listRowBackground(HopGold.row)
            Section(header: Text("主题预览").foregroundColor(HopGold.light), footer: Text("预览仅用于展示主题样式。")) {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geometry in
                        let scale = geometry.size.width / 863
                        Image(theme.assetName)
                            .resizable()
                            .frame(width: geometry.size.width, height: 1822 * scale)
                            .offset(y: -75 * scale)
                    }
                    .frame(height: 100)
                    .clipped()
                    .id(theme.rawValue)
                    .legacyAccessibilityHidden(true)
                    Text("\(theme.title)主题预览")
                        .font(.footnote)
                        .foregroundColor(HopGold.light)
                }
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(HopGold.row)
        }
        .hopGoldPage()
        .hopPageTitle(Text("主题设置"))
    }
}

private struct TestTargetPicker: View {
    let start: () -> Void
    @Environment(\.presentationMode) private var presentation
    @LegacyAppStorage(IOSSettings.selectedTargetsKey) private var selectedTargetsData = ""
    @LegacyAppStorage(IOSSettings.customTargetsKey) private var customTargetsData = ""

    private var selectedURLs: [String] { IOSSettings.selectedTestURLs(from: selectedTargetsData) }
    private var targets: [IOSSettings.Target] {
        _ = customTargetsData
        return IOSSettings.targets
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(["网页", "App"], id: \.self) { kind in
                    Section(header: Text(kind).foregroundColor(HopGold.light)) {
                        ForEach(targets.filter { $0.kind == kind }) { target in
                            Button {
                                var selected = selectedURLs
                                if selected.contains(target.url) {
                                    selected.removeAll { $0 == target.url }
                                } else {
                                    selected.append(target.url)
                                }
                                selectedTargetsData = IOSSettings.encodedTestURLs(selected)
                            } label: {
                                HStack {
                                    Text(target.title).foregroundColor(.primary)
                                    Spacer()
                                    if selectedURLs.contains(target.url) { Image(systemName: "checkmark").foregroundColor(HopGold.light) }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .legacyAccessibilityAddTraits(selectedURLs.contains(target.url) ? .isSelected : [])
                        }
                    }
                    .listRowBackground(HopGold.row)
                }
            }
            .hopGoldPage()
            .hopPageTitle(Text("测试目标"))
            .navigationBarItems(leading: Button("取消") { presentation.wrappedValue.dismiss() },
                trailing: Button("开始测试") {
                    presentation.wrappedValue.dismiss()
                    start()
                }.disabled(selectedURLs.isEmpty))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct TestTargetsView: View {
    let kind: String
    @LegacyAppStorage(IOSSettings.selectedTargetsKey) private var selectedTargetsData = ""
    @LegacyAppStorage(IOSSettings.customTargetsKey) private var customTargetsData = ""
    @State private var showingAdd = false

    var body: some View {
        List {
            Section(header: Text("预设").foregroundColor(HopGold.light)) {
                ForEach(IOSSettings.builtInTargets.filter { $0.kind == kind }) { target in
                    targetButton(target)
                }
            }
            .listRowBackground(HopGold.row)
            let custom = availableTargets.filter { $0.kind == kind && !IOSSettings.builtInTargets.contains($0) }
            if !custom.isEmpty {
                Section(header: Text("自定义").foregroundColor(HopGold.light), footer: Text("向左滑动可删除自定义目标。")) {
                    ForEach(custom) { target in
                        targetButton(target)
                    }
                    .onDelete { offsets in
                        let urls = Set(offsets.map { custom[$0].url })
                        let selected = selectedURLs.filter { !urls.contains($0) }
                        IOSSettings.customTargets.removeAll { urls.contains($0.url) }
                        selectedTargetsData = IOSSettings.encodedTestURLs(selected)
                    }
                }
                .listRowBackground(HopGold.row)
            }
        }
        .hopGoldPage()
        .hopPageTitle(Text("\(kind)测试目标"))
        .navigationBarItems(trailing: Button { showingAdd = true } label: {
            Image(systemName: "plus")
        }.legacyAccessibilityLabel("添加测试目标"))
        .sheet(isPresented: $showingAdd) {
            AddTestTargetView(kind: kind)
        }
    }

    private var selectedURLs: [String] { IOSSettings.selectedTestURLs(from: selectedTargetsData) }
    private var availableTargets: [IOSSettings.Target] {
        _ = customTargetsData
        return IOSSettings.targets
    }

    private func targetButton(_ target: IOSSettings.Target) -> some View {
        Button {
            var selected = selectedURLs
            if selected.contains(target.url) {
                selected.removeAll { $0 == target.url }
            } else {
                selected.append(target.url)
            }
            selectedTargetsData = IOSSettings.encodedTestURLs(selected)
        } label: {
            HStack {
                Text(target.title).foregroundColor(.primary)
                Spacer()
                if selectedURLs.contains(target.url) { Image(systemName: "checkmark").foregroundColor(HopGold.light) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .legacyAccessibilityAddTraits(selectedURLs.contains(target.url) ? .isSelected : [])
    }
}

private struct AddTestTargetView: View {
    let kind: String
    @Environment(\.presentationMode) private var presentation
    @State private var title = ""
    @State private var url = ""
    @State private var message: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("名称").foregroundColor(HopGold.light)) {
                    TextField("测试目标名称", text: $title)
                }
                .listRowBackground(HopGold.row)
                Section(header: Text("网址").foregroundColor(HopGold.light), footer: Text("请输入 HTTP 或 HTTPS 地址。")) {
                    TextField("https://", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .listRowBackground(HopGold.row)
                if let message { Section { Text(message).foregroundColor(.red) }.listRowBackground(HopGold.row) }
            }
            .hopGoldPage()
            .hopPageTitle(Text("添加\(kind)目标"))
            .navigationBarItems(leading: Button("取消") { presentation.wrappedValue.dismiss() },
                trailing: Button("添加") { save() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func save() {
        guard let target = IOSSettings.customTarget(title: title, url: url, kind: kind) else {
            message = "请输入名称和有效的 HTTP 或 HTTPS 网址。"
            return
        }
        guard !IOSSettings.targets.contains(where: { $0.url == target.url }) else {
            message = "这个网址已经存在。"
            return
        }
        IOSSettings.customTargets.append(target)
        presentation.wrappedValue.dismiss()
    }
}

enum IOSExitCountry {
    /// Chinese when the country has one. English only when it does not.
    static func label(code: String?, name: String?, fallback node: ProxyNode) -> String {
        if let code, !code.isEmpty, code != "XX" {
            let chinese = CountryResolver.displayName(for: code)
            if hasChinese(chinese) { return chinese }
            if let english = Locale(identifier: "en_US").localizedString(forRegionCode: code), !english.isEmpty {
                return english
            }
        }
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hasChinese(raw) { return raw }
        if !raw.isEmpty { return raw }
        return label(for: node)
    }

    static func label(for node: ProxyNode) -> String {
        let resolved = CountryResolver.effectiveCountry(for: node)
        if resolved.code != "XX" {
            let name = CountryResolver.displayName(for: resolved.code)
            if hasChinese(name) { return name }
            if let english = Locale(identifier: "en_US").localizedString(forRegionCode: resolved.code), !english.isEmpty {
                return english
            }
            return name
        }
        let raw = node.countryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hasChinese(raw) { return raw }
        return raw.isEmpty ? "未知" : raw
    }

    private static func hasChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
}

private struct ShareTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
    }
}
