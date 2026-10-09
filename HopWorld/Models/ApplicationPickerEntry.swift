import Foundation

struct ApplicationPickerEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let bundleIdentifier: String
    var id: String { url.path }

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let fields = [name, url.deletingPathExtension().lastPathComponent, bundleIdentifier, url.path]
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
    }
}
