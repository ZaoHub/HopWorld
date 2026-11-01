import Foundation
import Combine

enum CityLibraryError: LocalizedError {
    case invalidData
    case downloadFailed
    var errorDescription: String? {
        switch self {
        case .invalidData: return "离线库格式无效或数据不完整，原有离线库已保留。"
        case .downloadFailed: return "GeoNames 下载失败，请稍后重试。"
        }
    }
}

@MainActor final class ChineseCityLibrary: ObservableObject {
    static let shared = ChineseCityLibrary()
    static let didInstall = Notification.Name("ChineseCityLibraryDidInstall")
    @Published private(set) var catalog = ChineseCityCatalog.shared
    @Published private(set) var stage: String?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    var isInstalled: Bool { catalog.cityCount > 0 }
    var isDownloading: Bool { task != nil }

    /// Validate before replacing the installed file so interrupted downloads never erase a working library.
    nonisolated static func install(_ data: Data, at url: URL = ChineseCityCatalog.installedURL) throws -> ChineseCityCatalog {
        guard data.count <= 64 * 1024 * 1024 else { throw CityLibraryError.invalidData }
        let catalog = try ChineseCityCatalog(data: data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        return catalog
    }

    func download() {
        guard task == nil else { return }
        error = nil
        progress = 0
        stage = "准备下载…"
        task = Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HopWorld-Cities-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: directory)
                stage = nil
                progress = nil
                task = nil
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let files = ["cities500.zip", "alternateNamesV2.zip", "admin1CodesASCII.txt"]
                for (offset, file) in files.enumerated() {
                    try Task.checkCancellation()
                    let base = Double(offset) / Double(files.count)
                    let span = 1 / Double(files.count)
                    stage = "下载 GeoNames（\(offset + 1)/\(files.count)）…"
                    progress = base
                    let url = URL(string: "https://download.geonames.org/export/dump/\(file)")!
                    let (temporary, response) = try await XrayInstaller.downloadFile(
                        from: url,
                        timeoutRequest: 60,
                        timeoutResource: 3600
                    ) { fraction in
                        let value = base + span * fraction * 0.92
                        Task { @MainActor in
                            self.progress = value
                        }
                    }
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1024 * 1024 else {
                        throw CityLibraryError.downloadFailed
                    }
                    try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(file))
                    progress = base + span * 0.92
                }
                stage = "生成中文离线库…"
                progress = 0.94
                let worker = Task.detached(priority: .utility) {
                    let data = try GeoNamesCityBuilder.build(in: directory).encodedData()
                    return try Self.install(data)
                }
                let installed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                progress = 1
                ChineseCityCatalog.useInstalled(installed)
                catalog = installed
                error = nil
                NotificationCenter.default.post(name: Self.didInstall, object: nil)
            } catch is CancellationError {
                // A cancelled download keeps the previously installed catalog.
            } catch {
                if !Task.isCancelled {
                    // Keep a clearer message when generation fails after downloads finished.
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Drop a stale failure banner once the installed library is readable again.
    func clearErrorIfInstalled() {
        if isInstalled { error = nil }
    }
}
