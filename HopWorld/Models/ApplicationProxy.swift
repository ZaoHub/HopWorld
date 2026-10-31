import Foundation

/// Match canonical executable paths, never a loose process name (e.g. “Helper”).
struct ProxyApplication: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var name: String
    var isBundle: Bool
    var id: String { path }

    var isClaude: Bool {
        let url = URL(fileURLWithPath: path)
        if url.pathComponents.contains(where: { $0.caseInsensitiveCompare("Claude.app") == .orderedSame }) {
            return true
        }
        let bundleName = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return bundleName?.caseInsensitiveCompare("Claude") == .orderedSame
            || (!isBundle && url.lastPathComponent.caseInsensitiveCompare("claude") == .orderedSame)
    }

    init(url: URL) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let bundle = canonical.pathExtension.lowercased() == "app"
        var directory: ObjCBool = false
        guard canonical.isFileURL,
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory),
              bundle ? (Bundle(url: canonical)?.executableURL != nil) :
                (!directory.boolValue && FileManager.default.isExecutableFile(atPath: canonical.path)) else {
            throw ApplicationProxyError.invalid("请选择有效的 .app 或可执行文件。")
        }
        path = canonical.path
        name = canonical.deletingPathExtension().lastPathComponent
        isBundle = bundle
    }

    func validate() throws {
        let checked = try ProxyApplication(url: URL(fileURLWithPath: path))
        guard checked.path == path, checked.isBundle == isBundle else {
            throw ApplicationProxyError.invalid("应用路径已改变，请重新添加：\(name)")
        }
    }

    var pathRegex: String {
        // Go/RE2 literals: escape only characters supported by both RE2 and ICU.
        let special = Set("\\.+*?()|[]{}^$")
        let literal = path.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        return "^" + literal + (isBundle ? "/Contents/.*$" : "$")
    }
}

enum ApplicationProxyError: LocalizedError {
    case invalid(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .failed(let message): return message
        }
    }
}
