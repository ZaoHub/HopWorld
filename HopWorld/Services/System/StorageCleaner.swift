import AppKit
import Foundation

/// Disk leftovers that are safe to delete: temporary sessions from earlier runs and
/// Xray cores the `current` pointer no longer selects. User data is never listed.
enum StorageCleaner {
    enum Kind: String, CaseIterable, Sendable {
        case temporary, oldCores

        var title: String {
            switch self {
            case .temporary: return "临时运行文件"
            case .oldCores: return "旧版 Xray 核心"
            }
        }

        var detail: String {
            switch self {
            case .temporary: return "测速、TUN、订阅下载，以及取消后留下的 GitHub 下载临时文件。启动时会清理上次的运行垃圾；未下完的下载文件留到你下次下载或在这里确认后再删，并会提醒你。只清理本次启动之前的，正在使用的不受影响。"
            case .oldCores: return "更新后不再使用的 Xray 版本；保留当前使用的核心。"
            }
        }
    }

    struct Category: Identifiable, Sendable {
        let kind: Kind
        let items: [URL]
        let bytes: Int64
        var id: Kind { kind }
    }

    struct Result: Sendable {
        var removed = 0
        var bytes: Int64 = 0
        var failures = 0
    }

    private static let temporaryPrefixes = [
        "hopworld-singbox-", "hopworld-tun-", "HopWorld-batch-", "HopWorld-subscription-", "HopWorld-runtime-"
    ]
    private static let remindedDownloadPrefix = GitHubFileDownloader.partialPrefix

    static func scan() -> [Category] {
        Kind.allCases.map { kind in
            let items = candidates(for: kind)
            return Category(kind: kind, items: items, bytes: items.reduce(0) { $0 + allocatedSize(of: $1) })
        }
    }

    /// Earlier runs exit without removing their session directories; sweep them once at launch.
    static func cleanTemporaryLeftovers() -> Result {
        // Another running copy (e.g. an Xcode build beside the installed app) may still use them.
        guard let bundleID = Bundle.main.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count <= 1 else { return Result() }
        let items = candidates(for: .temporary).filter { !$0.lastPathComponent.hasPrefix(remindedDownloadPrefix) }
        return clean([Category(kind: .temporary, items: items, bytes: 0)])
    }

    static func clean(_ categories: [Category]) -> Result {
        var result = Result()
        for category in categories {
            // Re-check against the live state so nothing selected after the scan is removed.
            let allowed = Set(candidates(for: category.kind).map(\.path))
            for item in category.items where allowed.contains(item.path) {
                let size = allocatedSize(of: item)
                do {
                    try FileManager.default.removeItem(at: item)
                    result.removed += 1
                    result.bytes += size
                } catch {
                    result.failures += 1
                }
            }
        }
        return result
    }

    /// Anything created during this run may still be in use (or a core update being staged).
    private static func candidates(for kind: Kind) -> [URL] {
        let launchDate = NSRunningApplication.current.launchDate ?? Date()
        let predatesLaunch: (URL) -> Bool = { url in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            return created < launchDate
        }
        switch kind {
        case .temporary:
            return contents(of: FileManager.default.temporaryDirectory).filter { url in
                let name = url.lastPathComponent
                let known = temporaryPrefixes.contains(where: name.hasPrefix) || name.hasPrefix(remindedDownloadPrefix)
                return known && predatesLaunch(url)
            }
        case .oldCores:
            let root = XrayInstaller.supportDirectory
            let current = root.appendingPathComponent("current").resolvingSymlinksInPath().path
            // Without a resolvable current core every installed version may be the one in use.
            guard FileManager.default.fileExists(atPath: current) else { return [] }
            return contents(of: root.appendingPathComponent("cores")).filter {
                $0.resolvingSymlinksInPath().path != current && predatesLaunch($0)
            }
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: []
        )) ?? []
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
