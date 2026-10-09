import Foundation

/// Patch encrypted-library JSON so older on-disk snapshots decode after new optional fields are added.
enum LibrarySnapshotMigration {
    static func patchEncryptedLibraryJSON(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if var nodes = root["nodes"] as? [[String: Any]] {
            for index in nodes.indices {
                if nodes[index]["pendingConfigUpdate"] == nil {
                    nodes[index]["pendingConfigUpdate"] = false
                }
            }
            root["nodes"] = nodes
        }

        if var subscriptions = root["subscriptions"] as? [[String: Any]] {
            for index in subscriptions.indices {
                if subscriptions[index]["updateFailureCount"] == nil {
                    subscriptions[index]["updateFailureCount"] = 0
                }
            }
            root["subscriptions"] = subscriptions
        }

        return try JSONSerialization.data(withJSONObject: root, options: [])
    }
}
