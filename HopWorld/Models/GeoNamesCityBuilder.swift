import Foundation
import Darwin

/// Streaming conversion keeps the large alternate-name table out of memory and out of the app bundle.
enum GeoNamesCityBuilder {
    private struct Record {
        var country: String
        var admin: String
        var latitude: Double
        var longitude: Double
        var primary: Set<String>
        var aliases: Set<String> = []
        var chinese: String?
        var rank = -1
    }

    static func build(in directory: URL) throws -> ChineseCityCatalog {
        var records: [Int: Record] = [:]
        try lines(in: directory.appendingPathComponent("cities500.zip"), member: "cities500.txt") { f in
            guard f.count == 19, f[6] == "P", let id = Int(f[0]),
                  let lat = Double(f[4]), let lon = Double(f[5]), ChineseCityCatalog.validCoordinates(lat, lon) else {
                throw CityLibraryError.invalidData
            }
            let chinese = ["CN", "TW", "HK", "MO"].contains(f[8]) ? ChineseCityCatalog.chineseName(f[1]) : nil
            records[id] = Record(country: f[8], admin: f[10], latitude: lat, longitude: lon,
                                 primary: Set([f[1], f[2]].map(ChineseCityCatalog.key)), chinese: chinese)
        }
        guard !records.isEmpty else { throw CityLibraryError.invalidData }
        let priorities = ["zh-CN": 4, "zh-Hans": 4, "zh": 3, "zh-TW": 2, "zh-Hant": 2, "zh-HK": 1]
        let excluded: Set<String> = ["link", "post", "iata", "icao", "faac", "wkdt", "abbr"]
        try lines(in: directory.appendingPathComponent("alternateNamesV2.zip"), member: "alternateNamesV2.txt") { f in
            guard f.count >= 8, let id = Int(f[1]), records[id] != nil, f[6] != "1", f[7] != "1" else { return }
            let alias = ChineseCityCatalog.key(f[3])
            if !alias.isEmpty, !excluded.contains(f[2]),
               alias.unicodeScalars.allSatisfy({ $0.isASCII }) || alias.unicodeScalars.contains(where: { (0x400...0x52F).contains($0.value) }) {
                records[id]?.aliases.insert(alias)
            }
            if f[2] == "en", f[4] == "1" { records[id]?.primary.insert(alias) }
            if let priority = priorities[f[2]], let name = ChineseCityCatalog.chineseName(f[3]) {
                let rank = priority * 4 + (f[4] == "1" ? 2 : 0) + (f[5] == "1" ? 0 : 1)
                if rank > records[id]!.rank { records[id]?.chinese = name; records[id]?.rank = rank }
            }
        }
        // GeoNames has no Chinese alternate for Zelenograd; verified at vtbreg.ru/cn/company/feedback/.
        if records[463829] != nil { records[463829]?.chinese = "泽列诺格勒" }
        var cities: [ChineseCityCatalog.City] = []
        for (id, record) in records {
            try Task.checkCancellation()
            guard let chinese = record.chinese else { continue }
            cities.append(.init(geonameID: id, countryCode: record.country, admin1: record.admin,
                aliases: record.aliases.union(record.primary).sorted(), primaryNames: record.primary.sorted(),
                nameChinese: chinese, latitude: record.latitude, longitude: record.longitude))
        }
        guard !cities.isEmpty else { throw CityLibraryError.invalidData }
        var regions: [String: [String]] = [:]
        let used = Set(cities.map { "\($0.countryCode).\($0.admin1)" })
        let regionData = try Data(contentsOf: directory.appendingPathComponent("admin1CodesASCII.txt"))
        guard regionData.count < 8 * 1024 * 1024, let text = String(data: regionData, encoding: .utf8) else {
            throw CityLibraryError.invalidData
        }
        for line in text.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            if f.count >= 3, used.contains(f[0]) {
                regions[f[0]] = [f[1], f[2], String(f[0].split(separator: ".").last ?? "")].map(ChineseCityCatalog.key)
            }
        }
        let version = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return ChineseCityCatalog(cities: cities.sorted { $0.geonameID < $1.geonameID }, regions: regions, version: String(version))
    }

    private static func lines(in archive: URL, member: String, consume: ([String]) throws -> Void) throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, member]
        let output = Pipe()
        let errors = ProcessOutputCapture(capacity: 4096)
        process.standardOutput = output
        process.standardError = errors.pipe
        var launched = false
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            if launched { process.waitUntilExit() }
            errors.finish()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        launched = true
        try output.fileHandleForWriting.close()
        guard let stream = fdopen(dup(output.fileHandleForReading.fileDescriptor), "r") else { throw CityLibraryError.invalidData }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        var total = 0
        defer { free(buffer); fclose(stream) }
        while true {
            try Task.checkCancellation()
            let length = getline(&buffer, &capacity, stream)
            if length < 0 { break }
            total += length
            guard total <= 3_000_000_000, length < 1024 * 1024, let buffer,
                  let line = String(bytes: UnsafeRawBufferPointer(start: buffer, count: length), encoding: .utf8) else {
                throw CityLibraryError.invalidData
            }
            try consume(line.trimmingCharacters(in: .newlines).components(separatedBy: "\t"))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, total > 0 else { throw CityLibraryError.invalidData }
    }
}
