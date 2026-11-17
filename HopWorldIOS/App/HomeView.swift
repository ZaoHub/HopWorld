import SwiftUI
import Combine
import UIKit
import ImageIO
import NetworkExtension

private final class DefaultsObserver: ObservableObject {
    static let shared = DefaultsObserver()
    private var observer: NSObjectProtocol?
    private var publishScheduled = false
    private init() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // didChange 在主线程同步送达，此刻可能正处在视图更新里。
            guard let self, !self.publishScheduled else { return }
            self.publishScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.publishScheduled = false
                self?.objectWillChange.send()
            }
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

private struct HopPromptButton: Identifiable {
    let title: String
    let emphasized: Bool
    let action: () -> Void
    var id: String { title }
}

private struct HopThemePlate: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    var body: some View {
        if IOSTheme(rawValue: themeValue) == .xianxia {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.44), Color(red: 0.04, green: 0.25, blue: 0.27), Color(red: 0.025, green: 0.13, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HopGold.metal, lineWidth: 1.5))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(HopGold.light.opacity(0.35), lineWidth: 0.6).padding(3))
                .shadow(color: Color(red: 0, green: 0.5, blue: 0.5).opacity(0.2), radius: 4, y: 1)
        } else {
            GoldCutPanel()
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(red: 0.10, green: 0.09, blue: 0.075), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(GoldCutPanel().stroke(HopGold.metal, lineWidth: 2))
                .overlay(GoldCutPanel().stroke(HopGold.light.opacity(0.4), lineWidth: 0.6).padding(4))
                .shadow(color: HopGold.gold.opacity(0.25), radius: 4, y: 1)
        }
    }
}

private struct HopThemeActionFill: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    var body: some View {
        if IOSTheme(rawValue: themeValue) == .xianxia {
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.70, blue: 0.68), Color(red: 0.24, green: 0.48, blue: 0.48)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(HopGold.metal, lineWidth: 1))
        } else {
            Capsule().fill(HopGold.light)
        }
    }
}

func makeGlobalPromptController(library: IOSLibrary) -> UIViewController {
    let host = UIHostingController(rootView: BatchResultPrompt().environmentObject(library))
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    return host
}

private struct BatchResultPrompt: View {
    @EnvironmentObject private var library: IOSLibrary

    var body: some View {
        GeometryReader { _ in
            if let prompt = library.batchPrompt {
                promptView(prompt)
            }
        }
        .background(PromptWindowGate(shown: library.batchPrompt != nil))
    }

    private func promptView(_ prompt: IOSBatchPrompt) -> some View {
        switch prompt {
        case .connect(let usable, let testedIDs):
            return HopThemePrompt(
                title: "测试完成",
                message: "有 \(usable) 个可用节点。要按当前使用规则连接吗？",
                buttons: [
                    HopPromptButton(title: "连接", emphasized: true) {
                        library.batchPrompt = nil
                        Task { await library.connectTested(testedIDs) }
                    },
                    HopPromptButton(title: "暂不", emphasized: false) { library.batchPrompt = nil }
                ],
                onScrim: { library.batchPrompt = nil }
            )
        case .noAvailable(let subscriptionIDs):
            return HopThemePrompt(
                title: "没有可用节点",
                message: "这次测试没有可用节点。可以更新订阅，或更换一个订阅。",
                buttons: [
                    HopPromptButton(title: "更新订阅", emphasized: true) {
                        library.batchPrompt = nil
                        Task { await library.refreshTestedSubscriptions(subscriptionIDs) }
                    },
                    HopPromptButton(title: "更换订阅", emphasized: false) {
                        library.batchPrompt = nil
                        library.presentSubscriptions()
                    }
                ],
                onScrim: { library.batchPrompt = nil }
            )
        }
    }
}

private struct PromptWindowGate: UIViewRepresentable {
    var shown: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let shown = shown
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            if shown {
                window.isHidden = false
                window.makeKeyAndVisible()
            } else if !window.isHidden {
                window.isHidden = true
                window.windowScene?.windows.first { $0 !== window && $0.windowLevel == .normal }?.makeKey()
            }
        }
    }
}

private struct HopThemePrompt: View {
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue
    let title: String
    let message: String
    let buttons: [HopPromptButton]
    let onScrim: () -> Void

    private var xianxia: Bool { IOSTheme(rawValue: themeValue) == .xianxia }

    var body: some View {
        ZStack {
            (xianxia ? Color(red: 0.02, green: 0.08, blue: 0.10) : Color.black)
                .opacity(0.62)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture(perform: onScrim)
            VStack(spacing: 16) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(HopGold.light)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    ForEach(buttons) { button in
                        Button(action: button.action) {
                            Text(button.title)
                                .font(.body.weight(.semibold))
                                .foregroundColor(button.emphasized ? (xianxia ? Color.white : Color.black) : HopGold.light)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Group { if button.emphasized { HopThemeActionFill() } })
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .background(HopThemePlate())
            .padding(.horizontal, 32)
        }
    }
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

    /// 每张订阅卡片是一个分组。系统默认的分组间距比卡片本身还显眼。
    @ViewBuilder
    func subscriptionCardSpacing() -> some View {
        if #available(iOS 17.0, *) {
            listSectionSpacing(8)
        } else {
            self
        }
    }

    func hopPageTitle(_ title: Text) -> some View {
        navigationBarTitle(title, displayMode: .inline)
            .background(HomeNavigationBar())
            .homeListTopMargin()
    }

