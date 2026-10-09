import Foundation

struct XrayTrafficSnapshot: Sendable {
    var uploadBytes: Int64 = 0
    var downloadBytes: Int64 = 0
}

enum XrayStatsClient {
    /// Query user traffic across system/TUN and application proxy inbounds.
    /// Exclude API polling and connection probes; totals are since xray start.
    static func queryInboundTraffic(apiPort: Int = XrayConfigBuilder.apiPort, binaryURL: URL? = nil) async -> XrayTrafficSnapshot? {
        guard let binary = binaryURL ?? XrayProcessManager.resolveBinaryURL(), !Task.isCancelled else { return nil }
        guard let result = try? await ProcessRunner.run(
            executable: binary, arguments: [
                    "api", "statsquery",
                    "--server=127.0.0.1:\(apiPort)",
                    "-timeout", "2"
                ], timeout: 3
        ), result.status == 0, !result.timedOut, !result.cancelled else { return nil }
        return parse(result.output)
    }

    static func parse(_ data: Data) -> XrayTrafficSnapshot? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stats = json["stat"] as? [[String: Any]]
        else { return nil }

        var upload: Int64 = 0
        var download: Int64 = 0
        let interesting = ["socks-in", "http-in", "application-in"]

        for item in stats {
            guard let name = item["name"] as? String else { continue }
            let value: Int64 = {
                if let n = item["value"] as? Int64 { return n }
                if let n = item["value"] as? Int { return Int64(n) }
                if let s = item["value"] as? String, let n = Int64(s) { return n }
                if let n = item["value"] as? Double { return Int64(n) }
                return 0
            }()

            guard interesting.contains(where: { name.contains("inbound>>>\($0)>>>") }) else { continue }
            if name.hasSuffix(">>>uplink") {
                upload += value
            } else if name.hasSuffix(">>>downlink") {
                download += value
            }
        }

        return XrayTrafficSnapshot(uploadBytes: upload, downloadBytes: download)
    }
}
