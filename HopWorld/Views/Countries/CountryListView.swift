import AppKit
import SwiftUI

/// 国家页做成机场出发信息板：国家是目的地，节点是航线，延迟是飞行时间。
struct CountryListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var expandedCode: String?
    @State private var selectedRouteID: UUID?
    @State private var didAutoExpand = false
    @State private var region: BoardRegion = .all
    @State private var query = ""

    private var palette: BoardPalette { BoardPalette(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            if appState.countryGroups.isEmpty {
                boardEmpty(
                    title: "信息板还没有航班",
                    detail: "添加订阅之后，节点会按国家显示在这块出发板上。"
                )
            } else {
                header
                boardDivider
                GeometryReader { geo in
                    board(compact: geo.size.width < 660)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { reconcileExpansion() }
        .onChange(of: appState.countryGroups.map(\.code)) { _ in
            if region != .all, !shownRegions.contains(region) {
                region = .all
            }
            reconcileExpansion()
        }
        .onChange(of: region) { _ in reconcileExpansion() }
        .onChange(of: query) { _ in reconcileExpansion() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEPARTURES · 出发信息板")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                    HStack(spacing: 8) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Text("目的地")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(palette.text)
                            .fixedSize()
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(palette.text)
                    }
                    Text(summaryLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.subtext)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shownRegions) { item in
                            terminalTab(item)
                        }
                    }
                    .padding(.vertical, 1)
                }

                searchField
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// 整页一块信息板：每个国家一行，点击就地展开它的航线。
    private func board(compact: Bool) -> some View {
        ScrollView {
            let rows = sortedGroups(filteredGroups)
            if rows.isEmpty {
                boardEmpty(title: "没有这个目的地", detail: "换一个洲，或改一下搜索内容。")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, group in
                            let expanded = expandedCode == group.code
                            CountryBoardRow(
                                group: group,
                                region: BoardRegion.classify(group.code),
                                palette: palette,
                                compact: compact,
                                striped: index % 2 == 1,
                                isExpanded: expanded,
                                isCurrent: isCurrentCountry(group),
                                isConnectingCountry: isConnectingCountry(group),
                                nodes: expanded ? routes(in: group) : [],
                                queryHidesSome: expanded && queryHidesNodes(in: group),
                                connectedNodeID: connectedNodeID,
                                connectingNodeID: connectingNodeID,
                                selectedNodeID: selectedRouteID,
                                onSelectNode: { id in
                                    selectedRouteID = selectedRouteID == id ? nil : id
                                },
                                isTesting: !appState.testManager.canRetest
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedCode = expanded ? nil : group.code
                                }
                            }
                        }
                    } header: {
                        columnHeader(compact: compact)
                            .background(palette.boardTop)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 与行内列宽一一对应的表头，钉在信息板顶部。
    private func columnHeader(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Text("CODE")
                .frame(width: 58, alignment: .leading)
            Text("目的地")
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text("区域")
                    .frame(width: 76, alignment: .leading)
            }
            Text("航线")
                .frame(width: 44, alignment: .trailing)
            if !compact {
                Text("可用")
                    .frame(width: 56, alignment: .trailing)
            }
            Text("最快")
                .frame(width: 64, alignment: .trailing)
            Text("状态")
                .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .tracking(1)
        .foregroundStyle(palette.subtext)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.subtext)
            TextField("搜索目的地或航线", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.text)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.subtext)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.line, lineWidth: 0.8)
        }
    }

    private func terminalTab(_ item: BoardRegion) -> some View {
        let selected = region == item
        return Button {
            region = item
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.tint)
                    .frame(width: 6, height: 6)
                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Text("\(count(for: item))")
                    .font(.system(size: 11, design: .monospaced))
                    .opacity(0.75)
            }
            .foregroundStyle(selected ? palette.onAccent : palette.subtext)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? palette.accent : palette.chip)
            )
            .overlay {
                Capsule().strokeBorder(selected ? Color.clear : palette.line, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func boardEmpty(title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.accent.opacity(0.8))
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(palette.subtext)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var boardDivider: some View {
        Rectangle().fill(palette.line).frame(height: 0.8)
    }

    private var summaryLine: String {
        let countries = appState.countryGroups.count
        let nodes = appState.countryGroups.reduce(0) { $0 + $1.nodes.count }
        let usable = appState.countryGroups.reduce(0) { $0 + $1.availableCount }
        return "\(countries) 目的地 · \(usable) 可用 · \(nodes) 航线"
    }

    private var shownRegions: [BoardRegion] {
        var items: [BoardRegion] = [.all]
        for item in BoardRegion.chapterOrder where appState.countryGroups.contains(where: { BoardRegion.classify($0.code) == item }) {
            items.append(item)
        }
        return items
    }

    private func count(for item: BoardRegion) -> Int {
        if item == .all { return appState.countryGroups.count }
        return appState.countryGroups.filter { BoardRegion.classify($0.code) == item }.count
    }

    private var filteredGroups: [CountryGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.countryGroups.filter { group in
            (region == .all || BoardRegion.classify(group.code) == region) && matches(group, needle: needle)
        }
    }

    private var connectedNodeID: UUID? {
        guard appState.connection.state.status == .connected else { return nil }
        return appState.connection.state.currentNodeID
    }

    private var connectingNodeID: UUID? {
        guard appState.connection.state.status == .connecting else { return nil }
        return appState.connection.state.currentNodeID
    }

    private func isCurrentCountry(_ group: CountryGroup) -> Bool {
        guard let connectedNodeID else { return false }
        return group.nodes.contains { $0.id == connectedNodeID }
    }

    private func isConnectingCountry(_ group: CountryGroup) -> Bool {
        if let connectingNodeID, group.nodes.contains(where: { $0.id == connectingNodeID }) {
            return true
        }
        guard appState.connection.state.status == .connecting else { return false }
        return appState.connection.state.currentCountryCode?.uppercased() == group.code.uppercased()
    }

    private func reconcileExpansion() {
        let codes = filteredGroups.map(\.code)
        if let expandedCode {
            // 被过滤掉就收起，不强行换到别的国家。
            if !codes.contains(expandedCode) {
                self.expandedCode = nil
            }
            return
        }
        // 只在第一次进入时自动展开当前出口国。
        guard !didAutoExpand else { return }
        didAutoExpand = true
        if let connected = appState.countryGroups.first(where: isCurrentCountry), codes.contains(connected.code) {
            expandedCode = connected.code
        }
    }

    private func matches(_ group: CountryGroup, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if group.name.localizedCaseInsensitiveContains(needle) { return true }
        if group.code.localizedCaseInsensitiveContains(needle) { return true }
        return group.nodes.contains {
            appState.settings.nodeDisplayTitle($0).localizedCaseInsensitiveContains(needle) ||
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private func queryHidesNodes(in group: CountryGroup) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let countryHit = group.name.localizedCaseInsensitiveContains(needle) ||
            group.code.localizedCaseInsensitiveContains(needle)
        guard !countryHit else { return false }
        return routes(in: group).count < group.nodes.count
    }

    private func routes(in group: CountryGroup) -> [ProxyNode] {
        let ordered = routeOrder(group.nodes)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        let countryHit = group.name.localizedCaseInsensitiveContains(needle) ||
            group.code.localizedCaseInsensitiveContains(needle)
        if countryHit { return ordered }
        return ordered.filter {
            appState.settings.nodeDisplayTitle($0).localizedCaseInsensitiveContains(needle) ||
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private func sortedGroups(_ groups: [CountryGroup]) -> [CountryGroup] {
        groups.sorted { lhs, rhs in
            if lhs.hasUsableNode != rhs.hasUsableNode { return lhs.hasUsableNode }
            switch (lhs.bestLatency, rhs.bestLatency) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func routeOrder(_ nodes: [ProxyNode]) -> [ProxyNode] {
        nodes.sorted { lhs, rhs in
            let left = routeRank(lhs)
            let right = routeRank(rhs)
            if left != right { return left < right }
            let leftLatency = lhs.lastLatency ?? Int.max
            let rightLatency = rhs.lastLatency ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            return appState.settings.nodeDisplayTitle(lhs).localizedStandardCompare(appState.settings.nodeDisplayTitle(rhs)) == .orderedAscending
        }
    }

    private func routeRank(_ node: ProxyNode) -> Int {
        if node.id == connectedNodeID { return 0 }
        if node.id == connectingNodeID { return 1 }
        switch node.resolvedTestStatus {
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
            return 2
        case .testing:
            return 3
        case .untested:
            return 4
        case .failed:
            return 5
        case .unavailable:
            return 6
        }
    }
}

private enum BoardRegion: String, CaseIterable, Identifiable {
    case all
    case asia
    case europe
    case americas
    case oceania
    case africa
    case other

    var id: String { rawValue }

    static let chapterOrder: [BoardRegion] = [.asia, .europe, .americas, .oceania, .africa, .other]

    var title: String {
        switch self {
        case .all: return "全部"
        case .asia: return "亚洲"
        case .europe: return "欧洲"
        case .americas: return "美洲"
        case .oceania: return "大洋洲"
        case .africa: return "非洲"
        case .other: return "其他"
        }
    }

    var latin: String {
        switch self {
        case .all: return "ALL"
        case .asia: return "ASIA"
        case .europe: return "EUROPE"
        case .americas: return "AMERICAS"
        case .oceania: return "OCEANIA"
        case .africa: return "AFRICA"
        case .other: return "ELSEWHERE"
        }
    }

    var tint: Color {
        switch self {
        case .all: return Color(red: 0.85, green: 0.60, blue: 0.15)
        case .asia: return Color(red: 0.16, green: 0.56, blue: 0.50)
        case .europe: return Color(red: 0.45, green: 0.42, blue: 0.75)
        case .americas: return Color(red: 0.80, green: 0.42, blue: 0.28)
        case .oceania: return Color(red: 0.25, green: 0.55, blue: 0.80)
        case .africa: return Color(red: 0.80, green: 0.58, blue: 0.20)
        case .other: return Color(red: 0.55, green: 0.55, blue: 0.58)
        }
    }

    static func classify(_ code: String) -> BoardRegion {
        switch code.uppercased() {
        case "CN", "HK", "MO", "TW", "JP", "KR", "SG", "IN", "TR", "IL",
             "AE", "PK", "BD", "PH", "VN", "TH", "MY", "ID", "KH", "MM",
             "LK", "NP", "MN", "KZ", "UZ", "GE", "AZ", "AM", "IQ", "IR",
             "SA", "QA", "KW":
            return .asia
        case "GB", "UK", "DE", "FR", "NL", "ES", "PL", "MD", "IT", "CH",
             "SE", "NO", "FI", "DK", "BE", "AT", "IE", "PT", "GR", "CZ",
             "HU", "RO", "UA", "IS", "LU", "BG", "RS", "HR", "SK", "SI",
             "LT", "LV", "EE", "BY":
            return .europe
        case "US", "CA", "MX", "CL", "AR", "BR", "CO", "PE", "EC", "UY", "PA", "CR":
            return .americas
        case "AU", "NZ":
            return .oceania
        case "ZA", "NG", "EG":
            return .africa
        default:
            return .other
        }
    }
}

private struct BoardPalette {
    var scheme: ColorScheme
    var boardTop: Color
    var boardBottom: Color
    var panel: Color
    var panelSelected: Color
    var chip: Color
    var stripe: Color
    var scanline: Color
    var text: Color
    var subtext: Color
    var accent: Color
    var onAccent: Color
    var line: Color
    var flap: Color
    var flapText: Color
    var flapSeam: Color
    var flapEdge: Color
    var shadow: Color

    init(scheme: ColorScheme) {
        self.scheme = scheme
        if scheme == .dark {
            boardTop = Color(red: 0.045, green: 0.055, blue: 0.085)
            boardBottom = Color(red: 0.070, green: 0.085, blue: 0.125)
            panel = Color(red: 0.100, green: 0.120, blue: 0.170)
            panelSelected = Color(red: 0.170, green: 0.150, blue: 0.110)
            chip = Color.white.opacity(0.06)
            stripe = Color.white.opacity(0.045)
            scanline = Color.white.opacity(0.018)
            text = Color(red: 0.93, green: 0.94, blue: 0.96)
            subtext = Color(red: 0.58, green: 0.63, blue: 0.70)
            accent = Color(red: 1.00, green: 0.70, blue: 0.14)
            onAccent = Color(red: 0.13, green: 0.09, blue: 0.02)
            line = Color.white.opacity(0.09)
            shadow = Color.black.opacity(0.35)
        } else {
            boardTop = Color(red: 0.918, green: 0.930, blue: 0.952)
            boardBottom = Color(red: 0.862, green: 0.878, blue: 0.910)
            panel = .white
            panelSelected = Color(red: 1.0, green: 0.950, blue: 0.860)
            chip = Color.black.opacity(0.045)
            stripe = Color.black.opacity(0.035)
            scanline = Color.black.opacity(0.014)
            text = Color(red: 0.10, green: 0.13, blue: 0.19)
            subtext = Color(red: 0.42, green: 0.47, blue: 0.55)
            accent = Color(red: 0.72, green: 0.44, blue: 0.05)
            onAccent = .white
            line = Color.black.opacity(0.09)
            shadow = Color.black.opacity(0.10)
        }
        // 翻牌始终是深色牌面，像真正的出发板。
        flap = Color(red: 0.085, green: 0.095, blue: 0.125)
        flapText = Color(red: 1.00, green: 0.76, blue: 0.28)
        flapSeam = Color.black.opacity(0.55)
        flapEdge = Color.white.opacity(scheme == .dark ? 0.10 : 0.05)
    }

    func statusColor(_ status: NodeTestStatus) -> Color {
        let dark = scheme == .dark
        switch status {
        case .ultraFast:
            return dark ? Color(red: 0.35, green: 0.85, blue: 0.50) : Color(red: 0.08, green: 0.55, blue: 0.30)
        case .fast:
            return dark ? Color(red: 0.40, green: 0.78, blue: 0.42) : Color(red: 0.12, green: 0.50, blue: 0.24)
        case .fairlyFast:
            return dark ? Color(red: 0.62, green: 0.80, blue: 0.35) : Color(red: 0.32, green: 0.48, blue: 0.12)
        case .fairlySlow:
            return dark ? Color(red: 0.95, green: 0.72, blue: 0.25) : Color(red: 0.62, green: 0.42, blue: 0.08)
        case .slow:
            return dark ? Color(red: 0.95, green: 0.55, blue: 0.25) : Color(red: 0.72, green: 0.36, blue: 0.10)
        case .ultraSlow:
            return dark ? Color(red: 0.92, green: 0.42, blue: 0.30) : Color(red: 0.66, green: 0.24, blue: 0.14)
        case .failed, .unavailable:
            return dark ? Color(red: 0.95, green: 0.42, blue: 0.38) : Color(red: 0.70, green: 0.20, blue: 0.16)
        case .testing:
            return accent
        case .untested:
            return subtext
        }
    }
}

private struct BoardBackdrop: View {
    var palette: BoardPalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.boardTop, palette.boardBottom], startPoint: .top, endPoint: .bottom)
            // 细细的横向扫描线，像老式信息板的屏显质感。
            Canvas { context, size in
                var path = Path()
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 4
                }
                context.stroke(path, with: .color(palette.scanline), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// 翻牌显示器里的字符牌：深色牌面 + 中间一道接缝。
private struct SplitFlapCode: View {
    enum Size {
        case regular, large

        var font: CGFloat { self == .large ? 17 : 12 }
        var width: CGFloat { self == .large ? 24 : 17 }
        var height: CGFloat { self == .large ? 32 : 21 }
        var corner: CGFloat { self == .large ? 4 : 3 }
        var gap: CGFloat { self == .large ? 3.5 : 2.5 }
    }

    var code: String
    var palette: BoardPalette
    var size: Size = .regular

    private var letters: [String] {
        code.uppercased().prefix(3).map { String($0) }
    }

    var body: some View {
        HStack(spacing: size.gap) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .font(.system(size: size.font, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.flapText)
                    .frame(width: size.width, height: size.height)
                    .background(palette.flap, in: RoundedRectangle(cornerRadius: size.corner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                            .strokeBorder(palette.flapEdge, lineWidth: 0.6)
                    }
                    .overlay {
                        Rectangle()
                            .fill(palette.flapSeam)
                            .frame(height: 0.8)
                    }
                    .shadow(color: palette.shadow.opacity(0.6), radius: 1.5, y: 1)
            }
        }
    }
}

/// 航线状态灯；测试中 / 连接中时闪烁。
private struct StatusBeacon: View {
    var status: NodeTestStatus
    var palette: BoardPalette
    var pulsing: Bool = false

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(palette.statusColor(status))
            .frame(width: 8, height: 8)
            .shadow(color: palette.statusColor(status).opacity(0.55), radius: 3)
            .opacity(pulsing && dim ? 0.25 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = pulsing }
            .onChange(of: pulsing) { new in dim = new }
    }
}

/// 信息板里的国家行：点击就地展开该国的航线列表。
private struct CountryBoardRow: View {
    @EnvironmentObject private var appState: AppState

    var group: CountryGroup
    var region: BoardRegion
    var palette: BoardPalette
    var compact: Bool
    var striped: Bool
    var isExpanded: Bool
    var isCurrent: Bool
    var isConnectingCountry: Bool
    var nodes: [ProxyNode]
    var queryHidesSome: Bool
    var connectedNodeID: UUID?
    var connectingNodeID: UUID?
    var selectedNodeID: UUID?
    var onSelectNode: (UUID) -> Void
    var isTesting: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if isExpanded {
                expandedArea
                    .transition(.opacity)
            }
        }
        .background(rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isExpanded ? palette.accent.opacity(0.7) : Color.clear, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 1.5)
            }
        }
    }

    private var rowFill: Color {
        if isExpanded { return Color(nsColor: .windowBackgroundColor) }
        return striped ? palette.stripe : Color.clear
    }

    private var mainRow: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                SplitFlapCode(code: group.code, palette: palette)
                    .frame(width: 58, alignment: .leading)

                HStack(spacing: 8) {
                    Text(group.flag)
                        .font(.system(size: 20))
                    Text(group.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !compact {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(region.tint)
                            .frame(width: 6, height: 6)
                        Text(region.title)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.subtext)
                    }
                    .frame(width: 76, alignment: .leading)
                }

                Text("\(group.nodes.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .frame(width: 44, alignment: .trailing)

                if !compact {
                    Text("\(group.availableCount)/\(group.nodes.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(group.availableCount > 0 ? palette.accent : palette.subtext)
                        .frame(width: 56, alignment: .trailing)
                }

                Text(group.bestLatency.map { LatencyFormat.display($0) } ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .frame(width: 64, alignment: .trailing)

                HStack(spacing: 6) {
                    if isCurrent {
                        Text("在航")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    } else if isConnectingCountry {
                        Text("连接中")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.subtext)
                }
                .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(WarmCardHover())
    }

    private var expandedArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    Task { await appState.connectCountry(group.code) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 11, weight: .bold))
                        Text(isConnectingCountry ? "连接中…" : "连接最快航线")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isConnectingCountry || group.nodes.isEmpty)
                .opacity(isConnectingCountry ? 0.6 : 1)
                .help("连接该国延迟最低的可用节点")

                Button {
                    Task { await appState.testNodes(group.nodes) }
                } label: {
                    Text(isTesting ? "测试中…" : "测试全部")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(palette.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(palette.line, lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isTesting || group.nodes.isEmpty)
                .opacity(isTesting || group.nodes.isEmpty ? 0.5 : 1)

                Spacer()

                Text(queryHidesSome ? "只显示匹配的 \(nodes.count) 条航线" : "单击选中 · 双击航线连接")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.subtext)
            }

            if nodes.isEmpty {
                Text(queryHidesSome ? "这个国家里没有匹配的航线" : "这里还没有航线")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.subtext)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        FlightRow(
                            node: node,
                            palette: palette,
                            striped: index % 2 == 1,
                            isCurrent: node.id == connectedNodeID,
                            isConnecting: node.id == connectingNodeID,
                            isSelected: node.id == selectedNodeID,
                            onSelect: { onSelectNode(node.id) },
                            onConnect: { appState.requestConnect(to: node) }
                        )
                        .contextMenu {
                            Button("查看") { appState.viewingNodeID = node.id }
                            Button("连接") { appState.requestConnect(to: node) }
                            Button("测试") {
                                Task { await appState.testNodes([node]) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

private struct FlightRow: View {
    @EnvironmentObject private var appState: AppState
    var node: ProxyNode
    var palette: BoardPalette
    var striped: Bool
    var isCurrent: Bool
    var isConnecting: Bool
    var isSelected: Bool
    var onSelect: () -> Void
    var onConnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusBeacon(
                status: node.resolvedTestStatus,
                palette: palette,
                pulsing: isConnecting || node.resolvedTestStatus == .testing
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(appState.settings.nodeDisplayTitle(node))
                        .font(.system(size: 13, weight: isCurrent || isSelected ? .semibold : .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    ExitMetadataLabels(city: node.exitMetadata?.city,
                                       networkOperator: node.exitMetadata?.networkOperator,
                                       asn: node.exitMetadata?.asn,
                                       countryCode: node.exitMetadata?.countryCode ?? node.countryCode,
                                       localizedCity: node.exitMetadata?.localizedCity)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .padding(.leading, 8)
                    NodeGroupLabel(name: node.groupName(subscriptions: appState.subscriptions))
                    if node.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.accent)
                    }
                    NodeRowLifecycleBadges(node: node, compact: true)
                }
                Text("\(node.protocolType.displayName) · \(node.server):\(node.port, format: .number.grouping(.never)) \(node.exitMetadata?.networkType?.displayName ?? "未知") · 最后可用：\(node.lastAvailableText)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.subtext)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(latencyLabel)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? palette.accent : palette.statusColor(node.resolvedTestStatus))
                    .lineLimit(1)
            }
            .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isCurrent ? palette.accent.opacity(0.8)
                        : (isSelected ? palette.accent.opacity(0.6) : Color.clear),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 1.5)
            }
        }
        .modifier(WarmCardHover(cornerRadius: 7, fill: rowFill))
        .contentShape(Rectangle())
        // 双击手势写在前（内层优先识别）；单击仅选中，双击才连接。
        .onTapGesture(count: 2, perform: onConnect)
        .onTapGesture(perform: onSelect)
    }

    private var rowFill: Color {
        if isCurrent { return palette.panelSelected }
        if isSelected { return palette.accent.opacity(0.18) }
        return striped ? palette.stripe : Color.clear
    }

    private var statusLabel: String {
        if isConnecting { return "连接中" }
        if isCurrent { return "在航" }
        return node.resolvedTestStatus.displayName
    }

    private var latencyLabel: String {
        if isConnecting { return "…" }
        return node.latencyText
    }
}

/// 节点页「机队」主题调色板，深浅色自适应。
/// 内部可见，供同样内部可见的 `NodeRow` 使用。
struct FleetPalette {
    var scheme: ColorScheme
    var bgTop: Color
    var bgBottom: Color
    var deckLine: Color
    var card: Color
    var cardBorder: Color
    var rowSurface: Color
    var stripe: Color
    var text: Color
    var subtext: Color
    var accent: Color
    var onAccent: Color
    var line: Color

    init(scheme: ColorScheme) {
        self.scheme = scheme
        if scheme == .dark {
            bgTop = Color(red: 0.045, green: 0.050, blue: 0.105)
            bgBottom = Color(red: 0.070, green: 0.075, blue: 0.150)
            deckLine = Color.white.opacity(0.035)
            card = Color.white.opacity(0.055)
            cardBorder = Color.white.opacity(0.10)
            rowSurface = Color(red: 0.11, green: 0.12, blue: 0.19)
            stripe = Color.white.opacity(0.035)
            text = Color(red: 0.92, green: 0.93, blue: 0.97)
            subtext = Color(red: 0.60, green: 0.63, blue: 0.71)
            accent = Color(red: 0.55, green: 0.62, blue: 1.0)
            onAccent = Color(red: 0.08, green: 0.09, blue: 0.20)
            line = Color.white.opacity(0.10)
        } else {
            bgTop = Color(red: 0.942, green: 0.948, blue: 0.968)
            bgBottom = Color(red: 0.893, green: 0.903, blue: 0.935)
            deckLine = Color.black.opacity(0.035)
            card = .white
            cardBorder = Color.black.opacity(0.08)
            rowSurface = .white
            stripe = Color.black.opacity(0.028)
            text = Color(red: 0.11, green: 0.13, blue: 0.20)
            subtext = Color(red: 0.43, green: 0.46, blue: 0.54)
            accent = Color(red: 0.28, green: 0.32, blue: 0.78)
            onAccent = .white
            line = Color.black.opacity(0.09)
        }
    }
}

/// 机库甲板背景：渐变 + 跑道斜线。
private struct FleetBackdrop: View {
    var palette: FleetPalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.bgTop, palette.bgBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = -size.height
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    x += 30
                }
                context.stroke(path, with: .color(palette.deckLine), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// 机库分区头：编号牌 + 订阅名 + 节点数。
private struct FleetBayHeader: View {
    var index: Int
    var title: String
    var count: Int
    var palette: FleetPalette

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.subtext)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.bgTop.opacity(0.92))
    }
}