    /// 分组标题在 iOS 14 起会被系统改成大写。iOS 13 没有这个修饰符。
    @ViewBuilder
    func hopHeaderCase() -> some View {
        if #available(iOS 14.0, *) {
            textCase(nil)
        } else {
            self
        }
    }

    @ViewBuilder
    func hiddenRowSeparator() -> some View {
        if #available(iOS 15.0, *) {
            listRowSeparator(.hidden)
        } else {
            self
        }
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
                   let navigation = controller.navigationController {
                    let bar = navigation.navigationBar
                    // 根页面没有可返回的上一层。关掉这条手势，右滑才能露出编辑。
                    navigation.interactivePopGestureRecognizer?.isEnabled = navigation.viewControllers.count > 1
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

private enum ConnectGuide: Identifiable {
    case noSubscription
    case needsTest
    case selectAvailable
    case noAvailable
    case outsidePolicy

    var id: String { title }

    var title: String {
        switch self {
        case .noSubscription: return "还没有订阅"
        case .needsTest: return "还没有测试"
        case .selectAvailable: return "请选择节点"
        case .noAvailable: return "没有可用节点"
        case .outsidePolicy: return "不在使用范围"
        }
    }

    var message: String {
        switch self {
        case .noSubscription:
            return "请先添加订阅组。添加完成后测试节点延迟，再选择可用节点连接。"
        case .needsTest:
            return "订阅里的节点还没有测试。请先测试延迟，再选择一个可用节点连接。"
        case .selectAvailable:
            return "已有可用节点。请选择一个符合使用范围的节点后再连接。"
        case .noAvailable:
            return "测试后没有可用节点。可以更新订阅组、重新测试，或更换订阅。"
        case .outsidePolicy:
            return "测到的节点都不在设置的使用范围内。可以调整使用范围、更新订阅或重新测试。"
        }
    }

    var actions: [ConnectGuideAction] {
        switch self {
        case .noSubscription: return [.addSubscription]
        case .needsTest: return [.testNodes, .selectNode]
        case .selectAvailable: return [.selectNode]
        case .noAvailable: return [.refreshSubscriptions, .testNodes, .replaceSubscription]
        case .outsidePolicy: return [.openSettings, .refreshSubscriptions, .testNodes]
        }
    }
}

private enum ConnectGuideAction: String, Identifiable {
    case addSubscription
    case testNodes
    case selectNode
    case refreshSubscriptions
    case replaceSubscription
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addSubscription: return "添加订阅"
        case .testNodes: return "去测试"
        case .selectNode: return "选择节点"
        case .refreshSubscriptions: return "更新订阅"
        case .replaceSubscription: return "更换订阅"
        case .openSettings: return "打开设置"
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
    @State private var connectGuide: ConnectGuide?
    @State private var guideTestAfterTargets = false
    @State private var showingUsageSettings = false

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
                        Group {
                            if page == .subscriptions {
                                Image(systemName: "xmark")
                            } else {
                                Text("完成")
                            }
                        }
                        .foregroundColor(HopGold.light)
                    }.legacyAccessibilityLabel("完成"))
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .accentColor(HopGold.light)
                .overlay(notice)
            }
            .sheet(isPresented: $showingUsageSettings) {
                NavigationView {
                    SettingsView()
                        .environmentObject(library)
                        .navigationBarItems(trailing: Button("完成") { showingUsageSettings = false }
                            .foregroundColor(HopGold.light))
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .accentColor(HopGold.light)
            }
            .sheet(isPresented: $showingTestTargets) {
                TestTargetPicker {
                    if guideTestAfterTargets {
                        guideTestAfterTargets = false
                        library.startBatch(library.connectableNodes.map(\.id))
                    } else {
                        Task { await library.measureSelected() }
                    }
                }
            }
            .sheet(isPresented: $showingNodeDetails) {
                NavigationView {
                    ZStack {
                        List {
                            if library.selectedNode != nil {
                                nodeDetails
                            }
                        }
                        .hopGoldPage()
                        if library.selectedNode == nil {
                            Text("还没有选择节点，请先前往节点或订阅")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(Color(red: 0.8, green: 0.7, blue: 0.53))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                                .allowsHitTesting(false)
                        }
                    }
                    .hopPageTitle(Text("节点详情"))
                    .navigationBarItems(trailing: Button("完成") { showingNodeDetails = false }
                        .foregroundColor(HopGold.light))
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .accentColor(HopGold.light)
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
        .overlay(connectGuideDialog)
        .onReceive(library.$subscriptionPageToken) { token in
            guard token > 0 else { return }
            showingUsageSettings = false
            showingNodeDetails = false
            showingTestTargets = false
            presentedPage = .subscriptions
        }
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

            // 黑金未连接时底图已写好状态，这里只补「请先选择节点」。
            // 仙侠始终用上面的 connectTitle，再画一层会和它叠成两行。
            if !xianxia && !isMotionPreview && library.selectedNode == nil && (displayStatus == .disconnected || displayStatus == .invalid) {
                Text("请先选择节点")
                    .font(.system(size: max(11, 23 * scale), weight: .medium))
                    .foregroundColor(Color(red: 1, green: 0.88, blue: 0.63))
                    .position(x: 431 * scale, y: (968 - top) * scale)
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
                if displayStatus == .connected || displayStatus == .connecting || displayStatus == .reasserting {
                    library.disconnect()
                    return
                }
                if let node = IOSSettings.connectChoice(selected: library.selectedNode, in: library.connectableNodes) {
                    if library.selectedNode?.id != node.id { library.select(node) }
                    Task {
                        startingConnection = true
                        await library.connect()
                        startingConnection = false
                    }
                    return
                }
                connectGuide = currentConnectGuide ?? .outsidePolicy
            } label: {
                Color.clear.contentShape(Circle())
            }
            .frame(width: 460 * scale, height: 460 * scale)
            .position(x: 431 * scale, y: (connectionY - top) * scale)
            .disabled(connectDisabled)
            .legacyAccessibilityLabel("\(statusText)，\(connectTitle)")
            .legacyAccessibilityHint(currentConnectGuide?.message ?? (!isMotionPreview && library.selectedNode == nil ? "请先选择节点" : ""))
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
        }
    }

    private var exitDetails: IOSExitLookup.ExitIP? {
        if case .found(let exit) = library.exitQuery { return exit }
        return nil
    }

    private var notice: some View {
        VStack {
            Spacer()
            if let message = library.lastError {
                Text(message)
                    .font(.body.weight(.semibold))
                    .foregroundColor(HopGold.light)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(HopThemePlate())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
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
        !isMotionPreview && (library.isBusy || displayStatus == .disconnecting)
    }

    /// 没有可连接节点时，点圆钮给出下一步。
    private var currentConnectGuide: ConnectGuide? {
        if library.subscriptions.isEmpty { return .noSubscription }
        let nodes = library.connectableNodes
        if nodes.isEmpty { return .noAvailable }
        if IOSSettings.connectChoice(selected: library.selectedNode, in: nodes) != nil { return nil }
        let tested = nodes.contains {
            switch $0.resolvedTestStatus {
            case .untested, .testing: return false
            default: return true
            }
        }
        if !tested { return .needsTest }
        if !nodes.contains(where: { $0.resolvedTestStatus.isUsable }) { return .noAvailable }
        return .outsidePolicy
    }

    @ViewBuilder private var connectGuideDialog: some View {
        if let connectGuide {
            HopThemePrompt(
                title: connectGuide.title,
                message: connectGuide.message,
                buttons: connectGuide.actions.map { action in
                    HopPromptButton(title: action.title, emphasized: true) {
                        self.connectGuide = nil
                        perform(action)
                    }
                } + [HopPromptButton(title: "取消", emphasized: false) { self.connectGuide = nil }],
                onScrim: { self.connectGuide = nil }
            )
        }
    }

    private func perform(_ action: ConnectGuideAction) {
        switch action {
        case .addSubscription, .replaceSubscription:
            presentedPage = .subscriptions
        case .openSettings:
            showingUsageSettings = true
        case .selectNode:
            presentedPage = .nodes
        case .testNodes:
            let ids = library.connectableNodes.map(\.id)
            if IOSSettings.selectedTestURLs.isEmpty {
                guideTestAfterTargets = true
                showingTestTargets = true
            } else {
                library.startBatch(ids)
            }
        case .refreshSubscriptions:
            let ids = library.subscriptions.map(\.id)
            presentedPage = .subscriptions
            Task {
                for id in ids {
                    await library.refreshSubscription(id)
                }
            }
        }
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
        ZStack {
            countryList
            if library.countries.isEmpty {
                Text("还没有节点。先到订阅页导入。")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(red: 0.8, green: 0.7, blue: 0.53))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .allowsHitTesting(false)
            }
        }
    }

    private var countryList: some View {
        List {
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

private struct NodeAddOutcome {
    var title: String
    var message: String
    var nodeIDs: [UUID]
}

struct AllNodesView: View {
    @EnvironmentObject private var library: IOSLibrary
    @State private var blockedNode: String?
    @State private var selectedGroupID: String?
    @State private var showingAddNode = false
    @State private var addDraft = ""
    @State private var addGroupID: UUID?
    @State private var addField = ShareFieldBox()
    @State private var addOutcome: NodeAddOutcome?
    @State private var pendingTestIDs: [UUID] = []
    @State private var showingTestTargets = false
    @State private var startTestAfterTargets = false

    var body: some View {
        ZStack {
            nodeList
            if library.connectableNodes.isEmpty {
                emptyMessage("还没有节点。先到订阅页导入。")
            } else if shown.isEmpty {
                emptyMessage("还没有可用节点。")
            }
        }
        .navigationBarItems(leading: Button(action: openAddNode) {
            Image(systemName: "plus")
                .foregroundColor(HopGold.light)
        }.legacyAccessibilityLabel("添加节点"))
        .overlay(BlockedNodePrompt(message: $blockedNode))
        .overlay(addNodeForm)
        .overlay(addResultPrompt)
        .sheet(isPresented: $showingTestTargets, onDismiss: {
            if startTestAfterTargets {
                startTestAfterTargets = false
                library.startBatch(pendingTestIDs)
            }
        }) {
            TestTargetPicker { startTestAfterTargets = true }
        }
    }

    @ViewBuilder private var addNodeForm: some View {
        if showingAddNode {
            AddNodeForm(
                fixedGroupName: selectedSubscription?.name,
                subscriptions: library.subscriptions,
                draft: $addDraft,
                groupID: $addGroupID,
                field: addField,
                onPaste: pasteAddDraft,
                onCancel: cancelAddNode,
                onAdd: submitAddNode
            )
        }
    }

    @ViewBuilder private var addResultPrompt: some View {
        if let outcome = addOutcome {
            HopThemePrompt(
                title: outcome.title,
                message: outcome.message,
                buttons: addResultButtons(outcome),
                onScrim: { addOutcome = nil }
            )
        }
    }

    private func addResultButtons(_ outcome: NodeAddOutcome) -> [HopPromptButton] {
        guard !outcome.nodeIDs.isEmpty else {
            return [HopPromptButton(title: "确定", emphasized: true) { addOutcome = nil }]
        }
        return [
            HopPromptButton(title: "测试", emphasized: true) {
                let ids = outcome.nodeIDs
                addOutcome = nil
                beginTestingAdded(ids)
            },
            HopPromptButton(title: "暂不", emphasized: false) { addOutcome = nil }
        ]
    }

    private var selectedSubscription: Subscription? {
        guard let activeGroupID, let id = UUID(uuidString: activeGroupID) else { return nil }
        return library.subscriptions.first { $0.id == id }
    }

    private func openAddNode() {
        addDraft = ""
        addGroupID = nil
        guard !library.subscriptions.isEmpty else {
            let message = "还没有订阅组。请先到订阅页添加。"
            library.showNotice(message)
            addOutcome = NodeAddOutcome(title: "没有订阅组", message: message, nodeIDs: [])
            return
        }
        showingAddNode = true
    }

    private func cancelAddNode() {
        addField.textView?.resignFirstResponder()
        showingAddNode = false
    }

    private func pasteAddDraft() {
        if let text = ShareClipboard.text() {
            addDraft = text
        } else {
            library.showNotice(ShareClipboard.unavailableMessage)
        }
    }

    private func submitAddNode() {
        guard let id = selectedSubscription?.id ?? addGroupID else {
            library.showNotice("请选择订阅组。")
            return
        }
        let text = addDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            library.showNotice("请输入分享链接。")
            return
        }
        addField.textView?.resignFirstResponder()
        do {
            let result = try library.appendShareLinks(text, to: id)
            showingAddNode = false
            addDraft = ""
            presentAddResult(result)
        } catch {
            showingAddNode = false
            library.showNotice(error.localizedDescription)
            addOutcome = NodeAddOutcome(title: "未能添加", message: error.localizedDescription, nodeIDs: [])
        }
    }

    private func presentAddResult(_ result: ShareLinkAppendResult) {
        var summary = result.added == 0 ? "这些节点已经在这个订阅组里。" : "已添加 \(result.added) 个节点。"
        if result.skipped > 0 { summary += "跳过 \(result.skipped) 条无效链接。" }
        library.showNotice(summary)
        let ids = result.added > 0 ? result.nodeIDs : []
        if ids.isEmpty || library.batchTotal > 0 {
            let message = ids.isEmpty ? summary : summary + "当前已有测速任务，请稍后再测试。"
            addOutcome = NodeAddOutcome(title: result.added == 0 ? "没有新节点" : "添加成功", message: message, nodeIDs: [])
            return
        }
        let ask = ids.count == 1 ? "要测试这个节点吗？" : "要测试这 \(ids.count) 个节点吗？"
        addOutcome = NodeAddOutcome(title: "添加成功", message: summary + ask, nodeIDs: ids)
    }

    private func beginTestingAdded(_ ids: [UUID]) {
        if IOSSettings.selectedTestURLs.isEmpty {
            pendingTestIDs = ids
            startTestAfterTargets = false
            showingTestTargets = true
        } else {
            library.startBatch(ids)
        }
    }

    private var nodeList: some View {
        List {
            if allSections.count > 1 {
                GroupFilterBar(sections: allSections, activeID: activeGroupID) { selectedGroupID = $0 }
                    .listRowBackground(Color.clear)
                    .hiddenRowSeparator()
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .environment(\.defaultMinListRowHeight, NodeScopeChips.height)
            }
            ForEach(sections) { section in
                Section(header: Text("\(section.title) · \(section.nodes.count)")) {
                    ForEach(section.nodes) { node in
                        NodeChoiceRow(node: node, blocked: $blockedNode)
                    }
                }
            }
        }
        .hopGoldPage()
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(Color(red: 0.8, green: 0.7, blue: 0.53))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
            .allowsHitTesting(false)
    }

    private var shown: [ProxyNode] {
        sections.flatMap(\.nodes)
    }

    private var activeGroupID: String? {
        guard let selectedGroupID, allSections.contains(where: { $0.id == selectedGroupID }) else { return nil }
        return selectedGroupID
    }

    private var sections: [NodeSection] {
        guard let activeGroupID else { return allSections }
        return allSections.filter { $0.id == activeGroupID }
    }

    private var allSections: [NodeSection] {
        var grouped: [String: [ProxyNode]] = [:]
        for node in library.connectableNodes.filter(IOSNodeScope.available.matches) {
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

private struct AddNodeForm: View {
    var fixedGroupName: String?
    var subscriptions: [Subscription]
    @Binding var draft: String
    @Binding var groupID: UUID?
    var field: ShareFieldBox
    var onPaste: () -> Void
    var onCancel: () -> Void
    var onAdd: () -> Void
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    private var xianxia: Bool { IOSTheme(rawValue: themeValue) == .xianxia }

    var body: some View {
        ZStack {
            (xianxia ? Color(red: 0.02, green: 0.08, blue: 0.10) : Color.black)
                .opacity(0.62)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture(perform: onCancel)
            VStack(spacing: 14) {
                Text("添加节点")
                    .font(.headline)
                    .foregroundColor(.white)
                if let fixedGroupName {
                    Text("加入「\(fixedGroupName)」")
                        .font(.subheadline)
                        .foregroundColor(HopGold.light)
                        .multilineTextAlignment(.center)
                } else {
                    groupPicker
                }
                HStack {
                    Text("分享链接")
                        .font(.subheadline)
                        .foregroundColor(HopGold.light)
                    Spacer(minLength: 8)
                    Button("粘贴", action: onPaste)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(HopGold.light)
                        .buttonStyle(BorderlessButtonStyle())
                }
                ShareTextEditor(text: $draft, field: field)
                    .frame(minHeight: 88, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HopGold.light.opacity(0.45), lineWidth: 1))
                VStack(spacing: 10) {
                    Button(action: onAdd) {
                        Text("添加")
                            .font(.body.weight(.semibold))
                            .foregroundColor(xianxia ? Color.white : Color.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(HopThemeActionFill())
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    Button(action: onCancel) {
                        Text("取消")
                            .font(.body.weight(.semibold))
                            .foregroundColor(HopGold.light)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(HopThemePlate())
            .padding(.horizontal, 28)
        }
    }

    private var groupPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(groupID == nil ? "订阅组 · 请选择" : "订阅组")
                .font(.subheadline)
                .foregroundColor(HopGold.light)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(subscriptions) { subscription in
                        groupRow(subscription)
                    }
                }
            }
            .frame(maxHeight: min(132, CGFloat(max(subscriptions.count, 1)) * 40))
        }
    }

    private func groupRow(_ subscription: Subscription) -> some View {
        let selected = groupID == subscription.id
        return Button {
            groupID = subscription.id
        } label: {
            HStack {
                Text(subscription.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundColor(selected ? (xianxia ? Color.white : Color.black) : HopGold.light)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(Group { if selected { HopThemeActionFill() } })
        }
        .buttonStyle(BorderlessButtonStyle())
    }
}

/// 「全部」固定在左侧。其余分组放得下就平铺，放不下就左右滑动。
private struct GroupFilterBar: View {
    var sections: [NodeSection]
    var activeID: String?
    var onSelect: (String?) -> Void
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue
    @State private var rowWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    private var total: Int { sections.reduce(0) { $0 + $1.nodes.count } }
    private var scroll: Bool { rowWidth > 0 && contentWidth > rowWidth + 1 }

    var body: some View {
        bar
            .frame(height: NodeScopeChips.height)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: FilterRowWidthKey.self, value: proxy.size.width)
            })
            .background(measurer)
            .onPreferenceChange(FilterRowWidthKey.self) { rowWidth = $0 }
            .onPreferenceChange(FilterContentWidthKey.self) { contentWidth = $0 }
    }

    @ViewBuilder private var bar: some View {
        if scroll {
            HStack(spacing: 6) {
                chip(title: "全部", count: total, selected: activeID == nil, fill: false) { onSelect(nil) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { groupChips(fill: false) }
                }
            }
        } else {
            HStack(spacing: 6) {
                chip(title: "全部", count: total, selected: activeID == nil, fill: true) { onSelect(nil) }
                groupChips(fill: true)
            }
        }
    }

    private var measurer: some View {
        HStack(spacing: 6) {
            chip(title: "全部", count: total, selected: false, fill: false) {}
            groupChips(fill: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: FilterContentWidthKey.self, value: proxy.size.width)
        })
        .hidden()
        .allowsHitTesting(false)
        .accessibility(hidden: true)
    }

    @ViewBuilder private func groupChips(fill: Bool) -> some View {
        ForEach(sections) { section in
            chip(title: section.title, count: section.nodes.count, selected: activeID == section.id, fill: fill) {
                onSelect(activeID == section.id ? nil : section.id)
            }
        }
    }

    private func chip(title: String, count: Int, selected: Bool, fill: Bool, action: @escaping () -> Void) -> some View {
        let xianxia = IOSTheme(rawValue: themeValue) == .xianxia
        return Button(action: action) {
            Text("\(title) \(count)")
                .font(.subheadline)
                .lineLimit(1)
                .foregroundColor(selected ? (xianxia ? Color.white : Color.black) : HopGold.light)
                .padding(.horizontal, 10)
                .frame(maxWidth: fill ? .infinity : 160)
                .frame(height: NodeScopeChips.height)
                .background(HopThemeChipFace(selected: selected))
        }
        .buttonStyle(BorderlessButtonStyle())
        .fixedSize(horizontal: !fill, vertical: false)
        .legacyAccessibilityLabel("显示\(title) \(count)")
        .legacyAccessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FilterRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct FilterContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SubscriptionNodesView: View {
    @EnvironmentObject private var library: IOSLibrary
    @LegacyAppStorage(IOSSettings.showSubscriptionNoticesKey) private var showSubscriptionNotices = false
    @State private var scope: IOSNodeScope = .all
    @State private var showingTestTargets = false
    @State private var pendingTestIDs: [UUID] = []
    @State private var blockedNode: String?
    var subscriptionID: UUID

    var body: some View {
        List {
            Section {
                NodeScopeChips(scope: $scope, includeAll: true) { item in
                    rows.filter(item.matches).count
                }
                .frame(maxWidth: .infinity)
                .frame(height: NodeScopeChips.height)
            }
            .listRowBackground(Color.clear)
            .hiddenRowSeparator()
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .environment(\.defaultMinListRowHeight, NodeScopeChips.height)
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
            if shown.isEmpty {
                Text(rows.isEmpty ? "这个订阅组还没有节点。" : "这个筛选下没有节点。")
                    .foregroundColor(.secondary)
                    .listRowBackground(HopGold.row)
            }
            ForEach(shown) { node in
                NodeChoiceRow(node: node, blocked: $blockedNode)
            }
        }
        .hopGoldPage()
        .hopPageTitle(Text(title))
        .navigationBarItems(trailing: Button(library.batchTotal > 0 ? "停止 \(library.batchDone)/\(library.batchTotal)" : "测试\(scope == .all ? "" : " \(scope.title)") \(shown.count)") {
            if library.batchTotal > 0 {
                library.stopBatch()
            } else if IOSSettings.selectedTestURLs.isEmpty {
                pendingTestIDs = shown.map(\.id)
                showingTestTargets = true
            } else {
                library.startBatch(shown.map(\.id))
            }
        }
        .foregroundColor(HopGold.light)
        .disabled(shown.isEmpty && library.batchTotal == 0))
        .accentColor(HopGold.light)
        .sheet(isPresented: $showingTestTargets) {
            TestTargetPicker { library.startBatch(pendingTestIDs) }
        }
        .overlay(BlockedNodePrompt(message: $blockedNode))
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

    private var shown: [ProxyNode] {
        rows.filter(scope.matches)
    }
}

private struct HopThemeChipFace: View {
    var selected: Bool
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    var body: some View {
        if IOSTheme(rawValue: themeValue) == .xianxia {
            face(RoundedRectangle(cornerRadius: 16), xianxia: true)
        } else {
            face(GoldCutPanel(), xianxia: false)
        }
    }

    private func face<S: Shape>(_ shape: S, xianxia: Bool) -> some View {
        shape.fill(fill(xianxia: xianxia))
            .overlay(shape.stroke(HopGold.metal, lineWidth: xianxia ? 1 : 1.5))
            .overlay(shape.stroke(HopGold.light.opacity(selected ? 0.45 : 0.28), lineWidth: 0.6).padding(2))
    }

    private func fill(xianxia: Bool) -> LinearGradient {
        if selected {
            if xianxia {
                return LinearGradient(colors: [Color(red: 0.45, green: 0.70, blue: 0.68), Color(red: 0.24, green: 0.48, blue: 0.48)], startPoint: .top, endPoint: .bottom)
            }
            return LinearGradient(colors: [HopGold.light, Color(red: 0.86, green: 0.68, blue: 0.38)], startPoint: .top, endPoint: .bottom)
        }
        if xianxia {
            return LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.44), Color(red: 0.04, green: 0.25, blue: 0.27), Color(red: 0.025, green: 0.13, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color(white: 0.24), Color(red: 0.10, green: 0.09, blue: 0.075), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct NodeScopeChips: View {
    @Binding var scope: IOSNodeScope
    var includeAll = false
    var counts: (IOSNodeScope) -> Int
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    /// 列表会把这排按钮纵向撑高，固定成紧凑高度。
    static var height: CGFloat { 32 }

    private var xianxia: Bool { IOSTheme(rawValue: themeValue) == .xianxia }

    private var items: [IOSNodeScope] {
        (includeAll ? [IOSNodeScope.all] : []) + [.available, .unavailable, .failed, .untested]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let selected = scope == item
                Button(action: { scope = item == .all || selected ? .all : item }) {
                    Text("\(item.title) \(counts(item))")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundColor(selected ? (xianxia ? Color.white : Color.black) : HopGold.light)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height)
                        .background(HopThemeChipFace(selected: selected))
                }
                .buttonStyle(BorderlessButtonStyle())
                .legacyAccessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct NodeListView: View {
    @EnvironmentObject private var library: IOSLibrary
    var code: String
    let onDone: () -> Void
    @State private var blockedNode: String?

    var body: some View {
        List(library.nodes(in: code)) { node in
            NodeChoiceRow(node: node, blocked: $blockedNode)
        }
        .hopGoldPage()
        .hopPageTitle(Text(library.countries.first { $0.code == code }?.name ?? "节点"))
        .navigationBarItems(trailing: Button("完成", action: onDone).foregroundColor(HopGold.light))
        .accentColor(HopGold.light)
        .overlay(BlockedNodePrompt(message: $blockedNode))
    }
}

private struct NodeSection: Identifiable {
    let id: String
    let title: String
    let nodes: [ProxyNode]
}

private struct NodeChoiceRow: View {
    @EnvironmentObject private var library: IOSLibrary
    let node: ProxyNode
    @Binding var blocked: String?

    var body: some View {
        NodeRow(node: node, selected: library.selectedNodeID == node.id) {
            if let message = IOSSettings.blockMessage(node) {
                blocked = message
            } else {
                library.select(node)
            }
        }
    }
}

private struct BlockedNodePrompt: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HopThemePrompt(
                title: "不能选择",
                message: message,
                buttons: [HopPromptButton(title: "确定", emphasized: true) { self.message = nil }],
                onScrim: { self.message = nil }
            )
        }
    }
}

private struct NodeRow: View {
    @LegacyAppStorage(IOSSettings.useCountryScopeKey) private var countryScope = IOSUseCountryScope.all.rawValue
    @LegacyAppStorage(IOSSettings.useExcludedCountriesKey) private var excludedCountries = "[]"
    @LegacyAppStorage(IOSSettings.useIncludedCountriesKey) private var includedCountries = "[]"
    let node: ProxyNode
    let selected: Bool
    let select: () -> Void

    private var outside: Bool {
        _ = countryScope
        _ = excludedCountries
        _ = includedCountries
        return IOSSettings.outsideCountryScope(node)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.displayTitle)
                        .foregroundColor(outside ? Color.secondary : .primary)
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
                    .foregroundColor(outside ? Color.secondary : HopGold.light)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(outside ? Color.secondary : HopGold.light)
                }
            }
            .opacity(outside ? 0.45 : 1)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .listRowBackground(NodeCardBackground(outside: outside))
        .legacyAccessibilityAddTraits(selected ? .isSelected : [])
        .legacyAccessibilityLabel(outside ? "\(node.displayTitle)，范围外" : node.displayTitle)
    }
}

private struct NodeCardBackground: View {
    let outside: Bool
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    private var ribbonOutset: CGFloat {
        IOSTheme(rawValue: themeValue) == .xianxia ? 1 : 2
    }

    var body: some View {
        HopThemeRow()
            .overlay(
                ZStack(alignment: .topLeading) {
                    Color.clear
                    outsideRibbon
                }
                .mask(NodeCardClip(outset: ribbonOutset))
                .allowsHitTesting(false)
            )
    }

    @ViewBuilder private var outsideRibbon: some View {
        if outside {
            CornerRibbon()
                .offset(x: 4 - ribbonOutset, y: 4 - ribbonOutset)
                .allowsHitTesting(false)
        }
    }
}

private struct NodeCardClip: View {
    var outset: CGFloat = 0
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    var body: some View {
        if IOSTheme(rawValue: themeValue) == .xianxia {
            RoundedRectangle(cornerRadius: 22).padding(4 - outset)
        } else {
            GoldCutPanel().padding(4 - outset)
        }
    }
}

private struct CornerRibbon: View {
    var body: some View {
        ZStack {
            CornerFold().fill(HopGold.light)
            Text("范围外")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.black)
                .fixedSize()
                .rotationEffect(.degrees(-45))
                .offset(x: -8, y: -8)
        }
        .frame(width: 46, height: 46)
        .clipped()
    }
}

private struct CornerFold: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ImportView: View {
    @EnvironmentObject private var library: IOSLibrary
    @State private var showingAdd = false
    @State private var editingSubscriptionID: UUID?
    @State private var pendingDeleteSubscriptions: [Subscription] = []

    var body: some View {
        ZStack {
            subscriptionList
            if library.subscriptions.isEmpty {
                Text("还没有订阅组。请添加订阅。")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(red: 0.8, green: 0.7, blue: 0.53))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .allowsHitTesting(false)
            }
        }
        .accentColor(HopGold.light)
        .navigationBarItems(leading: Button { showingAdd = true } label: {
            Image(systemName: "plus")
                .foregroundColor(HopGold.light)
        }.legacyAccessibilityLabel("添加订阅"))
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionView().environmentObject(library)
        }
        .sheet(isPresented: Binding(get: { editingSubscriptionID != nil }, set: { if !$0 { editingSubscriptionID = nil } })) {
            if let editingSubscriptionID {
                EditSubscriptionView(subscriptionID: editingSubscriptionID).environmentObject(library)
            }
        }
        .overlay(subscriptionDeletePrompt)
    }

    @ViewBuilder private var subscriptionDeletePrompt: some View {
        if !pendingDeleteSubscriptions.isEmpty {
            let count = pendingDeleteSubscriptions.count
            let disconnects = pendingDeleteSubscriptions.contains { subscription in
                library.selectedNode?.subscriptionID == subscription.id
            }
            HopThemePrompt(
                title: count == 1 ? "删除订阅组" : "删除 \(count) 个订阅组",
                message: subscriptionDeleteMessage(count: count, disconnects: disconnects),
                buttons: [
                    HopPromptButton(title: "删除", emphasized: true) {
                        pendingDeleteSubscriptions.forEach { library.deleteSubscription($0.id) }
                        pendingDeleteSubscriptions = []
                    },
                    HopPromptButton(title: "取消", emphasized: false) { pendingDeleteSubscriptions = [] }
                ],
                onScrim: { pendingDeleteSubscriptions = [] }
            )
        }
    }

    private func subscriptionDeleteMessage(count: Int, disconnects: Bool) -> String {
        let base: String
        if count == 1, let name = pendingDeleteSubscriptions.first?.name {
            base = "删除「\(name)」？这个订阅组里的节点会一起删除。"
        } else {
            base = "删除这 \(count) 个订阅组？组里的节点会一起删除。"
        }
        return disconnects ? base + "当前连接会断开。" : base
    }

    private var subscriptionList: some View {
        List {
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
                    .subscriptionSwipes(
                        onEdit: { editingSubscriptionID = subscription.id },
                        onDelete: { pendingDeleteSubscriptions = [subscription] }
                    )
                }
                .listRowBackground(HopGold.row)
            }
        }
        .subscriptionCardSpacing()
        .hopGoldPage()
    }
}

