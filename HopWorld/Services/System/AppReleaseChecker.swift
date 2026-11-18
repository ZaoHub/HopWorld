import Foundation

/// 从 GitHub Releases 检查跃界应用是否有更新（仅检测应用，不安装、不查组件）。
@MainActor
final class AppReleaseChecker: ObservableObject {
    static let repository = "ZaoHub/HopWorld"
    nonisolated static let releasesURL = URL(string: "https://github.com/ZaoHub/HopWorld/releases/latest")!

    @Published private(set) var newerVersion: String?
    @Published private(set) var notice: String?
    @Published private(set) var isChecking = false

    private var didCheck = false

    func checkIfNeeded(currentVersion: String) async {
        guard !didCheck else { return }
        didCheck = true
        await performCheck(currentVersion: currentVersion, userInitiated: false)
    }

    func check(currentVersion: String) async {
        await performCheck(currentVersion: currentVersion, userInitiated: true)
    }

    private func performCheck(currentVersion: String, userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if userInitiated { notice = nil }
        guard await LabUtilityProcess.allowInternet(userInitiated: userInitiated) else {
            if userInitiated { notice = "当前无网络" }
            return
        }
        do {
            let remote = try await Self.fetchLatestVersion()
            if Self.isNewer(remote, than: currentVersion) {
                newerVersion = remote
                notice = nil
            } else {
                newerVersion = nil
                if userInitiated { notice = "已是最新" }
            }
        } catch {
            // 打开关于页时静默失败；只有点「检测更新」才提示。
            if userInitiated { notice = "检测失败" }
        }
    }

    nonisolated static func normalizedVersion(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let remote = XrayInstaller.versionParts(normalizedVersion(candidate)),
              let local = XrayInstaller.versionParts(normalizedVersion(current)) else {
            return false
        }
        return local.lexicographicallyPrecedes(remote)
    }

    private static func fetchLatestVersion() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HopWorld", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw URLError(.cannotParseResponse)
        }
        let version = normalizedVersion(release.tag_name)
        guard XrayInstaller.versionParts(version) != nil else {
            throw URLError(.cannotParseResponse)
        }
        return version
    }
}
