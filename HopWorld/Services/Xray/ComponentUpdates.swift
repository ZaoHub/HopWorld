import Foundation
import Combine
import Darwin

enum UpdateComponent: String, CaseIterable, Identifiable, Sendable {
    case singBox, geoFiles
    var id: String { rawValue }
    var title: String { self == .singBox ? "sing-box" : "GeoFiles" }
    var repository: String { self == .singBox ? "SagerNet/sing-box" : "Loyalsoldier/v2ray-rules-dat" }
    var summary: String { self == .singBox ? "TUN 接管与部分协议连接" : "国内外 IP、域名分流规则" }

    func installVersion(latest: String?, installed: String?) -> String? {
        guard let latest else { return nil }
        if self == .geoFiles {
            if let installed, installed >= latest { return nil }
            return latest
        }
        let approved = SingBoxInstaller.approvedVersion
        guard XrayInstaller.isVersion(latest, atLeast: approved),
              installed.map({ !XrayInstaller.isVersion($0, atLeast: approved) }) ?? true else { return nil }
        return approved
    }
}

struct ComponentRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let digest: String?

        func verify(_ data: Data) throws {
            guard !data.isEmpty, let digest, digest.hasPrefix("sha256:") else {
                throw XrayUpdateError.failed("缺少官方 SHA-256 摘要或下载文件为空")
            }
            try XrayRelease.Asset(name: name, digest: digest).verify(data)
        }
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func version(for component: UpdateComponent) throws -> String {
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        let valid = component == .singBox ? XrayInstaller.versionParts(version) != nil
            : version.count == 12 && version.allSatisfy { $0.isASCII && $0.isNumber }
        guard !draft, !prerelease, valid else { throw XrayUpdateError.failed("官方发布信息不是有效的稳定版本") }
        return version
    }

    static func fetch(for component: UpdateComponent) async throws -> ComponentRelease {
        let url = URL(string: "https://api.github.com/repos/\(component.repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("HopWorld", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XrayUpdateError.failed("检查更新失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let release = try JSONDecoder().decode(Self.self, from: data)
        _ = try release.version(for: component)
        return release
    }

    func download(
        _ name: String,
        for component: UpdateComponent,
        to directory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        _ = try version(for: component)
        guard let asset = assets.first(where: { $0.name == name }) else {
            throw XrayUpdateError.failed("官方发布缺少文件：\(name)")
        }
        let official = URL(string: "https://github.com/\(component.repository)/releases/download/\(tag_name)/\(name)")!
        let url = XrayInstaller.preferredDownloadMirror.rewrite(official)
        let (temporary, response) = try await XrayInstaller.downloadFile(
            from: url, timeoutRequest: 20, timeoutResource: 180, onProgress: onProgress
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XrayUpdateError.failed("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        onProgress?(1)
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: temporary)
        try asset.verify(bytes)
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file, options: .atomic)
        return file
    }
}

enum GeoFilesInstaller {
    static var root: URL { XrayInstaller.supportDirectory.appendingPathComponent("GeoFiles", isDirectory: true) }
    static var currentDirectory: URL? { currentDirectory(in: root) }

