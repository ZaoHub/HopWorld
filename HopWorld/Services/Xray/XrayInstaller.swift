import Foundation
import Combine
import CryptoKit
import Darwin

enum XrayUpdateError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

/// Xray 安装包下载线路。默认直连 GitHub；镜像仅改写 releases/download URL。
enum XrayDownloadMirror: String, CaseIterable, Identifiable, Codable, Sendable {
    case github
    case ghproxyNet
    case ghProxyCom
    case ghfastTop
    case ghLlkk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: return "GitHub 直连（默认）"
        case .ghproxyNet: return "ghproxy.net"
        case .ghProxyCom: return "gh-proxy.com"
        case .ghfastTop: return "ghfast.top"
        case .ghLlkk: return "gh.llkk.cc"
        }
    }

    /// 状态文案用，避免「默认」字样重复出现。
    var statusLabel: String {
        switch self {
        case .github: return "GitHub 直连"
        default: return title
        }
    }

    /// shortcut: 公益镜像域名会变，挂了就换；升级时改 allCases 列表即可。
    func rewrite(_ url: URL) -> URL {
        let prefix: String?
        switch self {
        case .github: prefix = nil
        case .ghproxyNet: prefix = "https://ghproxy.net/"
        case .ghProxyCom: prefix = "https://gh-proxy.com/"
        case .ghfastTop: prefix = "https://ghfast.top/"
        case .ghLlkk: prefix = "https://gh.llkk.cc/"
        }
        guard let prefix else { return url }
        return URL(string: prefix + url.absoluteString) ?? url
    }
}

enum XrayInstaller {
    static let masqueMinimumVersion = "26.10.21"
    static let preferredVersion = masqueMinimumVersion

