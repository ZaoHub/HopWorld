import Foundation

enum GitHubFileDownloader {
    static let folderDefaultsKey = "githubDownload.folder"
    static let partialPrefix = "HopWorld-dl-"

    enum Failure: LocalizedError {
        case invalidURL
        case http(Int)
        case empty
        case unwritableFolder

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "请填写 https 的 GitHub 文件地址"
            case .http(let code): return "下载失败：HTTP \(code)"
            case .empty: return "下载内容为空"
            case .unwritableFolder: return "所选文件夹不可写，请换一个位置（含已挂载的外置硬盘）"
            }
        }
    }

    static func canonicalURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              !url.path.isEmpty, url.path != "/" else {
            throw Failure.invalidURL
        }
        return url
    }

    static func filename(for url: URL) -> String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let cleaned = name.filter { !$0.isWhitespace && $0 != "/" }
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// 记住的文件夹仍在（含外置盘已挂载）时用它，否则回到「下载」。
    static func resolvedFolder(storedPath: String?) -> URL {
        if let storedPath {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: storedPath, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: storedPath, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func savedFolder(defaults: UserDefaults = .standard) -> URL {
        resolvedFolder(storedPath: defaults.string(forKey: folderDefaultsKey))
    }

    static func remember(folder: URL, defaults: UserDefaults = .standard) {
        defaults.set(folder.path, forKey: folderDefaultsKey)
    }

    static func partialFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(partialPrefix + UUID().uuidString)
    }

    /// 取消后留下的半成品。继续下载不会接着这些文件，清掉后把这句话给用户看。
    static func sweepAbandonedDownloads(in directory: URL? = nil) -> String? {
        let directory = directory ?? FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        let leftovers = files.filter { $0.lastPathComponent.hasPrefix(partialPrefix) }
        guard !leftovers.isEmpty else { return nil }
        var removed = 0
        var bytes: Int64 = 0
        for file in leftovers {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
                bytes += size
            } catch {}
        }
        guard removed > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "已清除上次取消留下的临时文件 \(removed) 个（\(size)）。继续下载不会接着上次的文件，本次从头下载。"
    }

    static func download(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let writer = PartialDownload(destination: destination, onProgress: onProgress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: writer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await writer.run(url, session: session)
    }

    /// 临时文件常在系统盘，外置硬盘需要复制而不是移动。
    static func save(temporary: URL, to directory: URL, filename: String) throws -> URL {
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw Failure.unwritableFolder }
        let destination = destination(for: filename, in: directory)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try FileManager.default.copyItem(at: temporary, to: destination)
            try? FileManager.default.removeItem(at: temporary)
        }
        return destination
    }

    static func destination(for filename: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for index in 2...99 {
            let candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    private static let allowedHosts: Set<String> = [
        "github.com", "www.github.com",
        "raw.githubusercontent.com", "objects.githubusercontent.com",
        "codeload.github.com", "release-assets.githubusercontent.com"
    ]
}

private final class PartialDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var expected: Int64 = 0
    private var count: Int64 = 0
    private var status = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(_ url: URL, session: URLSession) async throws {
        handle = try FileHandle(forWritingTo: destination)
        let task = session.dataTask(with: url)
        self.task = task
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        try? handle?.close()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        expected = response.expectedContentLength
        completionHandler((200...299).contains(status) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        count += Int64(data.count)
        let fraction = expected > 0 ? min(1, Double(count) / Double(expected)) : 0
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let outcome: Result<Void, Error>
        if let error {
            outcome = .failure(error)
        } else if !(200...299).contains(status) {
            outcome = .failure(GitHubFileDownloader.Failure.http(status))
        } else if count == 0 {
            outcome = .failure(GitHubFileDownloader.Failure.empty)
        } else {
            outcome = .success(())
        }
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }
}
