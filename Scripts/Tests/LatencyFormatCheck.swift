import Foundation

@main
struct LatencyFormatCheck {
    static func main() {
        assert(LatencyFormat.display(nil) == "—")
        assert(LatencyFormat.display(0) == "0 ms")
        assert(LatencyFormat.display(9) == "9 ms")
        assert(LatencyFormat.display(10) == "10 ms")
        assert(LatencyFormat.display(11) == "11 ms")
        assert(LatencyFormat.display(99) == "99 ms")
        assert(LatencyFormat.display(100) == "100 ms")
        assert(LatencyFormat.display(101) == "0.10 秒")
        assert(LatencyFormat.display(125) == "0.12 秒")
        assert(LatencyFormat.display(1_000) == "1.00 秒")
        assert(LatencyFormat.display(99_999) == "100.0 秒")
        assert(LatencyFormat.display(100_000) == "100.0 秒")
        assert(LatencyFormat.display(100_100) == "100.1 秒")
        assert(LatencyFormat.display(Int?.some(500)) == "0.50 秒")
        assert(LatencyFormat.seconds(500) == "0.50 秒")
        print("Latency format checks passed")
    }
}