    /// Shown when a probe needs the core but none is installed.
    static let missingCoreGuidance =
        "未安装 Xray 核心，无法测代理连通。请打开「关于 → 管理更新」安装 Xray；若下载失败，可切换下载线路后重试。"
    static let missingCoreShortGuidance = "未安装 Xray 核心，请先安装后再测速"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HopWorld", isDirectory: true)
    }

    static var managedBinaryURL: URL? {
        let current = supportDirectory.appendingPathComponent("current/xray")
        return FileManager.default.isExecutableFile(atPath: current.path) ? current.resolvingSymlinksInPath() : nil
    }

    static var supportBinaryURL: URL {
        managedBinaryURL ?? supportDirectory.appendingPathComponent("xray")
    }

    private static let versionCacheLock = NSLock()
    private static var versionCache: [String: (mtime: Date?, version: String?)] = [:]

    private static let installations = XrayInstallationCoordinator()

    /// Keep newer installed cores instead of downgrading them to the bundled baseline.
    @discardableResult
    static func ensureInstalled() async throws -> URL {
        if let existing = XrayProcessManager.resolveBinaryURL(),
           let installed = version(of: existing),
           (existing == managedBinaryURL || isVersion(installed, atLeast: preferredVersion)),
           assetDirectory(for: existing) != nil {
            return existing
        }
        let release = try await fetchReleaseResult(version: preferredVersion)
        return try await install(release: release)
    }

    private static func fetchReleaseResult(version: String) async throws -> XrayRelease {
        try await fetchRelease(path: "tags/v\(version)")
    }

    static let downloadMirrorKey = "xray.downloadMirror"

    static var preferredDownloadMirror: XrayDownloadMirror {
        let raw = UserDefaults.standard.string(forKey: downloadMirrorKey) ?? XrayDownloadMirror.github.rawValue
        return XrayDownloadMirror(rawValue: raw) ?? .github
    }

    static func install(
        release: XrayRelease,
        allowSwitch: Bool = false,
        mirror: XrayDownloadMirror? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try await installations.install(
            release,
            allowSwitch: allowSwitch,
            mirror: mirror ?? preferredDownloadMirror,
            onProgress: onProgress
        )
    }

    static func isVersion(_ version: String, atLeast baseline: String) -> Bool {
        guard let left = versionParts(version), let right = versionParts(baseline) else { return false }
        return !left.lexicographicallyPrecedes(right)
    }

    static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    static func fetchRelease(path: String = "latest") async throws -> XrayRelease {
        let endpoint = "https://api.github.com/repos/XTLS/Xray-core/releases"
        let url = URL(string: path == "newest" ? endpoint + "?per_page=1" : endpoint + "/" + path)!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HopWorld", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw XrayUpdateError.failed("检查 Xray 更新失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let release: XrayRelease
        if path == "newest" {
            guard let newest = try JSONDecoder().decode([XrayRelease].self, from: data).first else {
                throw XrayUpdateError.failed("官方暂无 Xray 发布版本")
            }
            release = newest
        } else {
            release = try JSONDecoder().decode(XrayRelease.self, from: data)
        }
        _ = try release.validatedVersion(allowPrerelease: path != "latest")
        return release
    }

    static func assetDirectory(for binary: URL) -> URL? {
        let candidates: [URL] = ([GeoFilesInstaller.currentDirectory, binary.deletingLastPathComponent(),
                                   supportDirectory, Bundle.main.resourceURL] as [URL?]).compactMap { $0 }
        return candidates.first { directory in
            ["geoip.dat", "geosite.dat"].allSatisfy { name in
                let url = directory.appendingPathComponent(name)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return size > 0 && FileManager.default.isReadableFile(atPath: url.path)
            }
        }
    }

    private static func invalidateVersionCache(for url: URL) {
        versionCacheLock.lock()
        defer { versionCacheLock.unlock() }
        versionCache.removeValue(forKey: url.path)
    }

    static func version(of url: URL) -> String? {
        versionCacheLock.lock()
        defer { versionCacheLock.unlock() }
        let path = url.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        if let cached = versionCache[path], cached.mtime == mtime {
            return cached.version
        }

        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            versionCache[path] = (mtime, nil)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        // "Xray 26.9.9 (Xray, Penetrates Everything.) ..."
        let parsed: String? = {
            let parts = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard parts.count >= 2, parts[0] == "Xray" else { return nil }
            return String(parts[1])
        }()
        versionCache[path] = (mtime, parsed)
        return parsed
    }

    fileprivate static func downloadOfficialRelease(
        _ release: XrayRelease,
        mirror: XrayDownloadMirror = .github,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let version = try release.validatedVersion(allowPrerelease: true)
        let asset = try release.archiveAsset()
        let official = URL(string: "https://github.com/XTLS/Xray-core/releases/download/v\(version)/\(asset.name)")!
        let url = mirror.rewrite(official)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await downloadFile(from: url, using: session, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw XrayUpdateError.failed("下载 Xray 失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        onProgress?(1)
        try asset.verify(Data(contentsOf: temporary))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("HopWorld-xray-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporary, to: archive)
        let extracted = work.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await unzip(archive, to: extracted)
        return try await activateExtractedRelease(at: extracted, version: version, directory: supportDirectory)
    }

    /// Shared by Xray / sing-box / GeoFiles updates so every installer can report the same 0…1 progress.
    static func downloadFile(
        from url: URL,
        timeoutRequest: TimeInterval = 15,
        timeoutResource: TimeInterval = 180,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutRequest
        configuration.timeoutIntervalForResource = timeoutResource
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await downloadFile(from: url, using: session, onProgress: onProgress)
    }

    /// URLSession.download(from:) 不回调进度；用 downloadTask + Progress 观测。
    private static func downloadFile(
        from url: URL,
        using session: URLSession,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        final class ObservationBox: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var task: URLSessionDownloadTask?
        }
        let box = ObservationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                let task = session.downloadTask(with: url) { tempURL, response, error in
                    box.observation?.invalidate()
                    box.observation = nil
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let tempURL, let response else {
                        continuation.resume(throwing: XrayUpdateError.failed("下载 Xray 失败：无响应"))
                        return
                    }
                    do {
                        // downloadTask 回调返回后临时文件会被删，先拷走。
                        let kept = FileManager.default.temporaryDirectory
                            .appendingPathComponent("HopWorld-dl-\(UUID().uuidString)")
                        try FileManager.default.copyItem(at: tempURL, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                if let onProgress {
                    box.observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                        onProgress(min(1, max(0, progress.fractionCompleted)))
                    }
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Validate the entire package before one atomic pointer switch. Running cores keep their resolved paths.
    static func activateExtractedRelease(at extracted: URL, version: String, directory: URL) async throws -> URL {
        guard versionParts(version) != nil, let sourceBinary = findXrayBinary(in: extracted) else {
            throw XrayUpdateError.failed("更新包中未找到有效的 Xray")
        }
        let cores = directory.appendingPathComponent("cores")
        try FileManager.default.createDirectory(at: cores, withIntermediateDirectories: true)
        let staged = cores.appendingPathComponent("\(version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        var activated = false
        defer { if !activated { try? FileManager.default.removeItem(at: staged) } }
        let binary = staged.appendingPathComponent("xray")
        try FileManager.default.copyItem(at: sourceBinary, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        for name in ["geoip.dat", "geosite.dat"] {
            let data = try Data(contentsOf: sourceBinary.deletingLastPathComponent().appendingPathComponent(name))
            guard !data.isEmpty else { throw XrayUpdateError.failed("更新包中的规则数据为空：\(name)") }
            try data.write(to: staged.appendingPathComponent(name), options: .atomic)
        }
        await clearQuarantine(at: binary)
        let result = try await ProcessRunner.run(executable: binary, arguments: ["version"], timeout: 5)
        let parts = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard result.status == 0, !result.timedOut, !result.cancelled,
              parts.count >= 2, parts[0] == "Xray", parts[1] == Substring(version) else {
            throw XrayUpdateError.failed("更新包中的 Xray 版本或架构校验失败")
        }
        try await validateInstallation(binary: binary, assets: staged)
        if let rules = GeoFilesInstaller.currentDirectory {
            try await validateInstallation(binary: binary, assets: rules)
        }
        try Task.checkCancellation()
        let link = directory.appendingPathComponent(".current-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: staged)
        guard rename(link.path, directory.appendingPathComponent("current").path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        activated = true
        return binary
    }

    /// Native config validation also checks that the cn/private rule sets can be read.
    static func validateInstallation(binary: URL, assets: URL) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-xray-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let node = ProxyNode(name: "compatibility", protocolType: .vless, server: "127.0.0.1", port: 443,
                             uuid: "11111111-1111-4111-8111-111111111111")
        let config = try XrayConfigBuilder.build(node: node,
            ports: .init(socksHost: "127.0.0.1", socksPort: 12001, httpHost: "127.0.0.1", httpPort: 12002),
            routingMode: .rules, applicationProxy: (port: 12003, password: "compatibility-check"))
        try XrayConfigBuilder.writeJSON(config, to: file)
        var environment = ProcessInfo.processInfo.environment
        environment["XRAY_LOCATION_ASSET"] = assets.path
        let result = try await ProcessRunner.run(executable: binary,
            arguments: ["run", "-test", "-config", file.path], timeout: 15, environment: environment)
        guard result.status == 0, !result.timedOut, !result.cancelled else {
            throw XrayUpdateError.failed("Xray 配置或规则兼容性检查失败：" + String(decoding: result.output.prefix(1200), as: UTF8.self))
        }
    }

    private static func findXrayBinary(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "xray" {
                return fileURL
            }
        }
        return nil
    }

    private static func unzip(_ zipURL: URL, to directory: URL) async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-o", zipURL.path, "-d", directory.path], timeout: 20)
        try Task.checkCancellation()
        guard result.status == 0, !result.timedOut else {
            throw XrayUpdateError.failed("解压失败或超时：\(String(decoding: result.output.suffix(500), as: UTF8.self))")
        }
    }

    private static func clearQuarantine(at url: URL) async {
        _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", url.path], timeout: 3)
    }
}

struct XrayRelease: Codable, Sendable {
    struct Asset: Codable, Sendable {
        let name: String
        let digest: String?

        func verify(_ data: Data) throws {
            let actual = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest?.lowercased() == actual else {
                throw XrayUpdateError.failed("更新文件 SHA256 校验失败或缺少官方摘要")
            }
        }
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func validatedVersion(allowPrerelease: Bool = false) throws -> String {
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        guard !draft, (allowPrerelease || !prerelease), XrayInstaller.versionParts(version) != nil else {
            throw XrayUpdateError.failed("官方发布信息不是有效的 Xray 版本")
        }
        return version
    }

    func archiveAsset() throws -> Asset {
        #if arch(arm64)
        let name = "Xray-macos-arm64-v8a.zip"
        #else
        let name = "Xray-macos-64.zip"
        #endif
        guard let asset = assets.first(where: { $0.name == name }) else {
            throw XrayUpdateError.failed("官方发布中没有适配当前 Mac 的 Xray 更新文件")
        }
        return asset
    }
}

private actor XrayInstallationCoordinator {
    private var pending: (id: UUID, task: Task<URL, Error>)?

    func install(
        _ release: XrayRelease,
        allowSwitch: Bool,
        mirror: XrayDownloadMirror,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let requested = try release.validatedVersion(allowPrerelease: true)
        while let running = pending {
            _ = try? await running.task.value
            if pending?.id == running.id { pending = nil }
        }
        if !allowSwitch, let existing = XrayProcessManager.resolveBinaryURL(),
           let version = XrayInstaller.version(of: existing),
           XrayInstaller.isVersion(version, atLeast: requested),
           XrayInstaller.assetDirectory(for: existing) != nil { return existing }
        let id = UUID()
        let task = Task {
            try await XrayInstaller.downloadOfficialRelease(release, mirror: mirror, onProgress: onProgress)
        }
        pending = (id, task)
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }
}

@MainActor
final class XrayUpdateManager: ObservableObject {
    @Published private(set) var installedVersion: String?
    @Published private(set) var latestRelease: XrayRelease?
    @Published private(set) var stableRelease: XrayRelease?
    @Published private(set) var isUpdating = false
    /// 下载阶段 0…1；检查更新 / 校验安装时为 nil。
    @Published private(set) var downloadProgress: Double?
    /// 当前正在安装的目标版本；空闲时为 nil。
    @Published private(set) var updatingVersion: String?
    @Published private(set) var status = "每天自动检查两个版本；开启自动更新后仅安装官方稳定版。"
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticUpdates: Bool {
        didSet { defaults.set(automaticUpdates, forKey: "xray.automaticUpdates") }
    }
    @Published var downloadMirror: XrayDownloadMirror {
        didSet { defaults.set(downloadMirror.rawValue, forKey: XrayInstaller.downloadMirrorKey) }
    }
    var latestVersion: String? { try? latestRelease?.validatedVersion(allowPrerelease: true) }
    var stableVersion: String? { try? stableRelease?.validatedVersion() }
    var hasUpdateError: Bool { status.contains("失败") }

    /// Prefer the official stable release when it is newer than the installed core.
    var availableStableUpdate: (release: XrayRelease, version: String)? {
        guard let release = stableRelease,
              let version = try? release.validatedVersion(),
              installedVersion.map({ !XrayInstaller.isVersion($0, atLeast: version) }) ?? true else { return nil }
        return (release, version)
    }
    private let defaults: UserDefaults
    private static let lastCheckKey = "xray.lastUpdateCheckAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticUpdates = defaults.object(forKey: "xray.automaticUpdates") as? Bool ?? true
        let raw = defaults.string(forKey: XrayInstaller.downloadMirrorKey) ?? XrayDownloadMirror.github.rawValue
        downloadMirror = XrayDownloadMirror(rawValue: raw) ?? .github
        lastCheckedAt = defaults.object(forKey: Self.lastCheckKey) as? Date
        latestRelease = defaults.data(forKey: "xray.latestRelease").flatMap { try? JSONDecoder().decode(XrayRelease.self, from: $0) }
        stableRelease = defaults.data(forKey: "xray.stableRelease").flatMap { try? JSONDecoder().decode(XrayRelease.self, from: $0) }
    }

    static func claimDailyCheck(defaults: UserDefaults, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           calendar.isDate(last, inSameDayAs: now) { return false }
        defaults.set(now, forKey: lastCheckKey)
        return true
    }

    func checkForUpdates(automatic: Bool = false) async {
        guard !isUpdating else { return }
        guard await LabUtilityProcess.allowInternet(userInitiated: !automatic) else { return }
        // Same-day automatic launch still installs a cached official stable update
        // when auto-update is on; only the network refresh is skipped.
        if automatic && !Self.claimDailyCheck(defaults: defaults) {
            installedVersion = await Self.readInstalledVersion()
            if automaticUpdates { await installAvailableStableUpdateIfNeeded() }
            return
        }
        let now = Date()
        defaults.set(now, forKey: Self.lastCheckKey)
        lastCheckedAt = now
        isUpdating = true
        downloadProgress = nil
        updatingVersion = nil
        status = "正在检查最新版本和官方稳定版…"
        defer {
            isUpdating = false
            downloadProgress = nil
            if !hasUpdateError { updatingVersion = nil }
        }
        installedVersion = await Self.readInstalledVersion()
        async let newest = Self.loadRelease(path: "newest")
        async let stable = Self.loadRelease(path: "latest")
        let results = await (newest, stable)
        var errors: [String] = []
        switch results.0 {
        case .success(let release):
            latestRelease = release
            defaults.set(try? JSONEncoder().encode(release), forKey: "xray.latestRelease")
        case .failure(let error): errors.append("最新版本：\(error.localizedDescription)")
        }
        switch results.1 {
        case .success(let release):
            stableRelease = release
            defaults.set(try? JSONEncoder().encode(release), forKey: "xray.stableRelease")
        case .failure(let error): errors.append("官方稳定版：\(error.localizedDescription)")
        }
        if errors.isEmpty {
            if let update = availableStableUpdate {
                status = automaticUpdates
                    ? "检查完成：发现官方稳定版 \(update.version)，正在自动安装…"
                    : "检查完成：发现官方稳定版 \(update.version)，请在「安装版本」中选择安装。"
            } else if let version = stableVersion, version == installedVersion {
                status = "检查完成：已是官方稳定版 \(version)。"
            } else {
                status = "检查完成，请在「安装版本」中选择要安装的版本。"
            }
        } else {
            status = errors.joined(separator: "；") + "。已有版本信息保留，可重新检查。"
        }
        // Auto-update always installs the official stable channel, never "newest"/prerelease.
        if automaticUpdates { await installAvailableStableUpdateIfNeeded() }
    }

    /// Installs the official stable release when auto-update is enabled and it is newer.
    private func installAvailableStableUpdateIfNeeded() async {
        guard automaticUpdates, let update = availableStableUpdate else { return }
        let nested = isUpdating
        if !nested {
            isUpdating = true
            downloadProgress = nil
            updatingVersion = nil
        }
        defer {
            if !nested {
                isUpdating = false
                downloadProgress = nil
                if !hasUpdateError { updatingVersion = nil }
            }
        }
        status = "发现官方稳定版 \(update.version)，正在自动安装…"
        await installSelectedRelease(update.release, allowSwitch: false)
    }

    func update(to release: XrayRelease) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer {
            isUpdating = false
            downloadProgress = nil
            if !hasUpdateError { updatingVersion = nil }
        }
        await installSelectedRelease(release, allowSwitch: true)
    }

    private func installSelectedRelease(_ release: XrayRelease, allowSwitch: Bool) async {
        guard await LabUtilityProcess.allowInternet(userInitiated: allowSwitch) else { return }
        do {
            let version = try release.validatedVersion(allowPrerelease: allowSwitch)
            updatingVersion = version
            downloadProgress = 0
            let mirror = downloadMirror
            status = "正在通过 \(mirror.statusLabel) 下载 Xray \(version)…"
            let binary = try await XrayInstaller.install(
                release: release,
                allowSwitch: allowSwitch,
                mirror: mirror
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress = fraction
                    let percent = Int((fraction * 100).rounded())
                    self.status = fraction < 1
                        ? "正在通过 \(mirror.statusLabel) 下载 Xray \(version)… \(percent)%"
                        : "正在校验并安装 Xray \(version)…"
                }
            }
            downloadProgress = nil
            installedVersion = await Self.readVersion(binary)
            updatingVersion = nil
            status = "已安装 Xray \(installedVersion ?? version)，下次连接或测试时生效；当前连接不受影响。"
        } catch {
            downloadProgress = nil
            status = "Xray 更新失败：\(error.localizedDescription)。可重新选择版本重试。"
            AppLogger.shared.warning(status, category: .xray)
        }
    }

    nonisolated private static func loadRelease(path: String) async -> Result<XrayRelease, Error> {
        do { return .success(try await XrayInstaller.fetchRelease(path: path)) }
        catch { return .failure(error) }
    }

    func refreshInstalledVersion() async {
        installedVersion = await Self.readInstalledVersion()
    }

    nonisolated private static func readInstalledVersion() async -> String? {
        XrayProcessManager.resolveBinaryURL().flatMap { XrayInstaller.version(of: $0) }
    }

    nonisolated private static func readVersion(_ binary: URL) async -> String? {
        XrayInstaller.version(of: binary)
    }
}
