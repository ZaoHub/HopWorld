import Foundation

enum LatencyFormat {
    /// 延迟不超过 0.10 秒时显示毫秒，超过时显示秒。
    static func display(_ milliseconds: Int) -> String {
        if milliseconds <= 100 {
            return "\(milliseconds) ms"
        }
        return seconds(milliseconds)
    }

    static func display(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return display(milliseconds)
    }

    /// 耗时等明确使用秒的显示。
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