private extension View {
    /// 列表自带的 onDelete 只会占住左滑，右滑的编辑按钮不会出现。两条都用滑动按钮。
    /// 版本判断不能放进 ViewBuilder，旧系统会在构造界面时崩溃。
    func subscriptionSwipes(onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        if #available(iOS 15.0, *) {
            return AnyView(swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("编辑", action: onEdit)
                    .tint(Color(red: 0.62, green: 0.45, blue: 0.18))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 不用 destructive：那个角色会立刻播放删行动画，确认前卡片就会往上走。
                Button("删除", action: onDelete)
                    .tint(.red)
            })
        } else {
            return AnyView(contextMenu {
                Button("编辑", action: onEdit)
                Button("删除", action: onDelete)
            })
        }
    }
}

private struct EditSubscriptionView: View {
    @EnvironmentObject private var library: IOSLibrary
    @Environment(\.presentationMode) private var presentation
    var subscriptionID: UUID
    @State private var name = ""
    @State private var urlText = ""
    @State private var draft = ""
    @State private var loaded = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var scope: IOSNodeScope = .all
    @State private var selecting = false
    @State private var picked: Set<UUID> = []
    @State private var pendingDelete: [UUID] = []
    @State private var shareField = ShareFieldBox()

    private var subscription: Subscription? {
        library.subscriptions.first { $0.id == subscriptionID }
    }

