import Foundation

enum LatencyFormat {
    /// 内部仍存毫秒；界面统一显示为秒。
    static func seconds(_ milliseconds: Int) -> String {
        let value = Double(milliseconds) / 1000
        if value >= 10 {
            return String(format: "%.1f 秒", value)
        }
        return String(format: "%.2f 秒", value)
    }

    static func seconds(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return seconds(milliseconds)
    }
}
