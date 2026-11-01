import Foundation

/// 从 GitHub Releases 检查跃界应用是否有更新（仅检测，不安装）。
@MainActor
final class AppReleaseChecker: ObservableObject {
    static let repository = "ZaoHub/HopWorld"
    static let homepageURL = URL(string: "https://zaohub.github.io/HopWorld/")!

    @Published private(set) var newerVersion: String?

    private var didCheck = false

    func checkIfNeeded(currentVersion: String) async {
        guard !didCheck else { return }
        didCheck = true
        do {
            let remote = try await Self.fetchLatestVersion()
            if Self.isNewer(remote, than: currentVersion) {
                newerVersion = remote
            }
        } catch {
            // 关于页静默失败：网络或 API 不可用时不打扰。
        }
    }

    static func normalizedVersion(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
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
