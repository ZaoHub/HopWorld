#!/usr/bin/env python3
"""Exercise production country parsing and its repeated UI lookup workload."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "HopWorld/Services/Country/CountryResolver.swift"
fixture = r'''
import Foundation

struct ProxyNode {
    var name: String
    var countryCode: String?
    var countryName: String?
    var pendingRemoval = false
}
struct CountryGroup {
    var code: String
    var name: String
    var flag: String
    var nodes: [ProxyNode]
}
@main struct Check {
    static func main() throws {
        let cases: [(String, String?)] = [
            ("🇭🇰 香港 01", "HK"), ("[JP] Tokyo", "JP"), ("(DE) 02", "DE"),
            ("/GB/ 03", "GB"), ("|US| 04", "US"), ("CA-05", "CA"),
            ("PARIS", "FR"), ("CHINA", "CN"), ("Singapore", "SG"),
            ("United States", "US"), ("United+States", nil), ("mystery host 9123", nil)
        ]
        for _ in 0..<3 {
            for (name, expected) in cases {
                precondition(CountryResolver.resolve(fromName: name)?.code == expected, name)
            }
        }
        var node = ProxyNode(name: "unknown destination")
        precondition(CountryResolver.effectiveCode(for: node) == "XX")
        node.name = "🇫🇷 Paris"
        precondition(CountryResolver.effectiveCode(for: node) == "FR", "Rename must not use a stale result")
        node.countryCode = "de"
        node.countryName = "德国"
        precondition(CountryResolver.effectiveCountry(for: node).code == "DE", "Stored exit country must win")
        let names = (0..<1111).map { cases[$0 % cases.count].0 + " node-\($0)" }
        let nodes = names.map { ProxyNode(name: $0) }
        let expected = names.indices.map { cases[$0 % cases.count].1 ?? "XX" }
        let start = Date()
        let resolved = nodes.map { CountryResolver.effectiveCode(for: $0) }
        let cold = Date().timeIntervalSince(start)
        precondition(resolved == expected)
        let warmStart = Date()
        for _ in 0..<10 {
            precondition(nodes.map { CountryResolver.effectiveCode(for: $0) } == expected)
            precondition(CountryResolver.group(nodes).reduce(0) { $0 + $1.nodes.count } == nodes.count)
        }
        let warm = Date().timeIntervalSince(warmStart)
        // Memory-pressure eviction and concurrent callers must preserve pure lookup semantics.
        for index in 0..<9000 { _ = CountryResolver.resolve(fromName: "unlisted \(index)") }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let item = cases[index % cases.count]
            precondition(CountryResolver.resolve(fromName: item.0)?.code == item.1)
        }
        print("PASS: flags, ISO tokens, keywords, unknown names, rename, metadata precedence, grouping and concurrent lookups")
        print(String(format: "BENCH 1111 nodes: cold %.3f ms; 10 repeated lookup/group passes %.3f ms", cold * 1000, warm * 1000))
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-country-check-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    swift.write_text(fixture)
    binary = directory / "Check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
