import Foundation

/// Shared status/country × subscription filters for 节点 and 测试中心.
enum NodeListFilter {
    enum Scope: Hashable {
        case all
        case favorites
        case available
        case untested
        case unavailable
        case failed
        case country(String)
    }

    enum Source: Hashable {
        case all
        case subscription(UUID)
        case manual
        case namedSource(String)
    }

    static func encode(scope: Scope, source: Source) -> String {
        "\(encodeScope(scope))@@\(encodeSource(source))"
    }

    static func decode(_ raw: String) -> (scope: Scope, source: Source) {
        if let range = raw.range(of: "@@") {
            let scopeRaw = String(raw[..<range.lowerBound])
            let sourceRaw = String(raw[range.upperBound...])
            return (
                decodeScope(scopeRaw) ?? .all,
                decodeSource(sourceRaw) ?? .all
            )
        }

        // Legacy single-token: status/country → scope; subscription/manual → source.
        switch raw {
        case "all":
            return (.all, .all)
        case "favorites", "available", "untested", "unavailable", "failed":
            return (decodeScope(raw) ?? .all, .all)
        case "manual":
            return (.all, .manual)
        default:
            if raw.hasPrefix("country:") {
                return (decodeScope(raw) ?? .all, .all)
            }
            if raw.hasPrefix("subscription:") || raw.hasPrefix("named:") {
                return (.all, decodeSource(raw) ?? .all)
            }
            return (.all, .all)
        }
    }

    static func encodeScope(_ value: Scope) -> String {
        switch value {
        case .all: return "all"
        case .favorites: return "favorites"
        case .available: return "available"
        case .untested: return "untested"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        case .country(let code): return "country:\(code)"
        }
    }

    static func encodeSource(_ value: Source) -> String {
        switch value {
        case .all: return "all"
        case .manual: return "manual"
        case .subscription(let id): return "subscription:\(id.uuidString)"
        case .namedSource(let name): return "named:\(name)"
        }
    }

    static func decodeScope(_ raw: String) -> Scope? {
        switch raw {
        case "all": return .all
        case "favorites": return .favorites
        case "available": return .available
        case "untested": return .untested
        case "unavailable": return .unavailable
        case "failed": return .failed
        default:
            if raw.hasPrefix("country:") {
                let code = String(raw.dropFirst("country:".count))
                return code.isEmpty ? nil : .country(code)
            }
            return nil
        }
    }

    static func decodeSource(_ raw: String) -> Source? {
        switch raw {
        case "all": return .all
        case "manual": return .manual
        default:
            if raw.hasPrefix("subscription:"),
               let id = UUID(uuidString: String(raw.dropFirst("subscription:".count))) {
                return .subscription(id)
            }
            if raw.hasPrefix("named:") {
                let name = String(raw.dropFirst("named:".count))
                return name.isEmpty ? nil : .namedSource(name)
            }
            return nil
        }
    }
}
