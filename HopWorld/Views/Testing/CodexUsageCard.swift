import SwiftUI
import AppKit
import Darwin

struct CodexUsageSnapshot: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
        var remaining: Double { min(100, max(0, 100 - usedPercent)) }
    }
    struct Credits: Decodable, Sendable {
        let balance: String?
        let unlimited: Bool
    }
    struct Bucket: Decodable, Sendable {
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }
    struct Resets: Decodable, Sendable { let availableCount: Int }
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    let rateLimitResetCredits: Resets?
    var bucket: Bucket? {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty { return buckets["codex"] }
        return rateLimits
    }
    func window(minutes: Int) -> Window? {
        [bucket?.primary, bucket?.secondary].compactMap { $0 }.first { $0.windowDurationMins == minutes }
    }
    var reserveBucket: Bucket? { rateLimitsByLimitId?["base_model_inference"] }
    var reserveWindow: Window? { reserveBucket?.primary ?? reserveBucket?.secondary }
    var creditLabel: String {
        guard let credits = bucket?.credits else { return "未获取" }
        return credits.unlimited ? "不限额" : (credits.balance ?? "未获取")
    }
}

/// Uses the local Codex login via the supported read-only app-server RPC.
/// Never reads or copies authentication tokens into HopWorld.
enum CodexUsageReader {
    enum ReadError: LocalizedError {
        case missing, unavailable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "未找到 Codex，安装并登录后刷新。"
            case .unavailable: return "无法读取用量，请确认 Codex 已登录后重试。"
            case .failed: return "用量刷新失败，请稍后重试。"
            }
        }
        var diagnostic: String {
            switch self {
            case .missing: return "未找到可执行的 Codex CLI"
            case .unavailable: return "读取失败，未返回有效用量响应"
            case .failed(let detail): return detail
            }
        }
    }
    static func safeDetail(_ detail: String) -> String {
        var result = detail
        for pattern in [#"(?i)Bearer\s+\S+"#, #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?"#,
                        #"(?i)(?:access[_-]?token|refresh[_-]?token|authorization|cookie|password|api[_-]?key)\s*[:=]\s*[^\s,;]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[已隐藏]")
            }
        }
        return String(result.prefix(1200))
    }
    static func read(executablePath: String? = nil, timeoutInterval: TimeInterval = 20) throws -> CodexUsageSnapshot {
        let candidates = executablePath.map { [$0] } ?? [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ReadError.missing
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let startedAt = Date()
        var stage = "启动 app-server"
        do {
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutInterval
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        stage = "initialize"
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "hopworld_usage", "title": "HopWorld Usage", "version": "1.0"]]])
        var buffer = Data()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ReadError.failed("达到 \(timeoutInterval) 秒读取超时，未收到完整 RPC 响应") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 200).rounded(.up)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw ReadError.failed("等待输出失败 errno=\(errno)")
            }
            guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                throw ReadError.failed("输出管道异常 revents=\(descriptor.revents)")
            }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError.failed("读取输出失败 errno=\(errno)")
            }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 4_000_000 else { throw ReadError.failed("响应缓冲区超过 4 MB") }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if let error = message["error"] as? [String: Any] {
                    let code = (error["code"] as? Int).map(String.init) ?? "未知"
                    let reason = safeDetail(error["message"] as? String ?? "无错误说明")
                    throw ReadError.failed("RPC code=\(code), message=\(reason)")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    stage = "account/rateLimits/read"
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] {
                    stage = "解析用量响应"
                    return try JSONDecoder().decode(CodexUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
                }
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let exit = process.isRunning ? "仍在运行，输出流已结束" : "exit=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)"
        throw ReadError.failed("\(elapsed >= 20 ? "达到 20 秒读取超时" : "未收到完整响应")，\(exit)")
        } catch {
            let detail: String
            if let readError = error as? ReadError { detail = readError.diagnostic }
            else if let decoding = error as? DecodingError {
                switch decoding {
                case .keyNotFound(let key, let context): detail = "缺少字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")).\(key.stringValue)"
                case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                    detail = "字段解析失败：\(context.codingPath.map(\.stringValue).joined(separator: "."))"
                @unknown default: detail = "未知数据解析错误"
                }
            } else {
                let underlying = error as NSError
                detail = "domain=\(underlying.domain), code=\(underlying.code), message=\(safeDetail(underlying.localizedDescription))"
            }
            throw ReadError.failed("stage=\(stage), elapsed=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s, executable=\(path), \(detail)")
        }
    }
}