    private var shareNodes: [ProxyNode] {
        IOSNodeSort.byLatency(library.connectableNodes.filter { $0.subscriptionID == subscriptionID })
    }

    private var shown: [ProxyNode] {
        shareNodes.filter(scope.matches)
    }

    var body: some View {
        NavigationView {
            Form {
                if let message {
                    Section { Text(message).foregroundColor(messageIsError ? .red : HopGold.light) }
                        .listRowBackground(HopGold.row)
                }
                if let subscription {
                    Section(header: Text("名称")) {
                        TextField("订阅组名称", text: $name)
                            .disableAutocorrection(true)
                    }
                    .listRowBackground(HopGold.row)
                    if subscription.sourceKind == .remoteURL {
                        Section(header: Text("订阅地址")) {
                            TextField("https://", text: $urlText)
                                .autocapitalization(.none)
                                .keyboardType(.URL)
                                .disableAutocorrection(true)
                        }
                        .listRowBackground(HopGold.row)
                    }
                    updateSection(subscription)
                    if subscription.sourceKind == .shareLinks {
                        addLinksSection
                        existingLinksSection
                    }
                } else {
                    Text("这个订阅组已经不在了。")
                        .foregroundColor(.secondary)
                        .listRowBackground(HopGold.row)
                }
            }
            .hopGoldPage()
            .hopPageTitle(Text("编辑订阅"))
            .navigationBarItems(
                leading: Button("取消") { presentation.wrappedValue.dismiss() }.foregroundColor(HopGold.light),
                trailing: Button("完成") { save() }.foregroundColor(HopGold.light)
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HopGold.light)
        .onAppear(perform: load)
        .overlay(deletePrompt)
    }

    private func updateSection(_ subscription: Subscription) -> some View {
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

    private var addLinksSection: some View {
        Section(header:
            HStack {
                Text("增加分享链接")
                Spacer(minLength: 8)
                Button("粘贴") { pasteDraft() }
                    .buttonStyle(BorderlessButtonStyle())
                    .foregroundColor(HopGold.light)
            }
            .hopHeaderCase()
        ) {
            ShareTextEditor(text: $draft, field: shareField)
                .frame(minHeight: 120)
            Button("加入") { addLinks() }
                .foregroundColor(HopGold.light)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .listRowBackground(HopGold.row)
    }

    private var existingLinksSection: some View {
        Section(header: Text("已有节点")) {
            NodeScopeChips(scope: $scope, includeAll: true) { item in
                shareNodes.filter(item.matches).count
            }
            .frame(maxWidth: .infinity)
            .frame(height: NodeScopeChips.height)
            .listRowBackground(Color.clear)
            .hiddenRowSeparator()
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .environment(\.defaultMinListRowHeight, NodeScopeChips.height)
            HStack(spacing: 12) {
                Button("筛选删除") { askDelete(shown.map(\.id)) }
                    .disabled(shown.isEmpty)
                Spacer(minLength: 8)
                Button(selecting ? "取消" : "批量删除") {
                    selecting.toggle()
                    if !selecting { picked.removeAll() }
                }
                if selecting {
                    Button("删除所选") { askDelete(Array(picked)) }
                        .disabled(picked.isEmpty)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(HopGold.light)
            .buttonStyle(BorderlessButtonStyle())
            if shown.isEmpty {
                Text(shareNodes.isEmpty ? "还没有分享链接。" : "这个筛选下没有节点。")
                    .foregroundColor(.secondary)
            }
            ForEach(shown) { node in
                shareRow(node)
            }
        }
        .listRowBackground(HopGold.row)
    }

    private func shareRow(_ node: ProxyNode) -> some View {
        let marked = picked.contains(node.id)
        return HStack(spacing: 10) {
            if selecting {
                Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(HopGold.light)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(node.displayTitle)
                Text(availabilityLine(node))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selecting else { return }
            if marked { picked.remove(node.id) } else { picked.insert(node.id) }
        }
    }

    private func availabilityLine(_ node: ProxyNode) -> String {
        let label: String
        if IOSNodeScope.available.matches(node) { label = "可用" }
        else if IOSNodeScope.unavailable.matches(node) { label = "不可用" }
        else if IOSNodeScope.failed.matches(node) { label = "失败" }
        else if IOSNodeScope.untested.matches(node) { label = "未测试" }
        else { label = "测试中" }
        return node.latencyText == "—" ? label : "\(label) · \(node.latencyText)"
    }

    @ViewBuilder private var deletePrompt: some View {
        if !pendingDelete.isEmpty {
            HopThemePrompt(
                title: "删除节点",
                message: "删除 \(pendingDelete.count) 个节点？对应分享链接会一起去掉，之后更新不会再加回来。",
                buttons: [
                    HopPromptButton(title: "删除", emphasized: true) {
                        library.deleteSubscriptionNodes(Set(pendingDelete), subscriptionID: subscriptionID)
                        picked.subtract(pendingDelete)
                        pendingDelete = []
                        message = nil
                    },
                    HopPromptButton(title: "取消", emphasized: false) { pendingDelete = [] }
                ],
                onScrim: { pendingDelete = [] }
            )
        }
    }

    private func load() {
        guard !loaded, let subscription else { return }
        loaded = true
        name = subscription.name
        urlText = subscription.originalURL
    }

    private func pasteDraft() {
        if let text = ShareClipboard.text() {
            draft = text
            message = nil
        } else {
            showMessage(ShareClipboard.unavailableMessage, error: true)
        }
    }

    private func addLinks() {
        do {
            let result = try library.appendShareLinks(draft, to: subscriptionID)
            if result.added == 0 {
                showMessage("这些分享链接已经在这个订阅组里。", error: false)
                return
            }
            draft = ""
            var text = "已增加 \(result.added) 个节点。"
            if result.skipped > 0 { text += "跳过 \(result.skipped) 条无效链接。" }
            showMessage(text, error: false)
        } catch {
            showMessage(error.localizedDescription, error: true)
        }
    }

    private func showMessage(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private func askDelete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showMessage("请填写名称。", error: true)
            return
        }
        guard let subscription else {
            presentation.wrappedValue.dismiss()
            return
        }
        if subscription.sourceKind == .remoteURL {
            let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                showMessage("请输入订阅地址。", error: true)
                return
            }
            guard URL(string: url)?.isFileURL != true else {
                showMessage("请输入订阅网址，而不是文件地址。", error: true)
                return
            }
            library.renameSubscription(subscriptionID, to: trimmed)
            if library.replaceSubscriptionURL(subscriptionID, with: url) {
                Task { await library.refreshSubscription(subscriptionID) }
            }
        } else {
            library.renameSubscription(subscriptionID, to: trimmed)
        }
        presentation.wrappedValue.dismiss()
    }
}

/// 类型选择和所在行用同一个外框。选中左侧时左缘贴左边框，选中右侧时右缘贴右边框。
private struct SubscriptionKindPicker: View {
    @Binding var kind: SubscriptionSourceKind
    @LegacyAppStorage(IOSSettings.themeKey) private var themeValue = IOSTheme.blackGold.rawValue

    private var xianxia: Bool { IOSTheme(rawValue: themeValue) == .xianxia }

    var body: some View {
        HStack(spacing: 0) {
            segment(.remoteURL, title: "订阅地址")
            segment(.shareLinks, title: "分享链接")
        }
        .frame(height: 40)
        .background(card)
    }

    private func segment(_ value: SubscriptionSourceKind, title: String) -> some View {
        Button { kind = value } label: {
            Text(title)
                .font(.subheadline.weight(kind == value ? .semibold : .regular))
                .foregroundColor(kind == value ? .white : HopGold.light)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(BorderlessButtonStyle())
        .legacyAccessibilityAddTraits(kind == value ? .isSelected : [])
    }

    @ViewBuilder private var card: some View {
        if xianxia {
            kindCard(RoundedRectangle(cornerRadius: 22))
        } else {
            kindCard(GoldCutPanel())
        }
    }

    private func kindCard<S: Shape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(xianxia
                ? LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.44), Color(red: 0.04, green: 0.25, blue: 0.27), Color(red: 0.025, green: 0.13, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                : LinearGradient(colors: [Color(white: 0.24), Color(red: 0.10, green: 0.09, blue: 0.075), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(xianxia
                ? LinearGradient(colors: [Color(red: 0.45, green: 0.70, blue: 0.68), Color(red: 0.24, green: 0.48, blue: 0.48)], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(white: 0.36), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                .mask(halfMask)
        }
        .overlay(shape.stroke(HopGold.metal, lineWidth: xianxia ? 1.5 : 2))
        .overlay(shape.stroke(HopGold.light.opacity(xianxia ? 0.35 : 0.4), lineWidth: 0.6).padding(xianxia ? 3 : 4))
    }

    private var halfMask: some View {
        GeometryReader { geo in
            Color.white
                .frame(width: geo.size.width / 2, height: geo.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: kind == .remoteURL ? .leading : .trailing)
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
    @State private var pasteNotice: String?
    @State private var pasteNoticeTask: Task<Void, Never>?
    @State private var shareField = ShareFieldBox()

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
                    SubscriptionKindPicker(kind: $kind)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        .listRowBackground(Color.clear)
                        .hiddenRowSeparator()
                }
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
                            Button("粘贴") {
                                applyPastedAddress(UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(HopGold.light)
                        }
                    }
                    .listRowBackground(HopGold.row)
                } else {
                    Section(header:
                        HStack(alignment: .center, spacing: 8) {
                            Text("分享链接")
                            Spacer(minLength: 8)
                            HeaderPasteButton(action: { pasteShareLinks() })
                                .frame(width: Self.shareHeaderPasteWidth, height: Self.shareHeaderLineHeight)
                                .clipped()
                        }
                        .font(.footnote)
                        .lineLimit(1)
                        .hopHeaderCase()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ) {
                        ShareTextEditor(text: $shareText, field: shareField)
                            .frame(minHeight: 160)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                leading: Button("取消") { presentation.wrappedValue.dismiss() }
                    .foregroundColor(HopGold.light),
                trailing: Button(library.isBusy ? "添加中…" : "添加") { Task { await save() } }
                    .foregroundColor(HopGold.light)
                    .disabled(library.isBusy || imported)
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HopGold.light)
        .overlay(pasteNoticeBar)
        .overlay(addResultPrompt)
        .sheet(isPresented: $showingTestTargets, onDismiss: {
            if startAfterTargetSelection { library.startBatch(importedNodeIDs) }
            presentation.wrappedValue.dismiss()
        }) {
            TestTargetPicker { startAfterTargetSelection = true }
        }
    }

    private static var shareHeaderLineHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight)
    }

    private static var shareHeaderPasteWidth: CGFloat {
        ceil(("粘贴" as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)]).width)
    }

    private static var pasteUnavailableMessage: String { ShareClipboard.unavailableMessage }

    private func showPasteNotice(_ text: String) {
        pasteNotice = text
        pasteNoticeTask?.cancel()
        pasteNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            pasteNotice = nil
        }
    }

    private var pasteNoticeBar: some View {
        VStack {
            Spacer()
            if let pasteNotice {
                Text(pasteNotice)
                    .font(.body.weight(.semibold))
                    .foregroundColor(HopGold.light)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(HopThemePlate())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
            }
        }
        .allowsHitTesting(false)
    }

    private func pasteShareLinks() {
        // 点按后再读全文。系统这时才弹出粘贴授权；ss、vmess 等不是普通网址，不能先按网页规则丢掉。
        if let text = Self.clipboardText(from: UIPasteboard.general) {
            applySharePaste(text)
            return
        }
        if pasteIntoShareField() { return }
        showPasteNotice(Self.pasteUnavailableMessage)
    }

    private static func clipboardText(from board: UIPasteboard) -> String? {
        ShareClipboard.text(from: board)
    }

    private func pasteIntoShareField() -> Bool {
        guard let view = shareField.textView else { return false }
        view.becomeFirstResponder()
        let before = view.text ?? ""
        view.paste(nil)
        let after = view.text ?? ""
        guard after != before, !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        shareText = after
        pasteNotice = nil
        return true
    }

    private func applySharePaste(_ value: String?) {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            showPasteNotice(Self.pasteUnavailableMessage)
            return
        }
        shareText = text
        pasteNotice = nil
    }

    private func applyPastedAddress(_ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            showPasteNotice("无法读取剪贴板中的网址，请尝试复制网址文本。")
            return
        }
        guard URL(string: value)?.isFileURL != true else {
            showPasteNotice("剪贴板中是文件地址，请复制订阅网址文本后重试。")
            return
        }
        urlText = value
        pasteNotice = nil
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

    @ViewBuilder private var addResultPrompt: some View {
        if showingTestPrompt {
            HopThemePrompt(
                title: imported ? "添加成功" : "添加失败",
                message: addResultMessage,
                buttons: addResultButtons,
                onScrim: { showingTestPrompt = false }
            )
        }
    }

    private var addResultMessage: String {
        if !imported { return message ?? "请检查订阅内容后重试。" }
        if importedNodeIDs.isEmpty { return "已添加，但没有可测试的节点。" }
        if library.batchTotal > 0 { return "已添加 \(importedNodeIDs.count) 个节点。当前已有测速任务，请稍后再测试。" }
        return "已添加 \(importedNodeIDs.count) 个节点，是否立即测试延迟？"
    }

    private var addResultButtons: [HopPromptButton] {
        if !imported {
            return [HopPromptButton(title: "确定", emphasized: true) { showingTestPrompt = false }]
        }
        if !importedNodeIDs.isEmpty && library.batchTotal == 0 {
            return [
                HopPromptButton(title: "立即测试", emphasized: true) {
                    showingTestPrompt = false
                    beginTesting()
                },
                HopPromptButton(title: "暂不测试", emphasized: false) {
                    showingTestPrompt = false
                    presentation.wrappedValue.dismiss()
                }
            ]
        }
        return [HopPromptButton(title: "确定", emphasized: true) {
            showingTestPrompt = false
            presentation.wrappedValue.dismiss()
        }]
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
    @EnvironmentObject private var library: IOSLibrary
    @LegacyAppStorage(IOSSettings.themeKey) private var selectedTheme = IOSTheme.blackGold.rawValue
    @LegacyAppStorage(IOSSettings.showSubscriptionNoticesKey) private var showSubscriptionNotices = false
    @LegacyAppStorage(IOSSettings.useAvailableOnlyKey) private var useAvailableOnly = true
    @LegacyAppStorage(IOSSettings.useExitIPOnlyKey) private var useExitIPOnly = true
    @LegacyAppStorage(IOSSettings.useCountryScopeKey) private var countryScope = IOSUseCountryScope.all.rawValue
    @LegacyAppStorage(IOSSettings.useExcludedCountriesKey) private var excludedCountries = "[]"
    @LegacyAppStorage(IOSSettings.useIncludedCountriesKey) private var includedCountries = "[]"
    @LegacyAppStorage(IOSSettings.selectedTargetsKey) private var selectedTargetsData = ""
    @LegacyAppStorage(IOSSettings.customTargetsKey) private var customTargetsData = ""
    @State private var timeout = IOSSettings.timeoutSeconds
    @State private var batchTimeout = IOSSettings.batchTimeoutSeconds
    @State private var autoSelectTimeout = IOSSettings.autoSelectTimeoutSeconds
    @State private var usageHelp: UsageHelp?
    @State private var countryGuide = false
    @State private var countryGuideScope = ""
    @State private var showingAddSubscription = false
    @State private var showingCountryTestTargets = false
    @State private var countryTestAsk = false
    @State private var showingCountryPicker = false

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
            Section(header: Text("使用范围").foregroundColor(HopGold.light)) {
                HStack(spacing: 8) {
                    Text("国家")
                    usageMark("国家", "仅使用非排除出口 IP 国家，或仅使用选中在内的出口 IP 国家。默认全部国家。按测到的出口 IP，不看节点名称。")
                    Spacer()
                    if countryScope != IOSUseCountryScope.all.rawValue && !activeCountries.isEmpty {
                        Button {
                            showingCountryPicker = true
                        } label: {
                            Text("已选 \(activeCountries.count) 个")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    Picker("", selection: countryScopeSelection) {
                        ForEach(IOSUseCountryScope.allCases) { scope in
                            Text(scope.title).tag(scope.rawValue)
                        }
                    }
                    .modifier(UsagePickerLabel())
                }
            }
            .listRowBackground(HopGold.row)
            Section(header: Text("测试目标").foregroundColor(HopGold.light), footer: Text("测速会检查所有选中目标，全部成功才算可用；延迟显示最慢的一项。")) {
                targetLink("网页")
                targetLink("App")
            }
            .listRowBackground(HopGold.row)
            Section(header: Text("自动优选").foregroundColor(HopGold.light)) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("可用")
                        usageMark("可用", "仅使用可用节点。")
                        Spacer()
                        Toggle("", isOn: $useAvailableOnly).modifier(UsagePickerLabel())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("出口")
                        usageMark("出口", "仅使用有出口 IP 的节点。")
                        Spacer()
                        Toggle("", isOn: $useExitIPOnly).modifier(UsagePickerLabel())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Text("超时")
                    usageMark("超时", "当前连接超过所选时间还没连上，就自动切换下一个符合条件的节点。")
                    Spacer()
                    Picker("", selection: Binding(get: { autoSelectTimeout }, set: {
                        autoSelectTimeout = $0
                        IOSSettings.autoSelectTimeoutSeconds = $0
                    })) {
                        ForEach(IOSSettings.autoSelectTimeoutChoices, id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds)
                        }
                    }
                    .modifier(UsagePickerLabel())
                }
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
            Section(header: Text("订阅").foregroundColor(HopGold.light), footer: Text("在订阅详情中显示服务商提供的公告和账户信息。")) {
                Toggle("显示订阅信息", isOn: $showSubscriptionNotices)
            }
            .listRowBackground(HopGold.row)
        }
        .hopGoldPage()
        .hopPageTitle(Text("设置"))
        .overlay(usageHelpPrompt)
        .overlay(countryGuidePrompt)
        .overlay(countryTestAskPrompt)
        .sheet(isPresented: $showingAddSubscription, onDismiss: revertCountryScopeIfUnselected) {
            AddSubscriptionView().environmentObject(library)
        }
        .sheet(isPresented: $showingCountryTestTargets, onDismiss: revertCountryScopeIfUnselected) {
            TestTargetPicker { beginCountryTest() }
        }
        .sheet(isPresented: $showingCountryPicker, onDismiss: revertCountryScopeIfUnselected) {
            countryPickerSheet
        }
    }

    private var countryPickerSheet: some View {
        NavigationView {
            List {
                ForEach(countryChoices, id: \.code) { country in
                    Button { toggleCountry(country.code) } label: {
                        HStack {
                            Text("\(country.flag) \(country.name)").foregroundColor(.primary)
                            Spacer()
                            if activeCountries.contains(country.code) {
                                Image(systemName: "checkmark").foregroundColor(HopGold.light)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .listRowBackground(HopGold.row)
                }
            }
            .hopGoldPage()
            .hopPageTitle(Text(IOSUseCountryScope(rawValue: countryScope)?.title ?? "选择国家"))
            .navigationBarItems(trailing: Button("完成") { showingCountryPicker = false }
                .foregroundColor(HopGold.light))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HopGold.light)
    }

    private var countryScopeSelection: Binding<String> {
        Binding(get: { countryScope }, set: {
            countryScope = $0
            presentCountryChoice()
        })
    }

    private func presentCountryChoice() {
        guard countryScope != IOSUseCountryScope.all.rawValue else {
            countryGuide = false
            countryGuideScope = ""
            return
        }
        if countryChoices.isEmpty {
            offerCountryGuide()
        } else {
            countryGuide = false
            showingCountryPicker = true
        }
    }

    private var countryGuidePrompt: some View {
        Group {
            if countryGuide {
                HopThemePrompt(
                    title: "还没有出口国家",
                    message: library.connectableNodes.isEmpty
                        ? "出口国家要先有节点，并完成延迟测试才会记下。请先添加订阅，测试后再回来选择国家。"
                        : "出口国家来自延迟测试记下的出口 IP，不看节点名称。请先测试节点，测完再回来选择要排除或指定的国家。",
                    buttons: countryGuideButtons,
                    onScrim: {
                        countryGuide = false
                        revertCountryScopeIfUnselected()
                    }
                )
            }
        }
    }

    private var countryGuideButtons: [HopPromptButton] {
        var buttons: [HopPromptButton] = []
        if library.connectableNodes.isEmpty {
            buttons.append(HopPromptButton(title: "添加订阅", emphasized: true) {
                countryGuide = false
                showingAddSubscription = true
            })
        } else {
            buttons.append(HopPromptButton(title: "去测试", emphasized: true) {
                countryGuide = false
                countryTestAsk = true
            })
        }
        buttons.append(HopPromptButton(title: "稍后", emphasized: false) {
            countryGuide = false
            revertCountryScopeIfUnselected()
        })
        return buttons
    }

    private var countryTestAskPrompt: some View {
        Group {
            if countryTestAsk {
                HopThemePrompt(
                    title: countryTestAskTitle,
                    message: countryTestAskMessage,
                    buttons: countryTestAskButtons,
                    onScrim: {
                        countryTestAsk = false
                        revertCountryScopeIfUnselected()
                    }
                )
            }
        }
    }

    private var countryTestCount: Int { library.connectableNodes.count }

    private var countryTestAskTitle: String {
        library.batchTotal > 0 ? "正在测试" : "开始测试"
    }

    private var countryTestAskMessage: String {
        if library.batchTotal > 0 {
            return "当前正在测试 \(library.batchDone)/\(library.batchTotal)。请等这次结束后再测试。"
        }
        if IOSSettings.selectedTestURLs.isEmpty {
            return "还没有测试目标。请先选择目标，选好后会测试全部 \(countryTestCount) 个节点，并记下出口国家。"
        }
        return "将测试全部 \(countryTestCount) 个节点的延迟，并记下出口国家。现在开始吗？"
    }

    private var countryTestAskButtons: [HopPromptButton] {
        if library.batchTotal > 0 {
            return [HopPromptButton(title: "确定", emphasized: true) {
                countryTestAsk = false
                revertCountryScopeIfUnselected()
            }]
        }
        if IOSSettings.selectedTestURLs.isEmpty {
            return [
                HopPromptButton(title: "选择目标", emphasized: true) {
                    countryTestAsk = false
                    showingCountryTestTargets = true
                },
                HopPromptButton(title: "取消", emphasized: false) {
                    countryTestAsk = false
                    revertCountryScopeIfUnselected()
                }
            ]
        }
        return [
            HopPromptButton(title: "开始测试", emphasized: true) {
                countryTestAsk = false
                beginCountryTest()
            },
            HopPromptButton(title: "取消", emphasized: false) {
                countryTestAsk = false
                revertCountryScopeIfUnselected()
            }
        ]
    }

    private func beginCountryTest() {
        let count = countryTestCount
        library.startBatch(library.connectableNodes.map(\.id))
        library.showNotice("已开始测试 \(count) 个节点。测完会记下出口国家。")
        revertCountryScopeIfUnselected()
    }

    private func revertCountryScopeIfUnselected() {
        guard countryScope != IOSUseCountryScope.all.rawValue, activeCountries.isEmpty else { return }
        countryScope = IOSUseCountryScope.all.rawValue
        countryGuideScope = ""
    }

    private func offerCountryGuide() {
        let needed = countryScope != IOSUseCountryScope.all.rawValue && countryChoices.isEmpty
        guard needed else {
            countryGuide = false
            countryGuideScope = ""
            return
        }
        guard countryGuideScope != countryScope else { return }
        countryGuideScope = countryScope
        countryGuide = true
    }

    private var usageHelpPrompt: some View {
        Group {
            if let help = usageHelp {
                HopThemePrompt(
                    title: help.title,
                    message: help.message,
                    buttons: [HopPromptButton(title: "确定", emphasized: true) { usageHelp = nil }],
                    onScrim: { usageHelp = nil }
                )
            }
        }
    }

    private func usageMark(_ title: String, _ message: String) -> some View {
        Button {
            usageHelp = UsageHelp(title: title, message: message)
        } label: {
            Text("?")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(HopGold.light)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(HopGold.light, lineWidth: 1))
        }
        .buttonStyle(BorderlessButtonStyle())
    }

    private var activeCountries: Set<String> {
        _ = excludedCountries
        _ = includedCountries
        return countryScope == IOSUseCountryScope.included.rawValue ? IOSSettings.useIncludedCountries : IOSSettings.useExcludedCountries
    }

    private var countryChoices: [(code: String, name: String, flag: String)] {
        var codes = activeCountries
        for node in library.connectableNodes {
            if let code = IOSSettings.measuredCountryCode(node) { codes.insert(code) }
        }
        return codes.sorted().map { code in
            (code, CountryResolver.displayName(for: code), FlagResolver.flag(for: code))
        }
    }

    private func toggleCountry(_ code: String) {
        var codes = activeCountries
        if codes.contains(code) { codes.remove(code) } else { codes.insert(code) }
        if countryScope == IOSUseCountryScope.included.rawValue {
            IOSSettings.useIncludedCountries = codes
            includedCountries = UserDefaults.standard.string(forKey: IOSSettings.useIncludedCountriesKey) ?? "[]"
        } else {
            IOSSettings.useExcludedCountries = codes
            excludedCountries = UserDefaults.standard.string(forKey: IOSSettings.useExcludedCountriesKey) ?? "[]"
        }
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

private struct UsageHelp: Identifiable {
    let title: String
    let message: String
    var id: String { title }
}

private struct UsagePickerLabel: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 14.0, *) {
            content.labelsHidden()
        } else {
            content
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
                                HStack(spacing: 12) {
                                    if IOSSettings.showsLogo(for: target.url) {
                                        TestTargetMark(url: target.url)
                                    }
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
            .navigationBarItems(leading: Button("取消") { presentation.wrappedValue.dismiss() }
                    .foregroundColor(HopGold.light),
                trailing: Button("开始测试") {
                    presentation.wrappedValue.dismiss()
                    start()
                }
                .foregroundColor(HopGold.light)
                .disabled(selectedURLs.isEmpty))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HopGold.light)
    }
}

private struct TestTargetMark: View {
    let url: String

    var body: some View {
        if let asset = IOSSettings.logoAsset(for: url) {
            Image(asset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .legacyAccessibilityHidden(true)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(HopGold.light)
                .frame(width: 28, height: 28)
                .legacyAccessibilityHidden(true)
        }
    }
}

private struct TestTargetsView: View {
    let kind: String
    @LegacyAppStorage(IOSSettings.selectedTargetsKey) private var selectedTargetsData = ""
    @LegacyAppStorage(IOSSettings.customTargetsKey) private var customTargetsData = ""
    @State private var showingAdd = false
    @State private var pendingDeleteTargets: [IOSSettings.Target] = []

    var body: some View {
        List {
            presetSection
            let custom = availableTargets.filter { $0.kind == kind && !IOSSettings.builtInTargets.contains($0) }
            if !custom.isEmpty {
                Section(header: Text("自定义").foregroundColor(HopGold.light), footer: Text("向左滑动后需要确认，才会删除自定义目标。")) {
                    ForEach(custom) { target in
                        targetButton(target)
                    }
                    .onDelete { offsets in
                        pendingDeleteTargets = offsets.map { custom[$0] }
                    }
                }
                .listRowBackground(HopGold.row)
            }
        }
        .hopGoldPage()
        .hopPageTitle(Text("\(kind)测试目标"))
        .navigationBarItems(trailing: Button { showingAdd = true } label: {
            Image(systemName: "plus")
                .foregroundColor(HopGold.light)
        }.legacyAccessibilityLabel(kind == "App" ? "从已安装应用添加" : "添加测试目标"))
        .accentColor(HopGold.light)
        .sheet(isPresented: $showingAdd) {
            if kind == "App" {
                AddAppTargetSheet()
            } else {
                AddTestTargetView(kind: kind)
            }
        }
        .overlay(targetDeletePrompt)
    }

    @ViewBuilder private var presetSection: some View {
        if kind == "App" {
            Section(header: Text("预设").foregroundColor(HopGold.light), footer: Text("测的是 App 自己的服务器，不是官网网页。TikTok 会检查 App 服务器，网页能打开不算通过；有多个地区时，连上一个即可。")) {
                presetRows
            }
            .listRowBackground(HopGold.row)
        } else {
            Section(header: Text("预设").foregroundColor(HopGold.light)) {
                presetRows
            }
            .listRowBackground(HopGold.row)
        }
    }

    @ViewBuilder private var presetRows: some View {
        ForEach(IOSSettings.builtInTargets.filter { $0.kind == kind }) { target in
            targetButton(target)
        }
    }

    @ViewBuilder private var targetDeletePrompt: some View {
        if !pendingDeleteTargets.isEmpty {
            let count = pendingDeleteTargets.count
            HopThemePrompt(
                title: count == 1 ? "删除测试目标" : "删除 \(count) 个测试目标",
                message: count == 1
                    ? "删除「\(pendingDeleteTargets[0].title)」？之后测速不再使用它。"
                    : "删除这 \(count) 个自定义测试目标？之后测速不再使用它们。",
                buttons: [
                    HopPromptButton(title: "删除", emphasized: true) {
                        let urls = Set(pendingDeleteTargets.map(\.url))
                        let selected = selectedURLs.filter { !urls.contains($0) }
                        IOSSettings.customTargets.removeAll { urls.contains($0.url) }
                        selectedTargetsData = IOSSettings.encodedTestURLs(selected)
                        pendingDeleteTargets = []
                    },
                    HopPromptButton(title: "取消", emphasized: false) { pendingDeleteTargets = [] }
                ],
                onScrim: { pendingDeleteTargets = [] }
            )
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
            HStack(spacing: 12) {
                if IOSSettings.showsLogo(for: target.url) {
                    TestTargetMark(url: target.url)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).foregroundColor(.primary)
                    if IOSSettings.probesAppServer(target.url) {
                        Text("测 App 服务器").font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if selectedURLs.contains(target.url) { Image(systemName: "checkmark").foregroundColor(HopGold.light) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .legacyAccessibilityAddTraits(selectedURLs.contains(target.url) ? .isSelected : [])
    }
}

private struct AddAppTargetSheet: View {
    @State private var manual = false

    var body: some View {
        Group {
            if manual {
                AddTestTargetView(kind: "App", onCancel: { manual = false })
            } else {
                InstalledAppTargetPicker(onManual: { manual = true })
            }
        }
    }
}

private struct InstalledAppTargetPicker: View {
    let onManual: () -> Void
    @Environment(\.presentationMode) private var presentation
    @LegacyAppStorage(IOSSettings.selectedTargetsKey) private var selectedTargetsData = ""
    @State private var installed: [IOSSettings.InstalledApp] = []
    @State private var loaded = false

    private var selectedURLs: [String] { IOSSettings.selectedTestURLs(from: selectedTargetsData) }
    private var rows: [IOSSettings.InstalledApp] {
        installed.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("已安装").foregroundColor(HopGold.light), footer: Text("只列出本机已安装的第三方应用，系统自带应用不会出现。标了「测 App 服务器」的会请求 App 自己的服务器，网页能打开不算通过。系统读不到未登记的应用；没有出现的，请手动填写网址。")) {
                    if !loaded {
                        Text("正在识别已安装应用…").foregroundColor(.secondary)
                    } else if rows.isEmpty {
                        Text("没有识别到已安装的第三方应用。").foregroundColor(.secondary)
                    } else {
                        ForEach(rows, id: \.scheme) { app in
                            Button { choose(app) } label: {
                                HStack(spacing: 12) {
                                    if IOSSettings.showsLogo(for: app.url) {
                                        TestTargetMark(url: app.url)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.title).foregroundColor(.primary)
                                        if IOSSettings.probesAppServer(app.url) {
                                            Text("测 App 服务器").font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedURLs.contains(app.url) {
                                        Image(systemName: "checkmark").foregroundColor(HopGold.light)
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .legacyAccessibilityLabel("\(app.title)，\(selectedURLs.contains(app.url) ? "已选择" : "添加为测试目标")")
                            .legacyAccessibilityAddTraits(selectedURLs.contains(app.url) ? .isSelected : [])
                        }
                    }
                }
                .listRowBackground(HopGold.row)
            }
            .hopGoldPage()
            .hopPageTitle(Text("选择应用"))
            .navigationBarItems(leading: Button("取消") { presentation.wrappedValue.dismiss() }
                    .foregroundColor(HopGold.light),
                trailing: Button("手动填写") { onManual() }
                    .foregroundColor(HopGold.light))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HopGold.light)
        .onAppear {
            guard !loaded else { return }
            installed = IOSSettings.installedApps { scheme in
                guard let url = URL(string: "\(scheme)://") else { return false }
                return UIApplication.shared.canOpenURL(url)
            }
            loaded = true
        }
    }

    private func choose(_ app: IOSSettings.InstalledApp) {
        let adopted = IOSSettings.adoptInstalledApp(app, custom: IOSSettings.customTargets, selected: selectedURLs)
        IOSSettings.customTargets = adopted.custom
        selectedTargetsData = IOSSettings.encodedTestURLs(adopted.selected)
        presentation.wrappedValue.dismiss()
    }
}

private struct AddTestTargetView: View {
    let kind: String
    var onCancel: (() -> Void)? = nil
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
            .navigationBarItems(leading: Button("取消") {
                    if let onCancel { onCancel() } else { presentation.wrappedValue.dismiss() }
                }
                    .foregroundColor(HopGold.light),
                trailing: Button("添加") { save() }
                    .foregroundColor(HopGold.light))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HopGold.light)
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

private enum ShareClipboard {
    static func text(from board: UIPasteboard = .general) -> String? {
        let text = (board.strings ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static var unavailableMessage: String {
        #if targetEnvironment(simulator)
        "模拟器没有读到剪贴板。请在模拟器窗口按 ⌘V，或先在模拟器里复制。"
        #else
        "需要允许粘贴才能读取剪贴板。"
        #endif
    }
}

private enum PasteTextLoader {
    static func load(_ providers: [NSItemProvider], done: @escaping (String?) -> Void) {
        guard !providers.isEmpty else {
            done(nil)
            return
        }
        let group = DispatchGroup()
        var parts: [Int: String] = [:]
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            group.enter()
            loadOne(provider) { text in
                if let text {
                    lock.lock()
                    parts[index] = text
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let text = parts.keys.sorted().compactMap { parts[$0] }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            done(text.isEmpty ? nil : text)
        }
    }

    private static func loadOne(_ provider: NSItemProvider, done: @escaping (String?) -> Void) {
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { object, _ in
                if let text = object, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    done(text)
                } else {
                    loadData(provider, done: done)
                }
            }
            return
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                if let text = object?.absoluteString, !text.isEmpty {
                    done(text)
                } else {
                    loadData(provider, done: done)
                }
            }
            return
        }
        loadData(provider, done: done)
    }

    private static func loadData(_ provider: NSItemProvider, done: @escaping (String?) -> Void) {
        let type = ["public.utf8-plain-text", "public.plain-text", "public.text", "public.utf16-plain-text", "public.url"]
            .first { provider.hasItemConformingToTypeIdentifier($0) }
        guard let type else { done(nil); return }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data else { done(nil); return }
            if type == "public.url", let url = URL(dataRepresentation: data, relativeTo: nil) {
                done(url.absoluteString)
                return
            }
            done(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16))
        }
    }
}

private struct HeaderPasteButton: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> TitlePasteButton {
        let button = TitlePasteButton(type: .custom)
        button.setTitle("粘贴", for: .normal)
        button.setTitleColor(UIColor(red: 1, green: 0.87, blue: 0.62, alpha: 1), for: .normal)
        button.setTitleColor(UIColor(red: 1, green: 0.87, blue: 0.62, alpha: 0.45), for: .highlighted)
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.backgroundColor = .clear
        button.clipsToBounds = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: TitlePasteButton, context: Context) {
        context.coordinator.action = action
        uiView.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        uiView.invalidateIntrinsicContentSize()
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TitlePasteButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func tap() { action?() }
    }
}

private final class TitlePasteButton: UIButton {
    override var intrinsicContentSize: CGSize {
        let font = titleLabel?.font ?? UIFont.preferredFont(forTextStyle: .footnote)
        let width = ceil((currentTitle as NSString?)?.size(withAttributes: [.font: font]).width ?? 0)
        return CGSize(width: max(width, 1), height: ceil(font.lineHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel?.frame = bounds
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -10, dy: -6).contains(point)
    }
}

private final class ShareFieldBox {
    weak var textView: UITextView?
}

private final class ShareLinkTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }

    override func paste(_ sender: Any?) {
        let before = text ?? ""
        super.paste(sender)
        if (text ?? "") != before { delegate?.textViewDidChange?(self) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        PasteTextLoader.load(itemProviders) { [weak self] text in
            guard let self else { return }
            if let text {
                self.acceptPaste(text)
            } else if let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                self.acceptPaste(raw)
            }
        }
    }

    private func acceptPaste(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = trimmed
        } else {
            insertText(trimmed)
        }
        delegate?.textViewDidChange?(self)
    }
}

private struct ShareTextEditor: UIViewRepresentable {
    @Binding var text: String
    var field: ShareFieldBox

    func makeUIView(context: Context) -> ShareLinkTextView {
        let view = ShareLinkTextView()
        field.textView = view
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(red: 1, green: 0.87, blue: 0.62, alpha: 1)
        view.tintColor = view.textColor
        view.keyboardAppearance = .dark
        view.backgroundColor = .clear
        view.isEditable = true
        view.isSelectable = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            "public.utf8-plain-text",
            "public.plain-text",
            "public.text",
            "public.url"
        ])
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ShareLinkTextView, context: Context) {
        field.textView = uiView
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
    }
}
