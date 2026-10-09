import Foundation

/// 分享链接 `fm=`（Xray FinalMask）的校验与序列化。
enum FinalMaskCodec {
    static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }
        return trimmed
    }

    static func isPresent(on node: ProxyNode) -> Bool {
        normalize(node.finalMaskJSON) != nil
    }

    /// 写入 `streamSettings.finalmask`；保留分享链接原始 `lengths`/`delays` 语义（需 Xray ≥ 26.9）。
    static func jsonObject(from node: ProxyNode) -> Any? {
        guard let raw = normalize(node.finalMaskJSON),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