@MainActor
final class CodexUsageMonitor: ObservableObject {
    @Published var snapshot: CodexUsageSnapshot?
    @Published var updatedAt: Date?
    @Published var message: String?
    @Published var isRefreshing = false
    private var refreshTimer: Timer?
    private let readSnapshot: @Sendable () throws -> CodexUsageSnapshot

    init(refreshInterval: TimeInterval = 300,
         readSnapshot: @escaping @Sendable () throws -> CodexUsageSnapshot = { try CodexUsageReader.read() }) {
        self.readSnapshot = readSnapshot
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { refreshTimer?.invalidate() }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let read = readSnapshot
            snapshot = try await Task.detached(priority: .utility) { try read() }.value
            updatedAt = Date()
            message = nil
        } catch {
            let detail = (error as? CodexUsageReader.ReadError)?.diagnostic ?? "\((error as NSError).domain) code=\((error as NSError).code)"
            AppLogger.shared.warning("[Codex 用量] 刷新失败；保留上次数据=\(snapshot != nil)；\(detail)")
            message = (error as? CodexUsageReader.ReadError)?.errorDescription ?? "用量读取失败，请稍后重试。"
        }
    }
}

struct CodexUsageCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var monitor = CodexUsageMonitor()
    @StateObject private var cursorMonitor = CursorUsageMonitor()
    @State private var showDetails = false
    @State private var showSettings = false
    @State private var flipAngle = 0.0
    @State private var isFlipping = false
    @AppStorage("usageCard.cursorFace") private var cursorFace = false
    @AppStorage("usageCard.frontProvider") private var frontProvider = "codex"
    @AppStorage("usageCard.backProvider") private var backProvider = "cursor"
    @AppStorage("usageCard.fiveHour") private var showFiveHour = true
    @AppStorage("usageCard.weekly") private var showWeekly = true
    @AppStorage("usageCard.resets") private var showResets = true
    @AppStorage("usageCard.credits") private var showCredits = true
    @AppStorage("usageCard.reserve") private var showReserve = true
    @AppStorage("usageCard.resetTime") private var showResetTime = true
    @AppStorage("usageCard.progress") private var showProgress = true
    @AppStorage("usageCard.cursorTotal") private var showCursorTotal = true
    @AppStorage("usageCard.cursorModels") private var showCursorModels = true
    @AppStorage("usageCard.cursorOtherModels") private var showCursorOtherModels = true

    private var activeProvider: String { cursorFace ? backProvider : frontProvider }
    private var isCursorFace: Bool { activeProvider == "cursor" }
    private var isCodexFace: Bool { activeProvider == "codex" }
    private var providerName: String { activeProvider == "cursor" ? "Cursor" : activeProvider == "claude" ? "Claude" : "Codex" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("用量设置")
                    .accessibilityLabel("用量设置")
                Button { showDetails = true } label: {
                    Text("用量 · " + providerName)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("查看用量详情")
                Spacer(minLength: 0)
                Button { flipCard() } label: {
                    Flip360Icon()
                }
                .buttonStyle(.borderless)
                .disabled(isFlipping)
                .help(isCursorFace ? "翻转到 Codex 用量" : "翻转到 Cursor 用量")
                .accessibilityLabel(isCursorFace ? "翻转到 Codex 用量" : "翻转到 Cursor 用量")
            }
            if isCursorFace {
                cursorUsageContent
            } else if monitor.snapshot == nil && monitor.message != nil {
                unavailableContent
            } else {
                if showFiveHour { usageRow("5 小时", minutes: 300) }
                if showWeekly { usageRow("每周", minutes: 10_080) }
                if showReserve, let reserve = monitor.snapshot?.reserveWindow {
                    reserveUsageRow(reserve)
                }
                if (showFiveHour || showWeekly || showReserve) && (showResets || showCredits) { Divider() }
                if showResets {
                    valueRow("可用重置", value: monitor.snapshot?.rateLimitResetCredits.map { "\($0.availableCount) 次" } ?? "未获取")
                }
                if showCredits { valueRow("额度", value: monitor.snapshot?.creditLabel ?? "未获取") }
                if !showFiveHour && !showWeekly && !showResets && !showCredits {
                    Text("在用量设置中选择显示内容").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 3) {
                if (isCursorFace ? cursorMonitor.message : monitor.message) != nil {
                    Text("更新失败，请重试。")
                } else if let updated = isCursorFace ? cursorMonitor.updatedAt : monitor.updatedAt {
                    Text("更新于")
                    Text(updated, style: .time)
                } else {
                    Text((isCursorFace ? cursorMonitor.isRefreshing : monitor.isRefreshing) ? "正在读取…" : "尚未更新")
                }
                if isCursorFace ? cursorMonitor.isRefreshing : monitor.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 4)
                Button {
                    let refreshingCursor = isCursorFace
                    Task {
                        if refreshingCursor {
                            guard !cursorMonitor.isRefreshing else { return }
                            appState.flashToast("正在刷新 Cursor 用量…")
                            await cursorMonitor.refresh()
                            appState.flashToast(cursorMonitor.message.map { "刷新失败：" + $0 } ?? "Cursor 用量已更新")
                        } else {
                            guard !monitor.isRefreshing else { return }
                            appState.flashToast("正在刷新 Codex 用量…")
                            await monitor.refresh()
                            appState.flashToast(monitor.message.map { "刷新失败：" + $0 } ?? "Codex 用量已更新")
                        }
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(isCursorFace ? cursorMonitor.isRefreshing : monitor.isRefreshing)
                    .help("刷新用量")
                    .accessibilityLabel(isCursorFace ? "刷新 Cursor 用量" : "刷新 Codex 用量")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)) }
        .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .sheet(isPresented: $showSettings) { settingsView }
        .popover(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 14) {
                Text(providerName + " 用量").font(.headline)
                if isCursorFace {
                    cursorUsageDetails
                    Text("读取本机 Cursor 登录账号，每 5 分钟刷新；刷新失败时保留上次数据。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = cursorMonitor.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    Button("打开 Cursor 用量页面") {
                        openExternal("https://cursor.com/dashboard?tab=usage")
                    }
                } else {
                    usageRow("5 小时使用限额", minutes: 300, detailed: true)
                    usageRow("每周使用限额", minutes: 10_080, detailed: true)
                    Divider()
                    valueRow("可用重置次数", value: monitor.snapshot?.rateLimitResetCredits.map { "\($0.availableCount) 次" } ?? "未获取")
                    valueRow("剩余额度", value: monitor.snapshot?.creditLabel ?? "未获取")
                    Text("读取本机 Codex 登录账号，每 5 分钟刷新。未获取表示尚未取得该字段的数据。刷新失败时保留上次数据，重置时间到达后以刷新结果为准。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = monitor.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    Button("打开 Codex 用量页面") {
                        openExternal("https://chatgpt.com/codex/settings/usage")
                    }
                }
            }
            .padding(20).frame(width: 340)
        }
        .task {
            async let codex: Void = monitor.refresh()
            async let cursor: Void = cursorMonitor.refresh()
            _ = await (codex, cursor)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                async let codex: Void = monitor.refresh()
                async let cursor: Void = cursorMonitor.refresh()
                _ = await (codex, cursor)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task {
                async let codex: Void = monitor.refresh()
                async let cursor: Void = cursorMonitor.refresh()
                _ = await (codex, cursor)
            }
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用量设置").font(.title2.weight(.semibold))
            Form {
                Section("卡片两面应用") {
                    Picker("正面", selection: $frontProvider) {
                        Text("Codex").tag("codex")
                        Text("Cursor").tag("cursor")
                        Text("Claude").tag("claude")
                    }
                    Picker("背面", selection: $backProvider) {
                        Text("Codex").tag("codex")
                        Text("Cursor").tag("cursor")
                        Text("Claude").tag("claude")
                    }
                    Text("点击卡片右下角翻转按钮切换两面。Codex 与 Cursor 支持自动读取，Claude 当前显示接入状态。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Codex 卡片显示内容") {
                    Toggle("5 小时剩余用量", isOn: $showFiveHour)
                    Toggle("每周剩余用量", isOn: $showWeekly)
                    Toggle("Luna Reserve 剩余用量", isOn: $showReserve)
                    Toggle("可用重置次数", isOn: $showResets)
                    Toggle("剩余额度", isOn: $showCredits)
                }
                Section("显示样式") {
                    Toggle("显示用量进度条", isOn: $showProgress)
                    Toggle("显示重置时间", isOn: $showResetTime)
                }
                Section("Cursor 卡片显示内容") {
                    Toggle("综合剩余用量", isOn: $showCursorTotal)
                    Toggle("Cursor 模型剩余用量", isOn: $showCursorModels)
                    Toggle("其他模型剩余用量", isOn: $showCursorOtherModels)
                    Text("自动读取本机 Cursor 登录账号，无需手动填写。每 5 分钟刷新，翻面不影响两侧自动更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("打开 Cursor 用量页面") {
                        openExternal("https://cursor.com/dashboard?tab=usage")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("设置自动保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420, height: 600)
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("未获取", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("重试") {
                    Task {
                        appState.flashToast("正在重试 Codex 用量…")
                        await monitor.refresh()
                        appState.flashToast(monitor.message.map { "读取失败：" + $0 } ?? "Codex 用量已更新")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("打开 Codex") {
                    openExternal("https://chatgpt.com/codex/settings/usage")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var cursorUsageContent: some View {
        if activeProvider == "claude" {
            Text("Claude 用量暂未接入读取")
                .font(.caption2).foregroundStyle(.secondary)
            Text("请在 Claude 用量设置或账单页面查看。")
                .font(.caption2).foregroundStyle(.secondary)
        } else if showCursorTotal { cursorUsageRow("综合剩余", remaining: cursorMonitor.snapshot?.planUsage?.totalRemaining) }
        if showCursorModels { cursorUsageRow("Cursor 模型", remaining: cursorMonitor.snapshot?.planUsage?.cursorModelsRemaining) }
        if showCursorOtherModels { cursorUsageRow("其他模型", remaining: cursorMonitor.snapshot?.planUsage?.otherModelsRemaining) }
        if !showCursorTotal && !showCursorModels && !showCursorOtherModels {
            Text("在用量设置中选择显示内容").font(.caption2).foregroundStyle(.secondary)
        } else if showResetTime, let end = cursorMonitor.snapshot?.billingCycleEnd {
            Text("重置：" + end.formatted(.dateTime.month().day().hour().minute()))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var cursorUsageDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            cursorUsageRow("综合剩余", remaining: cursorMonitor.snapshot?.planUsage?.totalRemaining, detailed: true)
            cursorUsageRow("Cursor 模型", remaining: cursorMonitor.snapshot?.planUsage?.cursorModelsRemaining, detailed: true)
            cursorUsageRow("其他模型", remaining: cursorMonitor.snapshot?.planUsage?.otherModelsRemaining, detailed: true)
            if let end = cursorMonitor.snapshot?.billingCycleEnd {
                Text("周期重置：" + end.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func cursorUsageRow(_ title: String, remaining: Double?, detailed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            valueRow(title, value: remaining.map { String(format: "剩余 %.1f%%", $0) } ?? "未获取")
            if let remaining, showProgress || detailed {
                ProgressView(value: remaining, total: 100).tint(usageColor(remaining))
            }
        }
    }

    private func openExternal(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func flipCard() {
        guard !isFlipping else { return }
        if reduceMotion { cursorFace.toggle(); return }
        isFlipping = true
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.15)) { flipAngle = 90 }
            try? await Task.sleep(for: .milliseconds(150))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { cursorFace.toggle(); flipAngle = -90 }
            withAnimation(.easeOut(duration: 0.15)) { flipAngle = 0 }
            try? await Task.sleep(for: .milliseconds(150))
            isFlipping = false
        }
    }

    private func usageColor(_ remaining: Double) -> Color {
        remaining <= 10 ? .red : remaining <= 25 ? .orange : .accentColor
    }
    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }.font(.caption2)
    }
    private func reserveUsageRow(_ window: CodexUsageSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            valueRow("Luna Reserve", value: "剩余 \(Int(window.remaining.rounded()))%")
            if showProgress { ProgressView(value: window.remaining, total: 100).tint(usageColor(window.remaining)) }
            if showResetTime, let reset = window.resetsAt {
                Text("重置：" + Date(timeIntervalSince1970: reset).formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func usageRow(_ title: String, minutes: Int, detailed: Bool = false) -> some View {
        let window = monitor.snapshot?.window(minutes: minutes)
        return VStack(alignment: .leading, spacing: 3) {
            valueRow(title, value: window.map { "剩余 \(Int($0.remaining.rounded()))%" } ?? "未获取")
            if let window {
                if showProgress || detailed {
                    ProgressView(value: window.remaining, total: 100).tint(usageColor(window.remaining))
                }
                if (showResetTime || detailed), let reset = window.resetsAt {
                    Text("重置：" + Date(timeIntervalSince1970: reset).formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct Flip360Icon: View {
    var body: some View {
        ZStack {
            Ellipse()
                .trim(from: 0.08, to: 0.92)
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 28, height: 14)
                .rotationEffect(.degrees(5))
                .offset(y: 4)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 5.5))
                .offset(x: 9, y: 8)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 12, height: 15)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .stroke(lineWidth: 1.4)
                .frame(width: 12, height: 15)
        }
        .frame(width: 30, height: 22)
        .accessibilityHidden(true)
    }
}
