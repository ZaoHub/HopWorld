import Foundation
import CryptoKit

enum SingBoxInstaller {
    static let version = "1.14.2"
    #if arch(arm64)
    static let architecture = "arm64"
    static let archiveSHA256 = "925c5382eca8492b0150f868a6db20b18290a38700e621724b3703fd453e032d"
    #else
    static let architecture = "amd64"
    static let archiveSHA256 = "b0bfb0dc70a5fc708710b9f5ea98b9ee76d40fa4169928d25d73edc4331df2fe"
    #endif

    static func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// Always extract from a hash-verified release archive; never elevate an
    /// arbitrary binary found on PATH or trust a user-writable hash receipt.
    static func prepare(in directory: URL) async throws -> URL {
        let folder = "sing-box-\(version)-darwin-\(architecture)"
        let cache = XrayInstaller.supportDirectory.appendingPathComponent(folder + ".tar.gz")
        if (try? digest(cache)) != archiveSHA256 {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 120
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let url = URL(string: "https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(folder).tar.gz")!
            let (download, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, try digest(download) == archiveSHA256 else {
                throw ApplicationProxyError.failed("sing-box 下载失败或 SHA-256 校验不符，未启动管理员进程。")
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: download).write(to: cache, options: .atomic)
        }
        // Copy the validated bytes first, then verify that private snapshot to
        // close the cache replacement race before archive extraction.
        let archive = directory.appendingPathComponent("release.tar.gz")
        try Data(contentsOf: cache).write(to: archive, options: .atomic)
        guard try digest(archive) == archiveSHA256 else { throw ApplicationProxyError.failed("核心缓存校验失败。") }
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", directory.path, "\(folder)/sing-box", "\(folder)/LICENSE"], timeout: 20)
        guard result.status == 0, !result.timedOut, !result.cancelled else {
            throw ApplicationProxyError.failed("解压 sing-box 失败。")
        }
        return directory.appendingPathComponent(folder).appendingPathComponent("sing-box")
    }
}
