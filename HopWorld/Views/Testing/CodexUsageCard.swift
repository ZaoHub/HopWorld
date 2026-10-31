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
    struct Resets: Decodable, Sendable {
        struct Credit: Decodable, Sendable {
            let status: String?
            let expiresAt: Double?
        }
        let availableCount: Int
        let credits: [Credit]?
        var expirationSuffix: String {
            guard availableCount > 0,
                  let expiration = credits?.filter({ $0.status == nil || $0.status == "available" })
                    .compactMap(\.expiresAt).filter({ $0.isFinite && $0 > Date().timeIntervalSince1970 }).min() else {
                return ""
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "M月d日 HH:mm"
            return " " + formatter.string(from: Date(timeIntervalSince1970: expiration))
        }
    }
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    let rateLimitResetCredits: Resets?
    var accountID: String?
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
    var hasZeroCreditBalance: Bool {
        guard let credits = bucket?.credits, !credits.unlimited,
              let balance = credits.balance,
              let value = Double(balance), value.isFinite else { return false }
        return value == 0
    }
}

/// Uses the local Codex login via the supported read-only app-server RPC.
/// Never reads or copies authentication tokens into HopWorld.
enum CodexUsageReader {
    enum ReadError: LocalizedError {
        case missing, unavailable
        case notLoggedIn, unsupportedAccount
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "未找到 Codex，安装并登录后刷新。"
            case .unavailable: return "无法读取用量，请确认 Codex 已登录后重试。"
            case .failed: return "用量刷新失败，请稍后重试。"
            case .notLoggedIn: return "Codex 未登录，请先登录 ChatGPT 账号。"
            case .unsupportedAccount: return "当前登录方式不支持订阅用量，请使用 ChatGPT 账号登录 Codex。"
            }
        }
        var diagnostic: String {
            switch self {
            case .missing: return "未找到可执行的 Codex CLI"
            case .unavailable: return "读取失败，未返回有效用量响应"
            case .failed(let detail): return detail
            case .notLoggedIn: return "stage=account/read，账号未登录，已跳过用量请求"
            case .unsupportedAccount: return "stage=account/read，非 ChatGPT 账号，已跳过订阅用量请求"
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
    static func accountIdentifier(_ account: [String: Any]) -> String? {
        if let id = account["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "id:" + id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Current app-server ChatgptAccount exposes email rather than an account ID.
        guard let email = account["email"] as? String else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : "email:" + normalized
    }
    static func read(executablePath: String? = nil, timeoutInterval: TimeInterval = 20, proxyURL: URL? = nil) throws -> CodexUsageSnapshot {
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
        if let proxyURL {
            var environment = ProcessInfo.processInfo.environment
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                environment[key] = proxyURL.absoluteString
            }
            environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
            environment["no_proxy"] = environment["NO_PROXY"]
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let startedAt = Date()
        var stage = "启动 app-server"
        var accountID: String?
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
                    stage = "account/read"
                    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                } else if id == 2 {
                    guard let result = message["result"] as? [String: Any], result.keys.contains("account") else {
                        throw ReadError.failed("账号检查返回格式无效，已跳过用量请求")
                    }
                    guard let account = result["account"] as? [String: Any] else {
                        throw ReadError.notLoggedIn
                    }
                    guard account["type"] as? String == "chatgpt" else {
                        throw ReadError.unsupportedAccount
                    }
                    accountID = accountIdentifier(account)
                    stage = "account/rateLimits/read"
                    try send(["id": 3, "method": "account/rateLimits/read"])
                } else if id == 3, let result = message["result"] {
                    stage = "解析用量响应"
                    var snapshot = try JSONDecoder().decode(CodexUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
                    snapshot.accountID = accountID
                    return snapshot
                }
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let exit = process.isRunning ? "仍在运行，输出流已结束" : "exit=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)"
        throw ReadError.failed("\(elapsed >= 20 ? "达到 20 秒读取超时" : "未收到完整响应")，\(exit)")
        } catch {
            if let readError = error as? ReadError {
                switch readError {
                case .notLoggedIn, .unsupportedAccount: throw readError
                default: break
                }
            }
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
    @Published var proxyConnected = false {
        didSet { if !proxyConnected { retryTimer?.invalidate(); retryTimer = nil } }
    }
    var proxyURL: URL?
    var onSnapshot: ((CodexUsageSnapshot) -> Void)?
    @Published var snapshot: CodexUsageSnapshot?
    @Published var updatedAt: Date?
    @Published var message: String?
    @Published var isRefreshing = false
    private var refreshTimer: Timer?
    private var retryTimer: Timer?
    private let retryInterval: TimeInterval
    private let readSnapshot: (@Sendable () throws -> CodexUsageSnapshot)?

    init(refreshInterval: TimeInterval = 300,
         retryInterval: TimeInterval = 60,
         readSnapshot: (@Sendable () throws -> CodexUsageSnapshot)? = nil) {
        self.readSnapshot = readSnapshot
        self.retryInterval = retryInterval
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { refreshTimer?.invalidate(); retryTimer?.invalidate() }

    func refresh(force: Bool = false) async {
        guard proxyConnected, !isRefreshing else { return }
        guard force || retryTimer == nil else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let proxy = proxyURL
            let read = readSnapshot ?? { try CodexUsageReader.read(proxyURL: proxy) }
            let result = try await Task.detached(priority: .utility) { try read() }.value
            guard proxyConnected else { return }
            snapshot = result
            updatedAt = Date()
            message = nil
            onSnapshot?(result)
        } catch {
            guard proxyConnected else { return }
            var shouldRetry = true
            if let readError = error as? CodexUsageReader.ReadError {
                switch readError {
                case .notLoggedIn, .unsupportedAccount:
                    shouldRetry = false
                    snapshot = nil
                    updatedAt = nil
                default: break
                }
            }
            let detail = (error as? CodexUsageReader.ReadError)?.diagnostic ?? "\((error as NSError).domain) code=\((error as NSError).code)"
            AppLogger.shared.warning("[Codex 用量] 刷新失败；保留上次数据=\(snapshot != nil)；\(detail)")
            message = (error as? CodexUsageReader.ReadError)?.errorDescription ?? "用量读取失败，请稍后重试。"
            if shouldRetry {
                let timer = Timer(timeInterval: retryInterval, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.retryTimer = nil
                        await self?.refresh()
                    }
                }
                retryTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                AppLogger.shared.info("[Codex 用量] 将在 \(Int(retryInterval)) 秒后重试用量查询（通过 HopWorld 代理）")
            }
        }
    }
}

struct CodexUsageCard: View {
    let statisticsHeight: CGFloat
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var monitor: CodexUsageMonitor
    @StateObject private var cursorMonitor = CursorUsageMonitor()
    @State private var showDetails = false
    @State private var showStatistics = false
    private struct UsageSettingsDraft {
        var frontProvider = "codex"
        var backProvider = "cursor"
        var showFiveHour = true
        var showWeekly = true
        var showResets = true
        var showCredits = true
        var showReserve = true
        var showResetTime = true
        var showProgress = true
        var displayMode = "list"
        var showCursorTotal = true
        var showCursorModels = true
        var showCursorOtherModels = true
    }
    @State private var usageSettingsDraft = UsageSettingsDraft()
    @State private var showSettings = false
    @State private var settingsTab = "display"
    @State private var notificationDraft = CodexResetNotificationSettings()
    @State private var showCreditsExplanation = false
    @State private var showReserveExplanation = false
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
    @AppStorage("usageCard.displayMode") private var displayMode = "list"
    @AppStorage("usageCard.cursorTotal") private var showCursorTotal = true
    @AppStorage("usageCard.cursorModels") private var showCursorModels = true
    @AppStorage("usageCard.cursorOtherModels") private var showCursorOtherModels = true

    private var activeProvider: String { cursorFace ? backProvider : frontProvider }
    private var isCursorFace: Bool { activeProvider == "cursor" }
    private var isCodexFace: Bool { activeProvider == "codex" }
    private var shouldShowCredits: Bool { showCredits && monitor.snapshot?.hasZeroCreditBalance != true }
    private var shouldShowReserve: Bool { showReserve && monitor.snapshot?.reserveWindow != nil }
    private var providerName: String { activeProvider == "cursor" ? "Cursor" : activeProvider == "claude" ? "Claude" : "Codex" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    usageSettingsDraft.frontProvider = frontProvider
                    usageSettingsDraft.backProvider = backProvider
                    usageSettingsDraft.showFiveHour = showFiveHour
                    usageSettingsDraft.showWeekly = showWeekly
                    usageSettingsDraft.showResets = showResets
                    usageSettingsDraft.showCredits = showCredits
                    usageSettingsDraft.showReserve = showReserve
                    usageSettingsDraft.showResetTime = showResetTime
                    usageSettingsDraft.showProgress = showProgress
                    usageSettingsDraft.displayMode = displayMode
                    usageSettingsDraft.showCursorTotal = showCursorTotal
                    usageSettingsDraft.showCursorModels = showCursorModels
                    usageSettingsDraft.showCursorOtherModels = showCursorOtherModels
                    notificationDraft = appState.codexNotifications.settings
                    showSettings = true
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("用量设置")
                    .accessibilityLabel("用量设置")
                Button { showDetails = true } label: {
                    Text("用量 · " + providerName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .buttonStyle(.plain)
                .help("查看用量详情")
                Spacer(minLength: 0)
                Button { flipCard() } label: {
                    Flip360Icon()
                        .scaleEffect(0.75)
                }
                .buttonStyle(.borderless)
                .disabled(isFlipping)
                .help(isCursorFace ? "翻转到 Codex 用量" : "翻转到 Cursor 用量")
                .accessibilityLabel(isCursorFace ? "翻转到 Codex 用量" : "翻转到 Cursor 用量")
            }
            if isCursorFace {
                if displayMode == "rings" {
                    UsageRingsView(items: cursorRingItems, centerValue: nil, centerTitle: "", centerExpiration: nil, showTimes: showResetTime)
                } else {
                    cursorUsageContent
                }
            } else if !monitor.proxyConnected && monitor.snapshot == nil {
                Text("尚未获取用量").font(.caption2).foregroundStyle(.secondary)
            } else if monitor.snapshot == nil && monitor.message != nil {
                unavailableContent
            } else if displayMode == "rings" {
                UsageRingsView(
                    items: codexRingItems,
                    centerValue: showResets ? (monitor.snapshot?.rateLimitResetCredits.map { "\($0.availableCount)次" } ?? "—") : nil,
                    centerTitle: "可用重置",
                    centerExpiration: showResets ? resetExpiration : nil,
                    showTimes: showResetTime
                )
            } else {
                if showFiveHour { usageRow("5 小时", minutes: 300) }
                if showWeekly { usageRow("一周", minutes: 10_080) }
                if shouldShowReserve, let reserve = monitor.snapshot?.reserveWindow {
                    reserveUsageRow(reserve)
                }
                if (showFiveHour || showWeekly || shouldShowReserve) && (showResets || shouldShowCredits) { Divider() }
                if showResets {
                    valueRow("可用重置" + (monitor.snapshot?.rateLimitResetCredits?.expirationSuffix ?? ""), value: monitor.snapshot?.rateLimitResetCredits.map { "\($0.availableCount) 次" } ?? "未获取")
                }
                if shouldShowCredits { valueRow("额度", value: monitor.snapshot?.creditLabel ?? "未获取") }
                if !showFiveHour && !showWeekly && !shouldShowReserve && !showResets && !shouldShowCredits {
                    Text("在用量设置中选择显示内容").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 3) {
                if !isCursorFace && !monitor.proxyConnected {
                    Text("连接代理后获取用量")
                } else if (isCursorFace ? cursorMonitor.message : monitor.message) != nil {
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
                if isCodexFace {
                    Button { showStatistics = true } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Token 消耗统计")
                    .accessibilityLabel("查看 Codex Token 消耗统计")
                }
                Button {
                    let refreshingCursor = isCursorFace
                    Task {
                        if refreshingCursor {
                            guard !cursorMonitor.isRefreshing else { return }
                            appState.flashToast("正在刷新 Cursor 用量…")
                            await cursorMonitor.refresh(allowKeychainInteraction: true)
                            appState.flashToast(cursorMonitor.message.map { "刷新失败：" + $0 } ?? "Cursor 用量已更新")
                        } else {
                            guard monitor.proxyConnected else {
                                appState.flashToast("请先连接代理，再获取 Codex 用量")
                                return
                            }
                            guard !monitor.isRefreshing else { return }
                            appState.flashToast("正在刷新 Codex 用量…")
                            await monitor.refresh(force: true)
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
        .sheet(isPresented: $showStatistics) {
            CodexTokenStatisticsView(
                fiveHourResetsAt: monitor.snapshot?.window(minutes: 300)?.resetsAt,
                weeklyResetsAt: monitor.snapshot?.window(minutes: 10_080)?.resetsAt,
                availableHeight: statisticsHeight
            )
        }
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
                    usageRow("一周使用限额", minutes: 10_080, detailed: true)
                    Divider()
                    valueRow("可用重置次数" + (monitor.snapshot?.rateLimitResetCredits?.expirationSuffix ?? ""), value: monitor.snapshot?.rateLimitResetCredits.map { "\($0.availableCount) 次" } ?? "未获取")
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
            await cursorMonitor.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await cursorMonitor.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await cursorMonitor.refresh() }
        }
    }

    private var resetExpiration: String {
        let value = monitor.snapshot?.rateLimitResetCredits?.expirationSuffix.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "到期时间未获取" : "到期：" + value
    }

    private func ringTime(_ timestamp: Double?) -> String {
        guard let timestamp else { return "重置时间未获取" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M月d日 HH:mm"
        return "重置：" + formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private var codexRingItems: [UsageRingItem] {
        var items: [UsageRingItem] = []
        if showFiveHour {
            let window = monitor.snapshot?.window(minutes: 300)
            items.append(.init(id: "fiveHour", title: "5小时", value: window.map { "\(Int($0.remaining.rounded()))%" } ?? "未获取", remaining: window?.remaining, color: .blue, time: ringTime(window?.resetsAt)))
        }
        if shouldShowReserve {
            let window = monitor.snapshot?.reserveWindow
            items.append(.init(id: "reserve", title: "Reserve", value: window.map { "\(Int($0.remaining.rounded()))%" } ?? "未获取", remaining: window?.remaining, color: .purple, time: ringTime(window?.resetsAt)))
        }
        if showWeekly {
            let window = monitor.snapshot?.window(minutes: 10_080)
            items.append(.init(id: "weekly", title: "一周", value: window.map { "\(Int($0.remaining.rounded()))%" } ?? "未获取", remaining: window?.remaining, color: .orange, time: ringTime(window?.resetsAt)))
        }
        if shouldShowCredits {
            items.append(.init(id: "credits", title: "额度", value: monitor.snapshot?.creditLabel ?? "未获取", remaining: nil, color: .pink, time: ""))
        }
        return items
    }

    private var cursorRingItems: [UsageRingItem] {
        var items: [UsageRingItem] = []
        let plan = cursorMonitor.snapshot?.planUsage
        let time = ringTime(cursorMonitor.snapshot?.billingCycleEnd?.timeIntervalSince1970)
        if showCursorTotal { items.append(.init(id: "total", title: "综合", value: cursorPercentLabel(plan?.totalRemaining), remaining: plan?.totalRemaining, color: .blue, time: time)) }
        if showCursorModels { items.append(.init(id: "cursor", title: "Cursor", value: cursorPercentLabel(plan?.cursorModelsRemaining), remaining: plan?.cursorModelsRemaining, color: .purple, time: time)) }
        if showCursorOtherModels { items.append(.init(id: "other", title: "其他", value: cursorPercentLabel(plan?.otherModelsRemaining), remaining: plan?.otherModelsRemaining, color: .orange, time: time)) }
        return items
    }

    private func cursorPercentLabel(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "未获取"
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用量设置").font(.title2.weight(.semibold))
            Picker("设置分类", selection: $settingsTab) {
                Text("卡片显示").tag("display")
                Text("通知").tag("notifications")
            }
            .pickerStyle(.segmented)
            Form {
                if settingsTab == "notifications" {
                    CodexResetNotificationSettingsFields(settings: $notificationDraft,
                        controller: appState.codexNotifications)
                } else {
                Section("卡片两面应用") {
                    Picker("正面", selection: $usageSettingsDraft.frontProvider) {
                        Text("Codex").tag("codex")
                        Text("Cursor").tag("cursor")
                        Text("Claude").tag("claude")
                    }
                    Picker("背面", selection: $usageSettingsDraft.backProvider) {
                        Text("Codex").tag("codex")
                        Text("Cursor").tag("cursor")
                        Text("Claude").tag("claude")
                    }
                    Text("点击卡片右下角翻转按钮切换两面。Codex 与 Cursor 支持自动读取，Claude 当前显示接入状态。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Codex 卡片显示内容") {
                    Toggle("5 小时剩余用量", isOn: $usageSettingsDraft.showFiveHour)
                    Toggle("一周剩余用量", isOn: $usageSettingsDraft.showWeekly)
                    Toggle(isOn: $usageSettingsDraft.showReserve) {
                        HStack(spacing: 5) {
                            Text("Luna Reserve 剩余用量")
                            Button { showReserveExplanation = true } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Luna Reserve 显示说明")
                            .accessibilityLabel("Luna Reserve 显示说明")
                            .popover(isPresented: $showReserveExplanation) {
                                Text("未获取到 Luna Reserve 用量时，即使开启此选项也会自动隐藏，对应圆环和下方时间图例均不显示。获取到数据后自动显示；剩余为 0 时仍会显示。隐藏后其余圆环会自动调整宽度。")
                                    .font(.callout)
                                    .padding(16)
                                    .frame(width: 280)
                            }
                        }
                    }
                    Toggle("可用重置次数", isOn: $usageSettingsDraft.showResets)
                    Toggle(isOn: $usageSettingsDraft.showCredits) {
                        HStack(spacing: 5) {
                            Text("剩余额度")
                            Button { showCreditsExplanation = true } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("剩余额度显示说明")
                            .accessibilityLabel("剩余额度显示说明")
                            .popover(isPresented: $showCreditsExplanation) {
                                Text("额度为 0 时，即使开启此选项也会自动隐藏。圆环模式下，有额度时仅在额度圆环上显示数量，下方不显示额度图例。额度没有到期时间，也不会换算成百分比；尚未获取的数据仍显示“未获取”。")
                                    .font(.callout)
                                    .padding(16)
                                    .frame(width: 280)
                            }
                        }
                    }
                }
                Section("显示样式") {
                    Picker("显示模式", selection: $usageSettingsDraft.displayMode) {
                        Text("列表").tag("list")
                        Text("圆环").tag("rings")
                    }
                    Text("圆环由外向内：5 小时、Luna Reserve、一周、额度；中心显示可用重置次数。额度无总额时仅显示数值。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("显示用量进度条", isOn: $usageSettingsDraft.showProgress)
                    Toggle("显示重置时间", isOn: $usageSettingsDraft.showResetTime)
                }
                Section("Cursor 卡片显示内容") {
                    Toggle("综合剩余用量", isOn: $usageSettingsDraft.showCursorTotal)
                    Toggle("Cursor 模型剩余用量", isOn: $usageSettingsDraft.showCursorModels)
                    Toggle("其他模型剩余用量", isOn: $usageSettingsDraft.showCursorOtherModels)
                    Text("自动读取本机 Cursor 登录账号，无需手动填写。每 5 分钟刷新，翻面不影响两侧自动更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("打开 Cursor 用量页面") {
                        openExternal("https://cursor.com/dashboard?tab=usage")
                    }
                }
                }
            }
            .formStyle(.grouped)
            HStack {
                if settingsTab == "notifications" {
                    CodexNotificationInfoButton("查看保存与测试说明", text: "点击“应用设置”保存自动通知和收件人修改。测试发送使用当前勾选的账号，不必先保存，也不会改变自动通知开关或监测基线。")
                } else {
                    Text("点击应用后保存").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { showSettings = false }
                Button("应用设置") {
                    frontProvider = usageSettingsDraft.frontProvider
                    backProvider = usageSettingsDraft.backProvider
                    showFiveHour = usageSettingsDraft.showFiveHour
                    showWeekly = usageSettingsDraft.showWeekly
                    showResets = usageSettingsDraft.showResets
                    showCredits = usageSettingsDraft.showCredits
                    showReserve = usageSettingsDraft.showReserve
                    showResetTime = usageSettingsDraft.showResetTime
                    showProgress = usageSettingsDraft.showProgress
                    displayMode = usageSettingsDraft.displayMode
                    showCursorTotal = usageSettingsDraft.showCursorTotal
                    showCursorModels = usageSettingsDraft.showCursorModels
                    showCursorOtherModels = usageSettingsDraft.showCursorOtherModels
                    appState.codexNotifications.apply(notificationDraft)
                    showSettings = false
                }
                .disabled(notificationDraft.validationError != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480, height: 600)
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("未获取", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("重试") {
                    Task {
                        guard monitor.proxyConnected else {
                            appState.flashToast("请先连接代理，再获取 Codex 用量")
                            return
                        }
                        appState.flashToast("正在重试 Codex 用量…")
                        await monitor.refresh(force: true)
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

private struct UsageRingItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let remaining: Double?
    let color: Color
    let time: String
}

private struct UsageRingsView: View {
    let items: [UsageRingItem]
    let centerValue: String?
    let centerTitle: String
    let centerExpiration: String?
    let showTimes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty && centerValue == nil {
                Text("在用量设置中选择显示内容").font(.caption2).foregroundStyle(.secondary)
            } else {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let ringCount = CGFloat(max(1, items.count))
                    let outerRadius = side * 0.48
                    let innerRadius = side * (centerValue == nil ? 0.10 : 0.14)
                    let gap = side * 0.025
                    let ringWidth = max(1, (outerRadius - innerRadius - gap * (ringCount - 1)) / ringCount)
                    ZStack {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let diameter = 2 * (outerRadius - ringWidth / 2 - CGFloat(index) * (ringWidth + gap))
                            ZStack {
                                Circle().stroke(item.color.opacity(0.18), lineWidth: ringWidth)
                                if let remaining = item.remaining {
                                    Circle()
                                        .trim(from: 0, to: min(1, max(0, remaining / 100)))
                                        .stroke(item.color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                } else if item.id == "credits" {
                                    Circle().stroke(item.color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                                }
                            }
                            .frame(width: diameter, height: diameter)
                            .overlay {
                                RingArcLabel(text: item.title + " " + item.value)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(item.title == "Reserve" ? "Luna Reserve" : item.title)
                            .accessibilityValue(item.value)
                            .help(item.title + "：" + item.value + "；" + item.time)
                        }
                        if let centerValue {
                            Circle().fill(Color.teal.opacity(0.18))
                                .overlay { Circle().stroke(Color.teal, lineWidth: 1) }
                                .frame(width: side * 0.19, height: side * 0.19)
                                .overlay {
                                    Text(centerValue)
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .accessibilityLabel(centerTitle)
                                .accessibilityValue(centerValue)
                                .help(centerTitle + "：" + centerValue)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .aspectRatio(1, contentMode: .fit)

                if showTimes {
                    ForEach(items.filter { $0.id != "credits" }) { item in
                        legendRow(title: item.title == "Reserve" ? "Luna Reserve" : item.title, detail: item.time.replacingOccurrences(of: "重置：", with: ""), color: item.color)
                    }
                    if let centerExpiration {
                        legendRow(title: centerTitle, detail: centerExpiration, color: .teal)
                    }
                }
            }
        }
    }

    private func legendRow(title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 2)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity)
        .help(title + " " + detail)
        .accessibilityElement(children: .combine)
    }
}

private struct RingArcLabel: View {
    let text: String

    var body: some View {
        Canvas { context, size in
            let radius = (min(size.width, size.height) - 10) / 2
            guard radius > 0 else { return }
            let font = Font.system(size: 8, weight: .semibold, design: .rounded).monospacedDigit()
            let glyphs = text.map { String($0) }
            let widths = glyphs.map { context.resolve(Text($0).font(font)).measure(in: CGSize(width: 100, height: 100)).width }
            var angle = -Double.pi / 2 - widths.reduce(0, +) / (2 * radius)
            for index in glyphs.indices {
                let halfStep = widths[index] / (2 * radius)
                angle += halfStep
                var glyphContext = context
                glyphContext.translateBy(x: size.width / 2 + cos(angle) * radius,
                                         y: size.height / 2 + sin(angle) * radius)
                glyphContext.rotate(by: .radians(angle + .pi / 2))
                // A fine halo keeps labels legible on both filled and empty ring segments.
                let halo = context.resolve(Text(glyphs[index]).font(font).foregroundColor(Color(nsColor: .windowBackgroundColor)))
                for offset in [CGPoint(x: -0.6, y: 0), CGPoint(x: 0.6, y: 0), CGPoint(x: 0, y: -0.6), CGPoint(x: 0, y: 0.6)] {
                    glyphContext.draw(halo, at: offset)
                }
                glyphContext.draw(context.resolve(Text(glyphs[index]).font(font).foregroundColor(.primary)), at: .zero)
                angle += halfStep
            }
        }
        .padding(-5)
        .accessibilityHidden(true)
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