struct NodeListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var sort: NodeSort = .latency
    @State private var selectedIDs: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var confirmDeleteSelection = false
    @State private var confirmRemoveDuplicates = false
    @State private var confirmCleanupNodes = false
    @State private var cleanupResultMessage: String?
    @State private var showCleanupResult = false
    @State private var showingLatencyTierHelp = false
    @State private var highlightedNodeID: UUID?
    @State private var highlightActive = false
    @State private var locationRequestID: UUID?

    /// Restored from settings so leaving/returning to「节点」keeps the last chips.
    /// Scope (status/country) and source (subscription) are independent and can combine.
    /// Source is shared with 测试中心 so switching tabs keeps the same subscription.
    private var scope: NodeListFilter.Scope {
        NodeListFilter.decode(appState.settings.nodeListCategoryRaw).scope
    }

    private var source: NodeListFilter.Source {
        NodeListFilter.decode(appState.settings.nodeListCategoryRaw).source
    }

    private func setScope(_ value: NodeListFilter.Scope) {
        persistFilter(scope: value, source: source)
    }

    private func setSource(_ value: NodeListFilter.Source) {
        persistFilter(scope: scope, source: value)
    }

    private func persistFilter(scope: NodeListFilter.Scope, source: NodeListFilter.Source) {
        let raw = NodeListFilter.encode(scope: scope, source: source)
        guard appState.settings.nodeListCategoryRaw != raw else { return }
        selectedIDs = []
        appState.updateSettingsFromView { $0.nodeListCategoryRaw = raw }
    }

    enum NodeSort: String, CaseIterable {
        case latency, name, country, recent
        var title: String {
            switch self {
            case .latency: return "延迟"
            case .name: return "名称"
            case .country: return "国家"
            case .recent: return "最近可用"
            }
        }
    }

    private var importButtonTitle: String {
        switch source {
        case .all, .manual:
            return "导入链接"
        case .subscription, .namedSource:
            return "添加节点"
        }
    }

    private var palette: FleetPalette { FleetPalette(scheme: colorScheme) }

    private var connectionStatus: ConnectionStatus { appState.connection.state.status }

    var body: some View {
        VStack(spacing: 0) {
            header

            filterDeck

            ScrollViewReader { proxy in
                let showsSections = scope == .all && source == .all && search.isEmpty
                let rows = showsSections ? activeNodes : filtered
                let locationTargetID = appState.focusNodeID.flatMap { id in
                    search.isEmpty && rows.contains(where: { $0.id == id }) ? id : nil
                }
                Group {
                    if rows.isEmpty {
                        emptyNodeList
                    } else {
                        // ForEach already supplies row IDs; adding .id here forces offscreen row construction.
                        List {
                            if showsSections {
                                ForEach(Array(subscriptionSections.enumerated()), id: \.element.id) { bayIndex, section in
                                    Section {
                                        if section.nodes.isEmpty {
                                            Text("暂无节点，请到订阅页更新")
                                                .font(.system(size: 12))
                                                .foregroundStyle(palette.subtext)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                        } else {
                                            ForEach(Array(sorted(section.nodes).enumerated()), id: \.element.id) { offset, node in
                                                nodeRow(
                                                    for: node,
                                                    sequenceNumber: section.startingNumber + offset,
                                                    striped: offset % 2 == 1
                                                )
                                            }
                                        }
                                    } header: {
                                        FleetBayHeader(
                                            index: bayIndex + 1,
                                            title: section.title,
                                            count: section.nodes.count,
                                            palette: palette
                                        )
                                    }
                                }
                            } else {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, node in
                                    nodeRow(for: node, sequenceNumber: offset + 1, striped: offset % 2 == 1)
                                }
                            }
                        }
                        // A fresh table avoids AppKit measuring every inserted row when expanding a filter.
                        .id(appState.settings.nodeListCategoryRaw)
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { FleetBackdrop(palette: palette) }
                .onChange(of: appState.focusNodeID) { id in
                    guard let id else { return }
                    if !rows.contains(where: { $0.id == id }) {
                        persistFilter(scope: .all, source: .all)
                    }
                    selectedIDs = [id]
                    search = ""
                }
                .task(id: locationTargetID) {
                    guard let id = locationTargetID else { return }
                    // Let the filtered table finish registering its rows before scrolling.
                    DispatchQueue.main.async {
                        guard appState.focusNodeID == id else { return }
                        withAnimation(nil) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        highlightActive = false
                        highlightedNodeID = id
                        locationRequestID = UUID()
                        appState.focusNodeID = nil
                    }
                }
                .task(id: locationRequestID) {
                    guard let requestID = locationRequestID else { return }
                    defer {
                        if locationRequestID == requestID {
                            highlightActive = false
                            highlightedNodeID = nil
                        }
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(350))
                        if reduceMotion {
                            highlightActive = true
                            try await Task.sleep(for: .seconds(1.8))
                        } else {
                            for step in 0..<6 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    highlightActive = step.isMultiple(of: 2)
                                }
                                try await Task.sleep(for: .milliseconds(300))
                            }
                        }
                    } catch {
                        // A new location request or leaving the page ends the previous highlight.
                    }
                }
            }
        }
        .onChange(of: appState.preferredNodeCategory) { value in
            guard let value else { return }
            switch value {
            case "all": setScope(.all)
            case "available": setScope(.available)
            case "untested": setScope(.untested)
            case "unavailable": setScope(.unavailable)
            case "failed": setScope(.failed)
            case "favorites": setScope(.favorites)
            default: break
            }
            appState.preferredNodeCategory = nil
        }
        .onAppear {
            if let value = appState.preferredNodeCategory {
                switch value {
                case "all": setScope(.all)
                case "available": setScope(.available)
                case "untested": setScope(.untested)
                case "unavailable": setScope(.unavailable)
                case "failed": setScope(.failed)
                case "favorites": setScope(.favorites)
                default: break
                }
                appState.preferredNodeCategory = nil
            }
        }
        .onChange(of: appState.countryGroups.map(\.code)) { codes in
            if case .country(let code) = scope, !codes.contains(code) {
                setScope(.all)
            }
        }
        .onChange(of: appState.subscriptions.map(\.id)) { ids in
            if case .subscription(let id) = source, !ids.contains(id) {
                setSource(.all)
            }
        }
        .confirmationDialog(
            "删除选中的 \(selectedIDs.count) 个节点？",
            isPresented: $confirmDeleteSelection,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                appState.deleteNodes(selectedIDs)
                selectedIDs = []
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            removeDuplicatesDialogTitle,
            isPresented: $confirmRemoveDuplicates,
            titleVisibility: .visible
        ) {
            Button("删除重复", role: .destructive) {
                let scope = selectedIDs.isEmpty ? Set(visibleNodeIDs) : selectedIDs
                appState.removeDuplicateNodes(among: scope)
                selectedIDs = []
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按协议/服务器/端口/凭证等指纹去重，保留收藏、当前连接与延迟更好的节点。")
        }
        .alert("清除长期不可用节点", isPresented: $confirmCleanupNodes) {
            Button("取消", role: .cancel) {}
            Button("确定清除", role: .destructive) {
                let ids = cleanupSubscriptionIDs
                var results: [String] = []
                var total = 0
                for id in ids {
                    guard let sub = appState.subscription(for: id) else { continue }
                    let before = Set(appState.nodes.filter { $0.subscriptionID == id }.map(\.id))
                    appState.cleanupUnavailableNodes(subscriptionID: id)
                    let remaining = Set(appState.nodes.map(\.id))
                    let removed = before.subtracting(remaining).count
                    total += removed
                    let favorites = appState.protectedCleanupFavoriteCount(subscriptionID: id)
                    results.append("\(sub.name)：清除 \(removed) 个节点，保留 \(favorites) 个达到期限的收藏节点")
                }
                selectedIDs.formIntersection(Set(appState.nodes.map(\.id)))
                cleanupResultMessage = (results + ["合计清除 \(total) 个节点", "收藏节点会一直保留；如需移除，请在节点列表中手动删除。"]).joined(separator: "\n")
                DispatchQueue.main.async { showCleanupResult = true }
            }
        } message: {
            Text(confirmCleanupNodes ? cleanupConfirmationMessage : "")
        }
        .alert("节点清理结果", isPresented: $showCleanupResult) {
            Button("好的", role: .cancel) { cleanupResultMessage = nil }
        } message: {
            Text(cleanupResultMessage ?? "")
        }
    }

    private var cleanupConfirmationMessage: String {
        let groups = cleanupSubscriptionIDs.compactMap { id -> String? in
            guard let sub = appState.subscription(for: id) else { return nil }
            return "\(sub.name)：\(appState.unavailableCleanupCandidates(subscriptionID: id).count) 个节点"
        }.joined(separator: "\n")
        return "将清除以下订阅组中符合期限的长期不可用节点：\n\n\(groups)\n\n共 \(cleanupNodeCount) 个节点。另有 \(protectedCleanupFavoriteCount) 个收藏节点已达到期限，仍会一直保留，除非在节点列表中手动删除。保留订阅、未测试、配置失败及当前连接节点。清理整个订阅组，不受搜索、国家、状态或多选限制。删除后无法撤销，确定继续吗？"
    }

    private var cleanupSubscriptionIDs: [UUID] {
        if case .subscription(let id) = source { return [id] }
        let ids = Set(nodesMatchingSource.compactMap(\.subscriptionID))
        return appState.subscriptions.filter { ids.contains($0.id) }.map(\.id)
    }

    private var protectedCleanupFavoriteCount: Int {
        cleanupSubscriptionIDs.reduce(0) {
            $0 + appState.protectedCleanupFavoriteCount(subscriptionID: $1)
        }
    }

    private var cleanupNodeCount: Int {
        cleanupSubscriptionIDs.reduce(0) {
            $0 + appState.unavailableCleanupCandidates(subscriptionID: $1).count
        }
    }

    private var cleanupNodesButton: some View {
        Button("清除节点") {
            if cleanupNodeCount > 0 {
                confirmCleanupNodes = true
            } else {
                cleanupResultMessage = "当前没有可清理的节点。另有 \(protectedCleanupFavoriteCount) 个收藏节点已达到不可用期限，仍会一直保留；如需移除，请在节点列表中手动删除。更新或测试进行中时请稍后再试。"
                showCleanupResult = true
            }
        }
        .help("按当前订阅范围清理长期不可用节点，保留收藏和当前连接节点")
    }

    // MARK: - 机队页眉：标题 + 读数 + 时钟

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FLEET · 机队")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("节点")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.text)
                        .fixedSize()
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusDot)
                            .frame(width: 8, height: 8)
                        Text("\(nodeCountSummary) · \(connectionStatus.displayName)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(palette.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(palette.cardBorder, lineWidth: 1) }
                    .help("可用：节点延迟测试通过；应用连通：最近一次应用探测至少一个目标通过的节点数")
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.text)
                }
                Button {
                    appState.focusNodeID = connectedNodeID
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.bordered)
                .tint(palette.accent)
                .disabled(connectedNodeID == nil)
                .accessibilityLabel("定位当前已连接节点")
                .help(connectedNodeID == nil ? "当前没有已连接节点" : "定位当前已连接节点")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var statusDot: Color {
        switch connectionStatus {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var connectedNodeID: UUID? {
        guard connectionStatus == .connected,
              let id = appState.connection.state.currentNodeID,
              activeNodes.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    // MARK: - 筛选甲板：订阅 / 状态 / 国家 / 搜索 / 排序

    private var filterDeck: some View {
        VStack(alignment: .leading, spacing: 8) {
            subscriptionFilterBar
            categoryBar
            if isSelectionMode {
                actionControls
                searchAndSortControls
            } else {
                HStack(spacing: 8) {
                    actionControls.fixedSize()
                    searchAndSortControls
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: isSelectionMode) { enabled in
            if !enabled { selectedIDs = [] }
        }
    }

    private var searchAndSortControls: some View {
        HStack(spacing: 8) {
            TextField("搜索节点", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
            Picker("排序", selection: $sort) {
                ForEach(NodeSort.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .frame(width: 120)
        }
    }

    // MARK: - 操作条：选择 / 导入 / 测试

    private var actionControls: some View {
        WrappingFlow(spacing: 8) {
            Toggle("选择", isOn: $isSelectionMode)
                .toggleStyle(.button)
                .tint(palette.accent)
                .controlSize(.small)
                .fixedSize()
                .help("开启后可多选节点做批量操作；单击行只选中不连接，双击行直接连接")

            if isSelectionMode {
                selectionToolbar
            } else {
                Button("删除重复") { confirmRemoveDuplicates = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("按节点指纹去重")
                cleanupNodesButton
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Rectangle().fill(palette.line).frame(width: 1, height: 16)

            Button(importButtonTitle) { appState.showImportLinks = true }
                .buttonStyle(.bordered)
                .controlSize(.small)

            if appState.testManager.isTesting {
                Button("停止") { appState.stopTesting() }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .controlSize(.small)
            } else {
                if appState.testManager.canResume {
                    Button("继续") {
                        Task { await appState.resumeTesting() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(testButtonTitle) {
                    Task { await appState.testNodes(nodesForCurrentTest) }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.small)
                .disabled(!matchingNodes.contains { $0.enabled && !$0.pendingRemoval })
            }
        }
    }

    private var removeDuplicatesDialogTitle: String {
        selectedIDs.isEmpty ? "删除当前列表中的重复节点？" : "删除选中范围内的重复节点？"
    }

    private var selectionToolbar: some View {
        Group {
            Text(selectedIDs.isEmpty ? "未选中" : "已选 \(selectedIDs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, minHeight: 20, alignment: .leading)

            Button("全选") { selectAllVisible() }
            Button("反选") { invertVisibleSelection() }
            Button("删除重复") { confirmRemoveDuplicates = true }
                .help("按节点指纹去重")
            cleanupNodesButton

            Rectangle().fill(palette.line).frame(width: 1, height: 16)

            Button("收藏") {
                appState.setFavorites(selectedIDs, isFavorite: true)
            }
            .disabled(selectedIDs.isEmpty)

            Button("取消收藏") {
                appState.setFavorites(selectedIDs, isFavorite: false)
            }
            .disabled(selectedIDs.isEmpty)

            Button("置顶") {
                appState.pinNodes(selectedIDs)
            }
            .disabled(selectedIDs.isEmpty)

            Button("取消置顶") {
                appState.unpinNodes(selectedIDs)
            }
            .disabled(selectedIDs.isEmpty)

            if appState.testManager.isTesting {
                Button("停止") { appState.stopTesting() }
            } else {
                Button("测试") {
                    let targets = appState.nodes.filter { selectedIDs.contains($0.id) }
                    Task { await appState.testNodes(targets) }
                }
                .disabled(selectedIDs.isEmpty)
            }

            Button("删除", role: .destructive) {
                confirmDeleteSelection = true
            }
            .disabled(selectedIDs.isEmpty)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func nodeRow(for node: ProxyNode, sequenceNumber: Int, striped: Bool = false) -> some View {
        NodeRow(
            node: node,
            sequenceNumber: sequenceNumber,
            isSelected: selectedIDs.contains(node.id),
            isCurrent: isCurrentNode(node),
            isConnecting: isConnectingNode(node),
            isPinned: appState.isPinned(node.id),
            striped: striped,
            palette: palette,
            onToggleSelect: {
                if isSelectionMode {
                    toggleSelection(node.id)
                } else {
                    // 单击只选中，不连接；双击或右键菜单「连接」。
                    selectedIDs = selectedIDs == [node.id] ? [] : [node.id]
                }
            },
            onConnect: {
                appState.requestConnect(to: node)
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.accent, lineWidth: 2)
                .background(palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(highlightedNodeID == node.id && highlightActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            NodeRowContextMenu(items: { nodeMenuItems(for: node) }) {
                if !isSelectionMode { selectedIDs = [node.id] }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func nodeMenuItems(for node: ProxyNode) -> [NodeRowContextMenu.Item] {
        var items: [NodeRowContextMenu.Item] = [
            .action("查看") { appState.viewingNodeID = node.id },
            .action("连接") { appState.requestConnect(to: node) },
            .separator
        ]
        if isSelectionMode {
            items.append(.action(selectedIDs.contains(node.id) ? "取消选中" : "选中") { toggleSelection(node.id) })
        }
        items += [
            .action(node.isFavorite ? "取消收藏" : "收藏") { appState.toggleFavorite(node.id) },
            .action(appState.isPinned(node.id) ? "取消置顶" : "置顶") { appState.togglePin(node.id) },
            .action("测试") { Task { await appState.testNodes([node]) } },
            .separator,
            .action("删除") {
                selectedIDs.remove(node.id)
                appState.deleteNode(node.id)
            }
        ]
        return items
    }

    private func isCurrentNode(_ node: ProxyNode) -> Bool {
        appState.connection.state.status == .connected &&
        appState.connection.state.currentNodeID == node.id
    }

    private func isConnectingNode(_ node: ProxyNode) -> Bool {
        appState.connection.state.status == .connecting &&
        appState.connection.state.currentNodeID == node.id
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func selectAllVisible() {
        selectedIDs = Set(visibleNodeIDs)
    }

    private func invertVisibleSelection() {
        let visible = Set(visibleNodeIDs)
        selectedIDs = visible.subtracting(selectedIDs)
    }

    private var visibleNodeIDs: [UUID] {
        if scope == .all && source == .all && search.isEmpty {
            return subscriptionSections.flatMap { sorted($0.nodes).map(\.id) }
        }
        return filtered.map(\.id)
    }

    private var categoryBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    scopeChip(.all, label: "全部", count: nodesMatchingSource.count)

                    let favorites = nodesMatchingSource.filter(\.isFavorite).count
                    if favorites > 0 {
                        scopeChip(.favorites, label: "收藏", count: favorites)
                    }

                    scopeChip(.available, label: "可用", count: nodesMatchingSource.filter {
                        $0.lastTestStatus.isUsable
                    }.count)

                    Button {
                        showingLatencyTierHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("查看延迟档次阈值")
                    .alert("延迟档次说明", isPresented: $showingLatencyTierHelp) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text(NodeTestStatus.latencyTierHelpMessage)
                    }

                    scopeChip(.untested, label: "未测试", count: nodesMatchingSource.filter {
                        $0.lastTestStatus == .untested
                    }.count)

                    scopeChip(.unavailable, label: "不可用", count: nodesMatchingSource.filter {
                        $0.lastTestStatus == .unavailable
                    }.count)

                    let failedCount = nodesMatchingSource.filter { $0.lastTestStatus == .failed }.count
                    if failedCount > 0 {
                        scopeChip(.failed, label: "失败", count: failedCount)
                    }
                }
            }

            if !scopedCountryGroups.isEmpty {
                countryPicker
            }
        }
    }

    private var subscriptionFilterBar: some View {
        Group {
            if !subscriptionFilterItems.isEmpty || !appState.subscriptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("订阅")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        sourceChip(.all, label: "全部", count: nodesMatchingScope.count)

                        ForEach(subscriptionFilterItems) { item in
                            sourceChip(
                                item.source,
                                label: item.title,
                                count: item.count
                            )
                        }

                        if source != .all {
                            Button {
                                appState.showImportLinks = true
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("向当前选中的订阅添加分享链接")
                        }
                    }
                    .background(SubscriptionGroupDragScroll())
                }
                .help("按住并左右拖动，或使用触控板横向滚动订阅分组")
            }
        }
    }

    private var countryPicker: some View {
        let selected = countryPickerSelection
        return Menu {
            Button {
                clearCountryScope()
            } label: {
                Text(selected == nil ? "✓ 全部国家" : "全部国家")
            }
            Divider()
            ForEach(scopedCountryGroups) { group in
                Button {
                    setScope(.country(group.code))
                } label: {
                    Text(
                        selected == group.code
                            ? "✓ \(group.flag) \(group.name)（\(group.count)）"
                            : "\(group.flag) \(group.name)（\(group.count)）"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(countryPickerTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(selected != nil ? palette.onAccent : palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    selected != nil
                        ? palette.accent
                        : palette.text.opacity(0.07)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    selected != nil ? Color.clear : palette.line,
                    lineWidth: 1
                )
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .help("按国家筛选；下拉中可看到全部国家")
    }

    private var countryPickerSelection: String? {
        if case .country(let code) = scope { return code }
        return nil
    }

    private var countryPickerTitle: String {
        if case .country(let code) = scope,
           let group = scopedCountryGroups.first(where: { $0.code == code }) {
            return "\(group.flag) \(group.name)"
        }
        // Show how many countries are available so it doesn't look "incomplete".
        return "国家（\(scopedCountryGroups.count)）"
    }

    private func clearCountryScope() {
        if case .country = scope {
            setScope(.all)
        }
    }

    private struct ScopedCountryGroup: Identifiable {
        var id: String { code }
        var code: String
        var flag: String
        var name: String
        var count: Int
    }

    /// All countries present under the current subscription filter (complete list for the dropdown).
    private var scopedCountryGroups: [ScopedCountryGroup] {
        CountryResolver.group(nodesMatchingSource).map { group in
            ScopedCountryGroup(
                code: group.code,
                flag: group.flag,
                name: group.name,
                count: group.nodes.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct SubscriptionFilterItem: Identifiable {
        var id: String
        var source: NodeListFilter.Source
        var title: String
        var count: Int
    }

    private var subscriptionFilterItems: [SubscriptionFilterItem] {
        var items: [SubscriptionFilterItem] = []
        let scoped = nodesMatchingScope
        let counts = scoped.reduce(into: [UUID?: Int]()) { $0[$1.subscriptionID, default: 0] += 1 }

        for sub in appState.subscriptions {
            let count = counts[sub.id] ?? 0
            items.append(
                SubscriptionFilterItem(
                    id: sub.id.uuidString,
                    source: .subscription(sub.id),
                    title: sub.name,
                    count: count
                )
            )
        }

        let knownIDs = Set(appState.subscriptions.map(\.id))
        let orphaned = scoped.filter { node in
            guard let sid = node.subscriptionID else { return false }
            return !knownIDs.contains(sid)
        }
        let orphanGroups = Dictionary(grouping: orphaned) { $0.sourceName ?? "未知订阅" }
        for (name, nodes) in orphanGroups.sorted(by: { $0.key < $1.key }) {
            items.append(
                SubscriptionFilterItem(
                    id: "orphan-\(name)",
                    source: .namedSource(name),
                    title: name,
                    count: nodes.count
                )
            )
        }

        let manualCount = counts[nil] ?? 0
        if manualCount > 0 {
            items.append(
                SubscriptionFilterItem(
                    id: "manual",
                    source: .manual,
                    title: "手动导入",
                    count: manualCount
                )
            )
        }

        return items
    }

    private struct SubscriptionSection: Identifiable {
        var id: String
        var title: String
        var nodes: [ProxyNode]
        var startingNumber: Int = 1
    }

    private var subscriptionSections: [SubscriptionSection] {
        let active = activeNodes
        let bySubscription = Dictionary(grouping: active, by: \.subscriptionID)
        var sections: [SubscriptionSection] = []

        for sub in appState.subscriptions {
            let nodes = bySubscription[sub.id] ?? []
            sections.append(SubscriptionSection(id: sub.id.uuidString, title: sub.name, nodes: nodes))
        }

        let knownIDs = Set(appState.subscriptions.map(\.id))
        let orphans = active.filter { node in
            guard let sid = node.subscriptionID else { return false }
            return !knownIDs.contains(sid)
        }
        let orphanGroups = Dictionary(grouping: orphans) { $0.sourceName ?? "未知订阅" }
        for (name, nodes) in orphanGroups.sorted(by: { $0.key < $1.key }) {
            sections.append(SubscriptionSection(id: "orphan-\(name)", title: name, nodes: nodes))
        }

        let manual = bySubscription[nil] ?? []
        if !manual.isEmpty {
            sections.append(SubscriptionSection(id: "manual", title: "手动导入", nodes: manual))
        }

        var nextNumber = 1
        for index in sections.indices {
            sections[index].startingNumber = nextNumber
            nextNumber += sections[index].nodes.count
        }
        return sections
    }

    private var emptyFilterTitle: String {
        if !search.isEmpty { return "没有匹配的节点" }
        switch scope {
        case .all: return "暂无节点"
        case .available: return "暂无可用节点"
        case .untested: return "暂无未测试节点"
        case .unavailable: return "暂无不可用节点"
        case .failed: return "暂无失败节点"
        case .favorites: return "暂无收藏节点"
        case .country: return "暂无该国家的节点"
        }
    }

    private var emptyFilterSourceName: String? {
        switch source {
        case .all: return nil
        case .subscription(let id):
            return appState.subscriptions.first(where: { $0.id == id })?.name ?? "该订阅"
        case .manual: return "手动导入"
        case .namedSource(let name): return name
        }
    }

    private var emptyFilterDescription: String {
        if !search.isEmpty {
            return "当前筛选范围内没有匹配结果，请调整关键词或清除搜索。"
        }
        if scope != .all {
            return "当前筛选范围内没有此类节点，可切换到「全部」查看其他节点。"
        }
        if case .subscription = source {
            return "此分组暂时没有节点，可添加节点或前往订阅页更新订阅。"
        }
        return "导入节点链接，或到订阅页添加并更新订阅。"
    }

    private func scopeChip(_ value: NodeListFilter.Scope, label: String, count: Int) -> some View {
        filterChip(selected: scope == value, label: label, count: count) {
            setScope(value)
        }
    }

    private func sourceChip(_ value: NodeListFilter.Source, label: String, count: Int) -> some View {
        filterChip(selected: source == value, label: label, count: count) {
            setSource(value)
        }
    }

    private func filterChip(selected: Bool, label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .opacity(0.7)
            }
            .font(.subheadline)
            .foregroundStyle(selected ? palette.onAccent : palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? palette.accent : palette.text.opacity(0.07))
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.clear : palette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var activeNodes: [ProxyNode] {
        let connectedID = appState.connection.state.currentNodeID
        return appState.nodes.filter { node in
            !node.pendingRemoval || node.id == connectedID
        }
    }

    private func subscriptionName(for node: ProxyNode) -> String {
        node.groupName(subscriptions: appState.subscriptions)
    }

    /// Nodes matching only the subscription row (for status chip counts).
    private var nodesMatchingSource: [ProxyNode] {
        filterBySource(activeNodes, source: source)
    }

    /// Nodes matching only the status row (for subscription chip counts).
    private var nodesMatchingScope: [ProxyNode] {
        filterByScope(activeNodes, scope: scope)
    }

    private var categorizedNodes: [ProxyNode] {
        filterByScope(filterBySource(activeNodes, source: source), scope: scope)
    }

    private func filterBySource(_ nodes: [ProxyNode], source: NodeListFilter.Source) -> [ProxyNode] {
        switch source {
        case .all:
            return nodes
        case .subscription(let id):
            return nodes.filter { $0.subscriptionID == id }
        case .manual:
            return nodes.filter { $0.subscriptionID == nil }
        case .namedSource(let name):
            let knownIDs = Set(appState.subscriptions.map(\.id))
            return nodes.filter { node in
                guard let sid = node.subscriptionID, !knownIDs.contains(sid) else { return false }
                return (node.sourceName ?? "未知订阅") == name
            }
        }
    }

    private func filterByScope(_ nodes: [ProxyNode], scope: NodeListFilter.Scope) -> [ProxyNode] {
        switch scope {
        case .all:
            return nodes
        case .favorites:
            return nodes.filter(\.isFavorite)
        case .available:
            return nodes.filter { $0.lastTestStatus.isUsable }
        case .untested:
            return nodes.filter { $0.lastTestStatus == .untested }
        case .unavailable:
            return nodes.filter { $0.lastTestStatus == .unavailable }
        case .failed:
            return nodes.filter { $0.lastTestStatus == .failed }
        case .country(let code):
            return nodes.filter {
                CountryResolver.effectiveCode(for: $0) == code.uppercased()
            }
        }
    }

    private var nodeCountSummary: String {
        let list = scope == .all && source == .all && search.isEmpty ? activeNodes : categorizedNodes
        let available = list.filter { $0.lastTestStatus.isUsable }.count
        let appConnected = list.filter(\.hasAppProbeSuccess).count
        return "可用 \(available) · 应用连通 \(appConnected)"
    }

    /// Nodes covered by the current filter (and search), used for scoped testing.
    private var nodesForCurrentTest: [ProxyNode] {
        filtered.filter { $0.enabled && !$0.pendingRemoval }
    }

    private var testButtonTitle: String {
        let rerun = appState.testManager.canResume || appState.testManager.phase == .finished
        let sourceLabel: String? = {
            switch source {
            case .all: return nil
            case .subscription(let id):
                return appState.subscriptions.first(where: { $0.id == id })?.name ?? "当前订阅"
            case .manual: return "手动"
            case .namedSource(let name): return name
            }
        }()
        let scopeLabel: String? = {
            switch scope {
            case .all: return nil
            case .favorites: return "收藏"
            case .available: return "可用"
            case .untested: return "未测"
            case .unavailable: return "不可用"
            case .failed: return "失败"
            case .country(let code):
                return appState.countryGroups.first(where: { $0.code == code })?.name ?? code
            }
        }()

        let target: String = {
            switch (sourceLabel, scopeLabel) {
            case (nil, nil): return "全部"
            case (let s?, nil): return s
            case (nil, let sc?): return sc
            case (let s?, let sc?): return "\(s)·\(sc)"
            }
        }()

        return rerun ? "重新测试 \(target)" : "测试 \(target)"
    }

    private func sorted(_ list: [ProxyNode]) -> [ProxyNode] {
        list.sorted { lhs, rhs in
            let leftPinned = appState.isPinned(lhs.id)
            let rightPinned = appState.isPinned(rhs.id)
            if leftPinned != rightPinned { return leftPinned && !rightPinned }

            switch sort {
            case .latency:
                // 可用各档 → 测试中 → 未测试 → 不可用但有 TCP → 完全不可用；组内再按档次/延迟升序。
                let leftBucket = latencySortBucket(lhs)
                let rightBucket = latencySortBucket(rhs)
                if leftBucket != rightBucket { return leftBucket < rightBucket }
                if leftBucket == 0 {
                    let leftRank = lhs.resolvedTestStatus.sortRank
                    let rightRank = rhs.resolvedTestStatus.sortRank
                    if leftRank != rightRank { return leftRank < rightRank }
                }
                return (lhs.lastLatency ?? Int.max) < (rhs.lastLatency ?? Int.max)
            case .name:
                return appState.settings.nodeDisplayTitle(lhs).localizedStandardCompare(appState.settings.nodeDisplayTitle(rhs)) == .orderedAscending
            case .country:
                return (lhs.countryName ?? "") < (rhs.countryName ?? "")
            case .recent:
                let leftBucket = latencySortBucket(lhs)
                let rightBucket = latencySortBucket(rhs)
                if leftBucket != rightBucket { return leftBucket < rightBucket }
                return (lhs.lastTestDate ?? .distantPast) > (rhs.lastTestDate ?? .distantPast)
            }
        }
    }

    /// 0 = 可用各档, 1 = 测试中, 2 = 未测试, 3 = 失败, 4 = 不可用但有 TCP, 5 = 完全不可用.
    private func latencySortBucket(_ node: ProxyNode) -> Int {
        switch node.lastTestStatus {
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
            return 0
        case .testing:
            return 1
        case .untested:
            return 2
        case .failed:
            return 3
        case .unavailable:
            return node.lastLatency != nil ? 4 : 5
        }
    }

    private var matchingNodes: [ProxyNode] {
        var list = categorizedNodes
        if !search.isEmpty {
            list = list.filter {
                appState.settings.nodeDisplayTitle($0).localizedCaseInsensitiveContains(search) ||
                $0.name.localizedCaseInsensitiveContains(search) ||
                ($0.countryName?.localizedCaseInsensitiveContains(search) ?? false) ||
                $0.server.localizedCaseInsensitiveContains(search) ||
                subscriptionName(for: $0).localizedCaseInsensitiveContains(search)
            }
        }
        return list
    }

    private var filtered: [ProxyNode] { sorted(matchingNodes) }

    private var emptyNodeList: some View {
        UnavailablePlaceholder(
            emptyFilterTitle,
            systemImage: search.isEmpty ? "tray" : "magnifyingglass",
            description: {
                VStack(spacing: 8) {
                    if let name = emptyFilterSourceName {
                        Text("当前分组：\(name)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(palette.text)
                    }
                    Text(emptyFilterDescription)
                        .foregroundStyle(palette.subtext)
                }
            },
            actions: {
                if !search.isEmpty {
                    Button("清除搜索") { search = "" }
                } else if scope != .all {
                    Button("查看全部节点") { setScope(.all) }
                } else if source != .all {
                    Button("查看全部分组") { setSource(.all) }
                }
                Button(importButtonTitle) { appState.showImportLinks = true }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
            }
        )
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct SubscriptionGroupDragScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAnchor { DragAnchor() }
    func updateNSView(_ nsView: DragAnchor, context: Context) {}

    static func dismantleNSView(_ nsView: DragAnchor, coordinator: ()) {
        nsView.detach()
    }

    final class DragAnchor: NSView, NSGestureRecognizerDelegate {
        private weak var scrollView: NSScrollView?
        private var startX: CGFloat = 0
        private lazy var pan: NSPanGestureRecognizer = {
            let gesture = NSPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            // Delay chip clicks until we know this press is not a drag.
            gesture.delaysPrimaryMouseButtonEvents = true
            gesture.delegate = self
            return gesture
        }()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let enclosingScrollView, enclosingScrollView !== scrollView else { return }
            detach()
            scrollView = enclosingScrollView
            enclosingScrollView.addGestureRecognizer(pan)
        }

        func detach() {
            scrollView?.removeGestureRecognizer(pan)
            scrollView = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let scrollView, let document = scrollView.documentView else { return false }
            return document.bounds.width > scrollView.contentView.bounds.width
        }

        @objc private func dragged(_ gesture: NSPanGestureRecognizer) {
            guard let scrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            if gesture.state == .began { startX = clip.bounds.minX }
            guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
            let maximum = max(document.bounds.minX, document.bounds.maxX - clip.bounds.width)
            let x = min(maximum, max(document.bounds.minX, startX - gesture.translation(in: scrollView).x))
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

struct NodeGroupLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.06), in: Capsule())
            .frame(maxWidth: 180, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .help("所属组：\(name)")
            .accessibilityLabel("所属组：\(name)")
    }
}

// A SwiftUI List row contextMenu adds a rectangular system outline outside the card.
private struct NodeRowContextMenu: NSViewRepresentable {
    enum Item {
        case action(String, () -> Void)
        case separator
    }

    let items: () -> [Item]
    var onOpen: () -> Void

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton()
        button.isTransparent = true
        button.isBordered = false
        button.title = ""
        button.target = button
        button.action = #selector(MenuButton.showMenu)
        button.setAccessibilityLabel("节点操作菜单")
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        button.items = items
        button.onOpen = onOpen
    }

    final class MenuButton: NSButton {
        var items: () -> [Item] = { [] }
        var onOpen: () -> Void = {}

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            onOpen()
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }

        @objc func showMenu() {
            onOpen()
            makeMenu().popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            for entry in items() {
                switch entry {
                case .separator: menu.addItem(.separator())
                case let .action(title, handler):
                    let action = MenuAction(handler)
                    let item = NSMenuItem(title: title, action: #selector(MenuAction.invokeMenuAction), keyEquivalent: "")
                    item.target = action
                    item.representedObject = action
                    menu.addItem(item)
                }
            }
            return menu
        }
    }

    private final class MenuAction: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func invokeMenuAction() { handler() }
    }
}

struct NodeRow: View {
    @EnvironmentObject private var appState: AppState
    let node: ProxyNode
    var sequenceNumber: Int? = nil
    var isSelected: Bool = false
    var isCurrent: Bool = false
    var isConnecting: Bool = false
    var isPinned: Bool = false
    var striped: Bool = false
    var palette: FleetPalette = FleetPalette(scheme: .light)
    /// 节点列表：单击整行只切换选中，不连接。
    var onToggleSelect: (() -> Void)? = nil
    /// 双击整行直接连接（等价于右键菜单「连接」）。
    var onConnect: (() -> Void)? = nil
    /// 国家列表等：单击连接。
    var action: (() -> Void)? = nil

    init(
        node: ProxyNode,
        sequenceNumber: Int? = nil,
        isSelected: Bool = false,
        isCurrent: Bool = false,
        isConnecting: Bool = false,
        isPinned: Bool = false,
        striped: Bool = false,
        palette: FleetPalette = FleetPalette(scheme: .light),
        onToggleSelect: (() -> Void)? = nil,
        onConnect: (() -> Void)? = nil,
        action: (() -> Void)? = nil
    ) {
        self.node = node
        self.sequenceNumber = sequenceNumber
        self.isSelected = isSelected
        self.isCurrent = isCurrent
        self.isConnecting = isConnecting
        self.isPinned = isPinned
        self.striped = striped
        self.palette = palette
        self.onToggleSelect = onToggleSelect
        self.onConnect = onConnect
        self.action = action
    }

    /// 兼容 `NodeRow(node:) { ... }` 写法。
    init(
        node: ProxyNode,
        isCurrent: Bool = false,
        isConnecting: Bool = false,
        action: @escaping () -> Void
    ) {
        self.node = node
        self.isCurrent = isCurrent
        self.isConnecting = isConnecting
        self.action = action
    }

    var body: some View {
        HStack(spacing: 0) {
            connectionRail
            if let sequenceNumber {
                sequenceLabel(sequenceNumber)
            }
            mainRowContent
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: 1)
        }
        .modifier(WarmCardHover(fill: rowFill, baseFill: palette.rowSurface))
        .shadow(color: .black.opacity(palette.scheme == .dark ? 0.16 : 0.06), radius: 3, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onConnect?()
        }
        .onTapGesture {
            if let onToggleSelect {
                onToggleSelect()
            } else {
                action?()
            }
        }
    }

    private var rowFill: Color {
        if isCurrent { return Color.green.opacity(palette.scheme == .dark ? 0.16 : 0.10) }
        if isSelected { return palette.accent.opacity(palette.scheme == .dark ? 0.22 : 0.13) }
        if isConnecting { return Color.orange.opacity(palette.scheme == .dark ? 0.14 : 0.08) }
        return striped ? palette.stripe : Color.clear
    }

    private var rowBorder: Color {
        if isCurrent { return Color.green.opacity(0.55) }
        if isSelected { return palette.accent.opacity(0.6) }
        if isConnecting { return Color.orange.opacity(0.55) }
        return palette.text.opacity(0.16)
    }

    private var connectionRail: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(isCurrent ? Color.green : (isConnecting ? Color.orange : Color.clear))
            .frame(width: 3)
            .padding(.vertical, 2)
            .padding(.trailing, 8)
    }

    private func sequenceLabel(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.subtext)
            .fixedSize()
            .padding(.trailing, 6)
    }

    private var mainRowContent: some View {
        HStack(spacing: 8) {
            Text(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node)))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                titleRow
                Text("\(subtitle) · 最后可用：\(node.lastAvailableText)")
                    .font(.caption)
                    .foregroundStyle(palette.subtext)
                    .lineLimit(1)
            }
            Spacer()
            trailingStatusColumn
        }
    }

    private var titleRow: some View {
        let displayedCity = ExitMetadataLocalization.city(
            node.exitMetadata?.city,
            countryCode: node.exitMetadata?.countryCode ?? node.countryCode,
            localizedCity: node.exitMetadata?.localizedCity,
            showChinese: appState.settings.showChineseNodeMetadata
        )
        return HStack(spacing: 4) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
            }
            if let countryName = appState.settings.nodeCountryLabel(node, displayedCity: displayedCity) {
                Text(countryName)
                    .font(.caption)
                    .foregroundStyle(palette.subtext)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 4)
                    .help("国家/地区：\(countryName)")
                    .accessibilityLabel("国家/地区：\(countryName)")
            }
            Text(appState.settings.nodeDisplayTitle(node))
                .font(.body.weight(titleFontWeight))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .help(appState.settings.nodeDisplayTitle(node))
            ExitMetadataLabels(city: node.exitMetadata?.city,
                               networkOperator: node.exitMetadata?.networkOperator,
                               asn: node.exitMetadata?.asn,
                               countryCode: node.exitMetadata?.countryCode ?? node.countryCode,
                               localizedCity: node.exitMetadata?.localizedCity)
                .font(.caption)
                .foregroundStyle(palette.subtext)
                .padding(.leading, 8)
            NodeGroupLabel(name: node.groupName(subscriptions: appState.subscriptions))
            if node.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            nodeLifecycleBadges
        }
    }

    private var titleFontWeight: Font.Weight {
        isSelected || isCurrent || isConnecting ? .semibold : .medium
    }

    @ViewBuilder
    private var nodeLifecycleBadges: some View {
        NodeRowLifecycleBadges(node: node)
    }

    @ViewBuilder
    private var trailingStatusColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isConnecting {
                Label("连接中", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if isCurrent {
                HStack(spacing: 4) {
                    Label("已连接", systemImage: "bolt.horizontal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    if node.latencyText != "—" {
                        Text(node.latencyText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(palette.subtext)
                    }
                }
            } else {
                Label(node.resolvedTestStatus.displayName, systemImage: node.resolvedTestStatus.symbolName)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(node.latencyText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.subtext)
            }
        }
    }

    private var subtitle: String {
        "\(node.protocolType.displayName) · \(node.server):\(node.port) \(node.exitMetadata?.networkType?.displayName ?? "未知")"
    }

    private var statusColor: Color {
        switch node.resolvedTestStatus {
        case .ultraFast: return Color(red: 0.05, green: 0.65, blue: 0.35)
        case .fast: return .green
        case .fairlyFast: return Color(red: 0.45, green: 0.75, blue: 0.2)
        case .fairlySlow: return .orange
        case .slow: return Color(red: 0.95, green: 0.45, blue: 0.1)
        case .ultraSlow: return Color(red: 0.85, green: 0.25, blue: 0.15)
        case .failed: return Color(red: 0.75, green: 0.2, blue: 0.15)
        case .unavailable: return .red
        case .testing: return .blue
        case .untested: return .secondary
        }
    }
}

// MARK: - Node lifecycle chips (subscription merge / deferred removal)

private struct NodeRowLifecycleBadges: View {
    let node: ProxyNode
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            if node.pendingConfigUpdate {
                lifecycleBadge("待应用", icon: "arrow.triangle.2.circlepath", tint: .orange)
            }
            if node.pendingRemoval {
                lifecycleBadge("待移除", icon: "clock.arrow.circlepath", tint: .secondary)
            }
        }
    }

    private func lifecycleBadge(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(compact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(tint.opacity(0.12), in: Capsule())
            .help(lifecycleHelp(title))
    }

    private func lifecycleHelp(_ title: String) -> String {
        switch title {
        case "待应用":
            return "订阅已更新连接参数；当前连接仍用旧配置，可立即应用或下次连接生效"
        case "待移除":
            return "订阅中已不存在；断开连接后将从列表删除（连接中仍会保留）"
        default:
            return title
        }
    }
}
