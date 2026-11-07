import AppKit
import SwiftUI

struct GitHubDownloadSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var mirror: XrayDownloadMirror = XrayInstaller.preferredDownloadMirror
    @State private var folder = GitHubFileDownloader.savedFolder()
    @State private var progress: Double?
    @State private var status = "粘贴 GitHub 文件链接，可改保存位置，包括外置硬盘。"
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("GitHub 下载").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            TextField("https://github.com/.../file", text: $address)
                .textFieldStyle(.roundedBorder)
            Picker("下载线路", selection: $mirror) {
                ForEach(XrayDownloadMirror.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .disabled(task != nil)
            HStack(spacing: 8) {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(folder.path)
                Button("更改…") { pickFolder() }
                    .disabled(task != nil)
            }
            if let progress {
                ProgressView(value: progress)
            }
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button(task == nil ? "下载" : "取消") {
                    if task == nil { start() } else { task?.cancel() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择保存文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        GitHubFileDownloader.remember(folder: url)
    }

    private func start() {
        let official: URL
        do {
            official = try GitHubFileDownloader.canonicalURL(address)
        } catch {
            status = error.localizedDescription
            return
        }
        let selected = mirror
        let directory = folder
        progress = 0
        status = "正在通过\(selected.statusLabel)下载…"
        task = Task {
            defer { task = nil }
            guard await LabUtilityProcess.allowInternet(userInitiated: true) else {
                await MainActor.run {
                    status = appState.offlineNoticeMessage
                    progress = nil
                }
                return
            }
            do {
                let text = try await LabUtilityClient().run(arguments: [
                    "download", official.absoluteString, selected.rawValue, directory.path
                ]) { event in
                    Task { @MainActor in
                        if let fraction = event.p { progress = fraction }
                        if let text = event.u { status = text }
                    }
                }
                await MainActor.run {
                    progress = 1
                    status = text
                }
            } catch is CancellationError {
                await MainActor.run {
                    status = "已取消。未下完的临时文件已删除。再次下载会从头开始，不会接着上次的文件。"
                    progress = nil
                }
            } catch {
                await MainActor.run {
                    progress = nil
                    status = error.localizedDescription
                }
            }
        }
    }
}

struct NetworkToolsSheet: View {
    private enum Page: Equatable {
        case tools, list, detail(SpeedRecord), latencyDetail(LatencyRecord)
    }

    private enum HistoryKind: String, CaseIterable, Identifiable {
        case speed = "测速"
        case latency = "时延"
        var id: String { rawValue }
    }

    private enum ReportRow {
        case pair(String, String)
        case bullet(String)
        case text(String)
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var report = "检测本地链路、系统代理，并可测速、测时延或清理指向本机的残留代理。"
    @State private var busy = false
    @State private var confirmRepair = false
    @State private var repairMessage = ""
    @State private var confirmNetworkRepair = false
    @State private var networkRepairMessage = ""
    @State private var showDNSWhitelist = false
    @State private var job: Task<Void, Never>?
    @State private var speedLine = LocalNetworkSpeedTest.lines[0].id
    @State private var page: Page = .tools
    @State private var records = SpeedHistory.load()
    @State private var latencyRecords = LatencyHistory.load()
    @State private var historyKind: HistoryKind = .speed
    @State private var confirmClear = false
    @State private var speedTesting = false
    @State private var latencyHost = LabUtilityProcess.latencyChoices[0].host
    @State private var latencySeconds = LabUtilityProcess.latencyDurations[0]
    @State private var latencyTesting = false
    @State private var showLatencySetup = false
    @State private var showSpeedSetup = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: LabPalette { LabPalette(scheme: colorScheme) }

    private var connected: Bool {
        appState.connection.state.status == .connected || appState.connection.state.status == .connecting
    }

    private var pageTitle: String {
        switch page {
        case .tools: return "网络工具"
        case .list: return "记录"
        case .detail: return "测速详情"
        case .latencyDetail: return "时延详情"
        }
    }

    var body: some View {
        ZStack {
            LabBackdrop(palette: palette)
            VStack(alignment: .leading, spacing: 14) {
                header
                switch page {
                case .tools:
                    toolsBody
                case .list:
                    historyList
                case .detail(let record):
                    historyDetail(record)
                case .latencyDetail(let record):
                    latencyHistoryDetail(record)
                }
            }
            .padding(24)
        }
        .frame(width: 920, height: 680)
        .confirmationDialog("修复残留代理", isPresented: $confirmRepair, titleVisibility: .visible) {
            Button("保留备份") { run { try await repair("keep") } }
            Button("删除备份", role: .destructive) { run { try await repair("delete") } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(repairMessage)
        }
        .sheet(isPresented: $confirmNetworkRepair) {
            NetworkRepairConfirmSheet(
                message: networkRepairMessage,
                canRestoreHosts: FileManager.default.fileExists(atPath: LabUtilityProcess.hostsBackupPath)
            ) {
                let found = networkRepairMessage
                run {
                    let fixed = try await utility(["network-repair"])
                    return [found, fixed].filter { !$0.isEmpty }.joined(separator: "\n")
                }
            } restore: {
                run { try await utility(["network-repair-restore-hosts"]) }
            }
        }
        .sheet(isPresented: $showDNSWhitelist) {
            DNSWhitelistSheet()
        }
        .sheet(isPresented: $showLatencySetup) {
            LatencySetupSheet(host: $latencyHost, seconds: $latencySeconds) {
                startLatency()
            }
        }
        .sheet(isPresented: $showSpeedSetup) {
            SpeedSetupSheet(lineID: $speedLine) {
                startSpeedTest()
            }
        }
        .confirmationDialog(historyKind == .speed ? "清空测速记录？" : "清空时延记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { clearListedHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除已保存的 \(listedCount) 条\(historyKind.rawValue)记录。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LAB · 网络")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                Text(pageTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(palette.text)
            }
            Spacer()
            if page != .tools {
                Button("返回", action: goBack)
                    .buttonStyle(.bordered)
            }
            if case .list = page, listedCount > 0 {
                Button("清空") { confirmClear = true }
                    .buttonStyle(.bordered)
            }
            Button(action: toggleHistory) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .help(page == .tools ? "记录" : "返回网络工具")
            .accessibilityLabel(page == .tools ? "记录" : "返回网络工具")
            Button("关闭") { job?.cancel(); dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var toolsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                iconButton(
                    speedTesting ? "停止" : "开始测速",
                    speedTesting ? "stop.fill" : "play.fill",
                    prominent: !speedTesting,
                    staysEnabled: speedTesting
                ) {
                    if speedTesting { job?.cancel() } else { showSpeedSetup = true }
                }
                iconButton(
                    latencyTesting ? "停止" : "测试时延",
                    latencyTesting ? "stop.fill" : "timer",
                    staysEnabled: latencyTesting
                ) {
                    if latencyTesting { job?.cancel() } else { showLatencySetup = true }
                }
                Spacer(minLength: 12)
                iconButton("检测", "antenna.radiowaves.left.and.right") {
                    run {
                        guard await LabUtilityProcess.allowInternet(userInitiated: true) else {
                            return [appState.offlineNoticeTitle, appState.offlineNoticeMessage].joined(separator: "\n")
                        }
                        return try await utility(["diagnose", connected ? "connected" : "idle"])
                    }
                }
                iconButton("刷新 DNS", "arrow.clockwise") {
                    run { try await utility(["flush-dns"]) }
                }
                iconButton("白名单", "list.bullet", help: "查看和修改 DNS 白名单。没改过时显示内置公共地址。", action: { showDNSWhitelist = true })
                iconButton("网络修复", "shield.lefthalf.filled", help: "按顺序检查 DNS、hosts、DHCP、MTU、Wi-Fi 和默认路由。有异常才继续修复，全部正常则不改。", action: prepareNetworkRepair)
                iconButton(
                    "修复残留代理",
                    "wrench.and.screwdriver",
                    help: connected ? "已连接或正在连接时不改系统代理" : "关闭指向 127.0.0.1 的系统代理，并选择是否删除备份",
                    action: prepareRepair
                )
                .disabled(connected || busy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            }
            LabCard(title: "结果", icon: "doc.text", tint: palette.accent, palette: palette, footnote: busy ? "进行中" : nil) {
                reportView(report)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func iconButton(
        _ title: String,
        _ icon: String,
        prominent: Bool = false,
        help: String? = nil,
        staysEnabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .help(help ?? title)
        .accessibilityLabel(title)
        .disabled(busy && !staysEnabled)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func speedStatus(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").first {
            !$0.hasPrefix("电波") && !$0.contains("：")
        }
        return line ?? "正在测速…"
    }

    private var statOrder: [String] { ["下载", "上传", "当前带宽", "平均", "最小", "最大"] }

    private func reportView(_ text: String) -> some View {
        let measuring = speedTesting || latencyTesting
        let rows = reportRows(text).filter { row in
            guard measuring, case .text(let line) = row else { return true }
            return line != speedStatus(text)
        }
        let stats = statOrder.compactMap { key in
            rows.compactMap { row -> (String, String)? in
                if case .pair(let name, let value) = row, name == key { return (name, value) }
                return nil
            }.first
        }
        let blocks = reportBlocks(rows)
        let waves = LocalNetworkSpeedTest.parseWaves(text)
        let latencySamples = LabUtilityProcess.latencySamples(in: text)
        let latencySlots = max(LabUtilityProcess.latencyPlannedCount(in: text) ?? 0, latencySamples.count)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if measuring {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(speedStatus(text))
                            .font(.callout)
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if speedTesting || !waves.down.isEmpty || !waves.up.isEmpty {
                    SpeedWaveChart(down: waves.down, up: waves.up, palette: palette)
                }
                if latencySlots > 0, latencyTesting || !latencySamples.isEmpty {
                    LatencyWaveChart(samples: latencySamples, slots: latencySlots, palette: palette)
                }
                if !stats.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(stats, id: \.0) { stat in
                            statTile(stat.0, stat.1)
                                .frame(maxWidth: stats.count >= 3 ? .infinity : 210)
                        }
                        if stats.count < 3 { Spacer(minLength: 0) }
                    }
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .pairs(let pairs):
                        LazyVGrid(
                            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                                pairRow(pair.0, pair.1)
                            }
                        }
                    case .row(let row):
                        reportRow(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private func statTile(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: statIcon(key))
                    .font(.system(size: 12, weight: .semibold))
                Text(key)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(palette.subtext)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.line, lineWidth: 1)
        }
    }

    private func statIcon(_ key: String) -> String {
        switch key {
        case "下载": return "arrow.down"
        case "上传": return "arrow.up"
        case "平均": return "timer"
        case "最小": return "arrow.down.to.line"
        case "最大": return "arrow.up.to.line"
        default: return "gauge.with.dots.needle.67percent"
        }
    }

    private enum ReportBlock {
        case pairs([(String, String)])
        case row(ReportRow)
    }

    private func reportBlocks(_ rows: [ReportRow]) -> [ReportBlock] {
        var blocks: [ReportBlock] = []
        var pairs: [(String, String)] = []
        func flush() {
            if !pairs.isEmpty {
                blocks.append(.pairs(pairs))
                pairs = []
            }
        }
        for row in rows {
            if case .pair(let key, let value) = row {
                if statOrder.contains(key) { continue }
                pairs.append((key, value))
            } else {
                flush()
                blocks.append(.row(row))
            }
        }
        flush()
        return blocks
    }

    @ViewBuilder
    private func reportRow(_ row: ReportRow) -> some View {
        switch row {
        case .pair(let key, let value):
            pairRow(key, value)
        case .bullet(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(palette.subtext)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .text(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pairRow(_ key: String, _ value: String) -> some View {
        let strong = key == "下载" || key == "上传" || key == "当前带宽"
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.callout)
                .foregroundStyle(palette.subtext)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.callout.weight(strong ? .semibold : .regular))
                .foregroundStyle(strong ? palette.accent : palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reportRows(_ text: String) -> [ReportRow] {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("电波") { return nil }
            if trimmed.hasPrefix("·") { return .bullet(trimmed) }
            guard let split = trimmed.firstIndex(of: "："), split != trimmed.startIndex else { return .text(trimmed) }
            let key = String(trimmed[..<split])
            let value = String(trimmed[trimmed.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, key.count <= 12 else { return .text(trimmed) }
            return .pair(key, value)
        }
    }

    private var listedCount: Int {
        historyKind == .speed ? records.count : latencyRecords.count
    }

    private var historyKindPicker: some View {
        Picker("记录类型", selection: $historyKind) {
            ForEach(HistoryKind.allCases) { kind in
                Text(kind.rawValue).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 148)
        .accessibilityLabel("记录类型")
    }

    private var historyList: some View {
        LabCard(
            title: "记录",
            icon: "clock",
            tint: palette.accent,
            palette: palette,
            footnote: listedCount == 0 ? nil : "\(listedCount) 条",
            trailing: AnyView(historyKindPicker)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if listedCount == 0 {
                        Text(historyKind == .speed ? "还没有测速记录。测完一次后会记在这里。" : "还没有时延记录。测完一次后会记在这里。")
                            .font(.callout)
                            .foregroundStyle(palette.subtext)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if historyKind == .speed {
                        speedHistoryRows
                    } else {
                        latencyHistoryRows
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var speedHistoryRows: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    historyColumns(date: "日期", network: "网络", down: "下载", up: "上传", header: true)
                    ForEach(records) { record in
                        Button { page = .detail(record) } label: {
                            historyColumns(
                                date: record.at.formatted(date: .numeric, time: .shortened),
                                network: record.snapshot.network,
                                down: LocalNetworkSpeedTest.speedText(record.snapshot.downloadMbps),
                                up: LocalNetworkSpeedTest.speedText(record.snapshot.uploadMbps),
                                header: false
                            )
                            .padding(10)
                            .background(palette.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(palette.line, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(record.snapshot.network)，下载 \(LocalNetworkSpeedTest.speedText(record.snapshot.downloadMbps))，上传 \(LocalNetworkSpeedTest.speedText(record.snapshot.uploadMbps))")
                        .accessibilityHint("查看测速详情")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private var latencyHistoryRows: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    historyColumns(date: "日期", network: "目标", down: "平均", up: "丢包", header: true)
                    ForEach(latencyRecords) { record in
                        Button { page = .latencyDetail(record) } label: {
                            historyColumns(
                                date: record.at.formatted(date: .numeric, time: .shortened),
                                network: record.snapshot.target,
                                down: latencyAverageText(record.snapshot.averageMs),
                                up: record.snapshot.loss,
                                header: false
                            )
                            .padding(10)
                            .background(palette.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(palette.line, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(record.snapshot.target)，平均 \(latencyAverageText(record.snapshot.averageMs))，丢包 \(record.snapshot.loss)")
                        .accessibilityHint("查看时延详情")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private func latencyAverageText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f ms", value)
    }

    private func historyColumns(date: String, network: String, down: String, up: String, header: Bool) -> some View {
        HStack(spacing: 12) {
            Text(date)
                .foregroundStyle(header ? palette.subtext : palette.subtext)
                .frame(width: 168, alignment: .leading)
            Text(network)
                .foregroundStyle(header ? palette.subtext : palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(down)
                .foregroundStyle(header ? palette.subtext : palette.accent)
                .frame(width: 120, alignment: .trailing)
            Text(up)
                .foregroundStyle(header ? palette.subtext : palette.text)
                .frame(width: 120, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(header ? .clear : palette.subtext)
                .accessibilityHidden(true)
        }
        .font(header ? .caption.weight(.semibold) : .callout.monospacedDigit())
    }

    private func historyDetail(_ record: SpeedRecord) -> some View {
        LabCard(title: record.snapshot.network, icon: "speedometer", tint: palette.accent, palette: palette, subtitle: record.at.formatted(date: .abbreviated, time: .shortened)) {
            reportView(record.snapshot.detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func latencyHistoryDetail(_ record: LatencyRecord) -> some View {
        LabCard(title: record.snapshot.target, icon: "timer", tint: palette.accent, palette: palette, subtitle: record.at.formatted(date: .abbreviated, time: .shortened)) {
            reportView(record.snapshot.detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func toggleHistory() {
        if page == .tools {
            records = SpeedHistory.load()
            latencyRecords = LatencyHistory.load()
            page = .list
        } else {
            page = .tools
        }
    }

    private func clearListedHistory() {
        switch historyKind {
        case .speed:
            SpeedHistory.clear()
            records = []
            if case .detail = page { page = .list }
        case .latency:
            LatencyHistory.clear()
            latencyRecords = []
            if case .latencyDetail = page { page = .list }
        }
    }

    private func goBack() {
        switch page {
        case .detail, .latencyDetail: page = .list
        case .list: page = .tools
        case .tools: break
        }
    }

    private func run(_ work: @escaping () async throws -> String) {
        guard !busy else { return }
        busy = true
        job = Task {
            let text: String
            do {
                text = try await work()
            } catch is CancellationError {
                text = "已取消"
            } catch {
                text = error.localizedDescription
            }
            report = text
            busy = false
            speedTesting = false
            latencyTesting = false
            job = nil
        }
    }

    private func utility(_ arguments: [String], live: Bool = false) async throws -> String {
        try await LabUtilityClient().run(arguments: arguments) { event in
            guard live, let text = event.u else { return }
            Task { @MainActor in report = text }
        }
    }

    private func repair(_ choice: String) async throws -> String {
        guard !connected else { return "当前已连接，未修改系统代理。" }
        return try await utility(["repair", choice])
    }

    private func prepareNetworkRepair() {
        guard !busy else { return }
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            do {
                let text = try await utility(["network-repair-preview"], live: true)
                report = text
                guard LabUtilityProcess.repairNeeded(text) else { return }
                networkRepairMessage = text
                confirmNetworkRepair = true
            } catch is CancellationError {
                report = "已取消"
            } catch {
                report = error.localizedDescription
            }
        }
    }

    private func prepareRepair() {
        guard !connected, !busy else { return }
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            do {
                repairMessage = try await utility(["repair-preview"])
                confirmRepair = true
            } catch is CancellationError {
                report = "已取消"
            } catch {
                report = error.localizedDescription
            }
        }
    }

    private func startSpeedTest() {
        guard !busy else { return }
        speedTesting = true
        report = "正在测速…"
        let line = speedLine
        run {
            guard await LabUtilityProcess.allowInternet(userInitiated: true) else {
                return [appState.offlineNoticeTitle, appState.offlineNoticeMessage].joined(separator: "\n")
            }
            do {
                let text = try await utility(["speed", line], live: true)
                guard let snapshot = SpeedSnapshot.decode(text) else { return text }
                SpeedHistory.append(snapshot)
                return snapshot.detail
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return "测速失败：\(error.localizedDescription)"
            }
        }
    }

    private func rememberLatency(_ text: String) {
        guard let snapshot = LatencySnapshot.make(from: text) else { return }
        LatencyHistory.append(snapshot)
        latencyRecords = LatencyHistory.load()
    }

    private func startLatency() {
        guard !busy else { return }
        latencyTesting = true
        report = "正在测试时延…"
        let host = latencyHost
        let seconds = latencySeconds
        run {
            guard await LabUtilityProcess.allowInternet(userInitiated: true) else {
                return [appState.offlineNoticeTitle, appState.offlineNoticeMessage].joined(separator: "\n")
            }
            do {
                let text = try await utility(["latency", host, String(seconds)], live: true)
                rememberLatency(text)
                return text
            } catch is CancellationError {
                guard report.contains("目标：") else { return "已取消" }
                let stopped = report + "\n已停止"
                rememberLatency(stopped)
                return stopped
            } catch {
                return "时延测试失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct SpeedSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var lineID: String
    var start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("测速").font(.title2.weight(.semibold))
            Picker("线路", selection: $lineID) {
                ForEach(LocalNetworkSpeedTest.lines) { line in
                    Text(line.name).tag(line.id)
                }
            }
            if let note = LocalNetworkSpeedTest.line(id: lineID)?.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始") {
                    dismiss()
                    start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct LatencySetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var host: String
    @Binding var seconds: Int
    var start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("测试时延").font(.title2.weight(.semibold))
            Text("本机 ICMP，每秒 1 个包，不走代理。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("目标", selection: $host) {
                ForEach(LabUtilityProcess.latencyChoices) { choice in
                    Text("\(choice.name)（\(choice.host)）").tag(choice.host)
                }
            }
            Picker("时长", selection: $seconds) {
                ForEach(LabUtilityProcess.latencyDurations, id: \.self) { seconds in
                    Text(Self.durationTitle(seconds)).tag(seconds)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始") {
                    dismiss()
                    start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private static func durationTitle(_ seconds: Int) -> String {
        switch seconds {
        case 60: return "1 分钟"
        case 300: return "5 分钟"
        case 600: return "10 分钟"
        default: return "\(seconds) 秒"
        }
    }
}

private struct NetworkRepairConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    var message: String
    var canRestoreHosts: Bool
    var start: () -> Void
    var restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网络修复").font(.title2.weight(.semibold))
            Text("检查已经完成。确认后才修复上面的异常项，可能要求输入管理员密码。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(message)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                if canRestoreHosts {
                    Button("还原 hosts") {
                        dismiss()
                        restore()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始修复") {
                    dismiss()
                    start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}

private struct DNSDraft: Identifiable, Equatable {
    let id = UUID()
    var address: String
}

private struct DNSWhitelistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drafts = LabUtilityProcess.trustedDNSList().map { DNSDraft(address: $0) }
    @State private var addition = ""
    @State private var editing = false

    private var addresses: [String] { drafts.map(\.address) }
    private var usingBuiltin: Bool { LabUtilityProcess.normalizedTrustedDNS(addresses) == LabUtilityProcess.builtinTrustedDNS }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DNS 白名单").font(.title2.weight(.semibold))
                Spacer()
                if editing {
                    Button("完成", action: finishEditing)
                } else {
                    Button("编辑") { editing = true }
                }
                Button("关闭") { persist(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(usingBuiltin ? "当前是内置白名单。这些地址不会被网络修复改掉。" : "已按你的修改保存。恢复内置可回到默认地址。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                if editing {
                    ForEach($drafts) { $draft in
                        HStack(spacing: 8) {
                            TextField("DNS 地址", text: $draft.address)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                drafts.removeAll { $0.id == draft.id }
                                persist()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("删除")
                        }
                    }
                } else {
                    ForEach(drafts) { draft in
                        Text(draft.address)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            if editing {
                HStack(spacing: 8) {
                    TextField("添加地址", text: $addition)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("添加", action: add)
                        .disabled(!LabUtilityProcess.isDNSAddress(addition))
                }
                HStack {
                    Button("恢复内置") {
                        drafts = LabUtilityProcess.builtinTrustedDNS.map { DNSDraft(address: $0) }
                        persist()
                    }
                    .disabled(usingBuiltin)
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }

    private func finishEditing() {
        persist()
        drafts = LabUtilityProcess.trustedDNSList().map { DNSDraft(address: $0) }
        addition = ""
        editing = false
    }

    private func add() {
        let address = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LabUtilityProcess.isDNSAddress(address), !addresses.contains(address) else { return }
        drafts.append(DNSDraft(address: address))
        addition = ""
        persist()
    }

    private func persist() {
        LabUtilityProcess.saveTrustedDNS(addresses)
    }
}

private struct SpeedWaveChart: View {
    var down: [Double]
    var up: [Double]
    var palette: LabPalette

    private var uploadTint: Color { Color(red: 0.96, green: 0.58, blue: 0.24) }

    var body: some View {
        let peak = max(down.max() ?? 0, up.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                waveLegend("下载", palette.accent)
                waveLegend("上传", uploadTint)
                Spacer()
            }
            Canvas { context, size in
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(baseline, with: .color(palette.line), lineWidth: 1)
                draw(&context, values: down, peak: peak, size: size, color: palette.accent)
                draw(&context, values: up, peak: peak, size: size, color: uploadTint)
            }
            .frame(height: 108)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            HStack(spacing: 0) {
                ForEach(1...Int(LocalNetworkSpeedTest.sampleSeconds), id: \.self) { second in
                    Text("\(second)s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(second <= max(down.count, up.count) ? palette.subtext : palette.subtext.opacity(0.35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var spoken: String {
        func numbers(_ values: [Double]) -> String {
            values.isEmpty ? "无" : values.map { String(format: "%.0f", $0) }.joined(separator: "、")
        }
        return "下载每秒 \(numbers(down.map { $0 / 8 })) MB/s，上传每秒 \(numbers(up.map { $0 / 8 })) MB/s"
    }

    private func waveLegend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 3)
            Text(title).font(.caption).foregroundStyle(palette.subtext)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, values: [Double], peak: Double, size: CGSize, color: Color) {
        guard let first = values.first else { return }
        let slots = CGFloat(LocalNetworkSpeedTest.sampleSeconds)
        func point(_ index: Int, _ value: Double) -> CGPoint {
            CGPoint(
                x: (CGFloat(index) + 0.5) / slots * size.width,
                y: size.height - 8 - CGFloat(value / peak) * (size.height - 16)
            )
        }
        var line = Path()
        line.move(to: point(0, first))
        for index in values.indices.dropFirst() {
            line.addLine(to: point(index, values[index]))
        }
        var fill = line
        let last = point(values.count - 1, values[values.count - 1])
        fill.addLine(to: CGPoint(x: last.x, y: size.height))
        fill.addLine(to: CGPoint(x: point(0, first).x, y: size.height))
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(0.16)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(color))
    }
}

private struct LatencyWaveChart: View {
    var samples: [Double?]
    var slots: Int
    var palette: LabPalette

    private var lossTint: Color { Color(red: 0.96, green: 0.58, blue: 0.24) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                waveLegend("时延", palette.accent)
                if samples.contains(where: { $0 == nil }) {
                    waveLegend("超时", lossTint)
                }
                Spacer()
            }
            Canvas { context, size in
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(baseline, with: .color(palette.line), lineWidth: 1)
                draw(&context, size: size)
            }
            .frame(height: 108)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            GeometryReader { geo in
                ForEach(LabUtilityProcess.latencyAxisSeconds(slots), id: \.self) { second in
                    Text("\(second)s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(second <= samples.count ? palette.subtext : palette.subtext.opacity(0.35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .position(
                            x: (CGFloat(second) - 0.5) / CGFloat(max(slots, 1)) * geo.size.width,
                            y: 8
                        )
                }
            }
            .frame(height: 16)
            .accessibilityHidden(true)
        }
    }

    private var spoken: String {
        let body = samples.map { sample in
            sample.map { String(format: "%.0f", $0) } ?? "超时"
        }.joined(separator: "、")
        return samples.isEmpty ? "还没有时延" : "每秒时延 \(body) 毫秒"
    }

    private func waveLegend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 3)
            Text(title).font(.caption).foregroundStyle(palette.subtext)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let peak = max(samples.compactMap { $0 }.max() ?? 0, 1)
        let width = CGFloat(max(slots, 1))
        func point(_ index: Int, _ value: Double) -> CGPoint {
            CGPoint(
                x: (CGFloat(index) + 0.5) / width * size.width,
                y: size.height - 8 - CGFloat(value / peak) * (size.height - 16)
            )
        }
        var segment: [CGPoint] = []
        func flush() {
            guard let first = segment.first, let last = segment.last else { return }
            var line = Path()
            line.move(to: first)
            for item in segment.dropFirst() { line.addLine(to: item) }
            var fill = line
            fill.addLine(to: CGPoint(x: last.x, y: size.height))
            fill.addLine(to: CGPoint(x: first.x, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(palette.accent.opacity(0.16)))
            context.stroke(line, with: .color(palette.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for item in segment {
                context.fill(Path(ellipseIn: CGRect(x: item.x - 2.5, y: item.y - 2.5, width: 5, height: 5)), with: .color(palette.accent))
            }
            segment = []
        }
        for (index, sample) in samples.enumerated() {
            if let sample {
                segment.append(point(index, sample))
            } else {
                flush()
                let x = (CGFloat(index) + 0.5) / width * size.width
                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: size.height - 6, width: 5, height: 5)), with: .color(lossTint))
            }
        }
        flush()
    }
}