    static func currentDirectory(in root: URL) -> URL? {
        let current = root.appendingPathComponent("current").resolvingSymlinksInPath()
        return ["geoip.dat", "geosite.dat"].allSatisfy {
            ((try? current.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        } ? current : nil
    }

    static var installedVersion: String? {
        guard let directory = currentDirectory else { return nil }
        return try? String(contentsOf: directory.appendingPathComponent("version.txt"), encoding: .utf8)
    }

    static func install(
        _ release: ComponentRelease,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let version = try release.version(for: .geoFiles)
        guard let binary = XrayProcessManager.resolveBinaryURL() else {
            throw XrayUpdateError.failed("请先安装 Xray，再更新规则文件")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // Download both assets from the same immutable release before activating either one.
        // Report overall 0…1 across the pair so the UI matches Xray's single progress bar.
        _ = try await release.download("geoip.dat", for: .geoFiles, to: work) { fraction in
            onProgress?(fraction * 0.5)
        }
        _ = try await release.download("geosite.dat", for: .geoFiles, to: work) { fraction in
            onProgress?(0.5 + fraction * 0.5)
        }
        onProgress?(1)
        try await activate(from: work, version: version, binary: binary, root: root)
    }

    static func activate(from source: URL, version: String, binary: URL, root: URL) async throws {
        guard version.count == 12, version.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw XrayUpdateError.failed("规则版本格式无效")
        }
        let staged = root.appendingPathComponent("\(version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        var activated = false
        defer { if !activated { try? FileManager.default.removeItem(at: staged) } }
        for name in ["geoip.dat", "geosite.dat"] {
            let bytes = try Data(contentsOf: source.appendingPathComponent(name))
            guard !bytes.isEmpty else { throw XrayUpdateError.failed("规则文件为空：\(name)") }
            try bytes.write(to: staged.appendingPathComponent(name), options: .atomic)
        }
        try await XrayInstaller.validateInstallation(binary: binary, assets: staged)
        try Data(version.utf8).write(to: staged.appendingPathComponent("version.txt"), options: .atomic)
        try Task.checkCancellation()
        let link = root.appendingPathComponent(".current-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: staged)
        guard rename(link.path, root.appendingPathComponent("current").path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        activated = true
    }
}

@MainActor
final class ComponentUpdateManager: ObservableObject {
    let component: UpdateComponent
    @Published private(set) var installedVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var isBusy = false
    @Published private(set) var hasError = false
    /// 下载阶段 0…1；检查更新 / 校验安装时为 nil。与 Xray 进度展示一致。
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var status = "每天首次启动检查更新。"
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticUpdates: Bool {
        didSet { defaults.set(automaticUpdates, forKey: component.rawValue + ".automaticUpdates") }
    }
    private let defaults: UserDefaults
    private var release: ComponentRelease?

    init(_ component: UpdateComponent, defaults: UserDefaults = .standard) {
        self.component = component
        self.defaults = defaults
        automaticUpdates = defaults.object(forKey: component.rawValue + ".automaticUpdates") as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: component.rawValue + ".lastCheckedAt") as? Date
    }

    var installVersion: String? {
        component.installVersion(latest: latestVersion, installed: installedVersion)
    }

    func refreshInstalledVersion() async {
        let component = component
        installedVersion = await Task.detached(priority: .utility) {
            component == .geoFiles ? GeoFilesInstaller.installedVersion : SingBoxInstaller.installedVersion
        }.value
    }

    func checkForUpdates(automatic: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        downloadProgress = nil
        defer {
            isBusy = false
            downloadProgress = nil
        }
        await refreshInstalledVersion()
        let key = component.rawValue + ".lastCheckedAt"
        // Same-day skip only when auto-update is off. With auto-update on we must
        // refresh, because this manager does not persist the pending release.
        if automatic, !automaticUpdates, let checked = defaults.object(forKey: key) as? Date,
           Calendar.current.isDate(checked, inSameDayAs: Date()) { return }
        hasError = false
        status = "正在检查更新…"
        do {
            let fetched = try await ComponentRelease.fetch(for: component)
            release = fetched
            latestVersion = try fetched.version(for: component)
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt, forKey: key)
            let needsAdaptation = component == .singBox && latestVersion.map {
                $0 != SingBoxInstaller.approvedVersion && XrayInstaller.isVersion($0, atLeast: SingBoxInstaller.approvedVersion)
            } == true
            if needsAdaptation {
                status = "已验证版本 \(SingBoxInstaller.approvedVersion)；上游新版本需随应用适配后开放。"
            } else if let version = installVersion {
                status = automaticUpdates
                    ? "检查完成：发现可用更新 \(version)，正在自动安装…"
                    : "检查完成：发现可用更新 \(version)，请点「更新」安装。"
            } else if let latest = latestVersion {
                status = "检查完成：已是最新版本 \(latest)。"
            } else {
                status = "检查完成：已是最新版本。"
            }
            if automaticUpdates, installVersion != nil { await installSelectedRelease() }
        } catch {
            hasError = true
            status = "检查更新失败：\(error.localizedDescription)。可重试。"
        }
    }

    func update() async {
        guard !isBusy, installVersion != nil else { return }
        isBusy = true
        hasError = false
        defer {
            isBusy = false
            downloadProgress = nil
        }
        await installSelectedRelease()
    }

    private func installSelectedRelease() async {
        let mirror = XrayInstaller.preferredDownloadMirror.statusLabel
        let target = installVersion.map { " \($0)" } ?? ""
        downloadProgress = 0
        status = "正在通过 \(mirror) 下载\(component.title)\(target)…"
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self else { return }
                self.downloadProgress = fraction
                let percent = Int((fraction * 100).rounded())
                self.status = fraction < 1
                    ? "正在通过 \(mirror) 下载\(self.component.title)\(target)… \(percent)%"
                    : "正在校验并安装\(self.component.title)\(target)…"
            }
        }
        do {
            switch component {
            case .singBox:
                try await SingBoxInstaller.installApprovedRelease(onProgress: onProgress)
            case .geoFiles:
                guard let release else { return }
                try await GeoFilesInstaller.install(release, onProgress: onProgress)
            }
            downloadProgress = nil
            await refreshInstalledVersion()
            status = "更新完成，下次连接或测试时生效。"
        } catch {
            downloadProgress = nil
            hasError = true
            status = "更新失败：\(error.localizedDescription)。原有文件保留，可重试。"
        }
    }
}
