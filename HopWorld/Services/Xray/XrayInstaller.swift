import Foundation

enum XrayInstaller {
    static let preferredVersion = "26.9.9"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HopWorld", isDirectory: true)
    }

    static var supportBinaryURL: URL {
        supportDirectory.appendingPathComponent("xray")
    }

    private static var versionCache: [String: (mtime: Date?, version: String?)] = [:]

    /// 确保本机有 **preferredVersion** 的 xray（缺失或过旧则下载到 Application Support）。
    @discardableResult
    static func ensureInstalled() async throws -> URL {
        if let existing = XrayProcessManager.resolveBinaryURL(),
           version(of: existing) == preferredVersion,
           assetDirectory(for: existing) != nil {
            return existing
        }

        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try await downloadOfficialRelease(to: supportBinaryURL)
        versionCache.removeValue(forKey: supportBinaryURL.path)

        guard FileManager.default.isExecutableFile(atPath: supportBinaryURL.path) else {
            throw XrayProcessError.binaryMissing
        }
        guard assetDirectory(for: supportBinaryURL) != nil else {
            throw XrayProcessError.startFailed("缺少 geoip.dat/geosite.dat 分流数据，请检查网络后重试安装。")
        }
        return supportBinaryURL
    }

    static func assetDirectory(for binary: URL) -> URL? {
        let candidates = [supportDirectory, binary.deletingLastPathComponent(), Bundle.main.resourceURL].compactMap { $0 }
        return candidates.first { directory in
            ["geoip.dat", "geosite.dat"].allSatisfy { name in
                let url = directory.appendingPathComponent(name)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return size > 0 && FileManager.default.isReadableFile(atPath: url.path)
            }
        }
    }

    static func version(of url: URL) -> String? {
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

    private static func downloadOfficialRelease(to destination: URL) async throws {
        let arch: String
        #if arch(arm64)
        arch = "arm64-v8a"
        #else
        arch = "64"
        #endif

        let version = preferredVersion
        let zipName = "Xray-macos-\(arch).zip"
        guard let url = URL(string: "https://github.com/XTLS/Xray-core/releases/download/v\(version)/\(zipName)") else {
            throw XrayProcessError.startFailed("无效的下载地址")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (tempURL, response) = try await session.download(from: url)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw XrayProcessError.startFailed("下载 xray 失败：HTTP \(http.statusCode)")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HopWorld-xray-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let zipURL = workDir.appendingPathComponent(zipName)
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: zipURL)

        let extractDir = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await unzip(zipURL, to: extractDir)

        guard let binary = findXrayBinary(in: extractDir) else {
            throw XrayProcessError.startFailed("压缩包中未找到 xray")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: binary, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        await clearQuarantine(at: destination)

        // 规则代理依赖这两个文件；缺失时明确失败，不能静默降级为全代理。
        for name in ["geoip.dat", "geosite.dat"] {
            let src = extractDir.appendingPathComponent(name)
            let data = try Data(contentsOf: src)
            guard !data.isEmpty else { throw XrayProcessError.startFailed("规则数据为空：\(name)") }
            try data.write(to: supportDirectory.appendingPathComponent(name), options: .atomic)
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
            throw XrayProcessError.startFailed("解压失败或超时：\(String(decoding: result.output.suffix(500), as: UTF8.self))")
        }
    }

    private static func clearQuarantine(at url: URL) async {
        _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", url.path], timeout: 3)
    }
}
