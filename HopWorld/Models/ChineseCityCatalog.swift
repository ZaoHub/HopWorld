import Foundation
@preconcurrency import CoreLocation

/// Optional, locally installed GeoNames catalog (CC BY 4.0).
struct ChineseCityCatalog: Sendable {
    struct City: Codable, Sendable {
        var geonameID: Int
        var countryCode: String
        var admin1: String
        var aliases: [String]
        var primaryNames: [String] = []
        var nameChinese: String
        var latitude: Double
        var longitude: Double
    }

    struct Snapshot: Codable {
        var version: String
        var regions: [String: [String]]
        var cities: [City]
    }

    static let installedURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HopWorld/ChineseCities.json")
    private static let storage = CatalogStorage()
    static var shared: ChineseCityCatalog { storage.current() }
    static func useInstalled(_ catalog: ChineseCityCatalog) { storage.replace(with: catalog) }

    private final class CatalogStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var catalog: ChineseCityCatalog?
        func current() -> ChineseCityCatalog {
            lock.lock(); defer { lock.unlock() }
            if let catalog { return catalog }
            let loaded = (try? ChineseCityCatalog.read(from: installedURL)) ?? ChineseCityCatalog(cities: [])
            catalog = loaded
            return loaded
        }
        func replace(with value: ChineseCityCatalog) { lock.lock(); catalog = value; lock.unlock() }
    }

    static func read(from url: URL) throws -> ChineseCityCatalog {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024 else { throw CityLibraryError.invalidData }
        return try ChineseCityCatalog(data: Data(contentsOf: url))
    }

    func encodedData() throws -> Data {
        try JSONEncoder().encode(Snapshot(version: version, regions: regions, cities: cities))
    }

    let version: String
    var cityCount: Int { cities.count }
    private let cities: [City]
    private let regions: [String: [String]]
    private let aliases: [String: [Int]]

    init(data: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard !snapshot.cities.isEmpty, snapshot.cities.count <= 500_000,
              snapshot.cities.allSatisfy({ Self.validCoordinates($0.latitude, $0.longitude)
                  && Self.chineseName($0.nameChinese) != nil && !$0.aliases.isEmpty }) else {
            throw CityLibraryError.invalidData
        }
        self.init(cities: snapshot.cities, regions: snapshot.regions, version: snapshot.version)
    }

    init(cities: [City], regions: [String: [String]] = [:], version: String = "fixture") {
        self.version = version
        self.cities = cities
        self.regions = regions.mapValues { $0.map(Self.key) }
        var index: [String: [Int]] = [:]
        for (offset, city) in cities.enumerated() {
            for alias in Set(city.aliases.map(Self.key)) where !alias.isEmpty {
                index[alias, default: []].append(offset)
            }
        }
        self.aliases = index
    }

    func name(for city: String?, countryCode: String? = nil, region: String? = nil,
              latitude: Double? = nil, longitude: Double? = nil) -> String? {
        guard let city else { return nil }
        let base = Self.baseName(city)
        if let chinese = Self.chineseName(base) { return chinese }
        var matches = (aliases[Self.key(base)] ?? []).map { cities[$0] }
        if let code = countryCode?.uppercased(), !code.isEmpty {
            matches = matches.filter { $0.countryCode == code }
        }
        if let region, !region.isEmpty {
            let regional = matches.filter {
                regions["\($0.countryCode).\($0.admin1)"]?.contains(Self.key(region)) == true
            }
            if !regional.isEmpty { matches = regional }
        }
        if let latitude, let longitude, Self.validCoordinates(latitude, longitude) {
            let nearby = matches.map { ($0, Self.distance(latitude, longitude, $0.latitude, $0.longitude)) }
                .sorted { $0.1 < $1.1 }
            if let first = nearby.first, first.1 <= 50,
               nearby.count == 1 || nearby[1].1 - first.1 > 5 {
                return Self.chineseName(first.0.nameChinese)
            }
        }
        let primary = matches.filter { $0.primaryNames.contains(where: { Self.key($0) == Self.key(base) }) }
        if !primary.isEmpty { matches = primary }
        let names = Set(matches.compactMap { Self.chineseName($0.nameChinese) })
        return names.count == 1 ? names.first : nil
    }

    static func baseName(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s*[（(][^()（）]*[)）]\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func chineseName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
              !value.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }) else { return nil }
        return value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
    }

    static func validCoordinates(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func distance(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        let factor = Double.pi / 180
        let h = pow(sin((c - a) * factor / 2), 2)
            + cos(a * factor) * cos(c * factor) * pow(sin((d - b) * factor / 2), 2)
        return 6371 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}


/// Only unresolved city coordinates are sent to Apple's geocoder, never node IPs or credentials.
actor ChineseCityResolver {
    typealias Lookup = @Sendable (NodeExitMetadata) async -> String?
    static let shared = ChineseCityResolver()
    private let catalog: ChineseCityCatalog?
    private let defaults: UserDefaults?
    private let lookup: Lookup
    private let pacingNanoseconds: UInt64
    private var cache: [String: String]
    private var failures: [String: Date] = [:]
    private var pending: [String: Task<String?, Never>] = [:]
    private var previousLookup: Task<String?, Never>?
    private var generation: UInt = 0
    private static let cacheKey = "ChineseCityNames.v1"

    init(catalog: ChineseCityCatalog? = nil, defaults: UserDefaults? = .standard,
         pacingNanoseconds: UInt64 = 1_000_000_000,
         lookup: @escaping Lookup = { await ChineseCityResolver.appleLookup($0) }) {
        self.catalog = catalog
        self.defaults = defaults
        self.pacingNanoseconds = pacingNanoseconds
        self.lookup = lookup
        self.cache = defaults?.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
    }

    func resolve(_ metadata: NodeExitMetadata,
                 allowingOnline: @escaping @Sendable () async -> Bool = { true }) async -> NodeExitMetadata {
        var result = metadata
        if let name = (catalog ?? .shared).name(for: metadata.city, countryCode: metadata.countryCode, region: metadata.region,
                                   latitude: metadata.latitude, longitude: metadata.longitude) {
            result.localizedCity = name
            return result
        }
        if ChineseCityCatalog.chineseName(metadata.localizedCity) != nil { return result }
        guard !Task.isCancelled, let city = metadata.city, !city.isEmpty,
              let latitude = metadata.latitude, let longitude = metadata.longitude,
              ChineseCityCatalog.validCoordinates(latitude, longitude) else { return result }
        let key = [metadata.countryCode ?? "", metadata.region ?? "", ChineseCityCatalog.baseName(city),
                   String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)]
            .map(ChineseCityCatalog.key).joined(separator: "|")
        if let name = ChineseCityCatalog.chineseName(cache[key]) { result.localizedCity = name; return result }
        if let failure = failures[key], Date().timeIntervalSince(failure) < 600 { return result }
        guard await allowingOnline(), !Task.isCancelled else { return result }
        let requestGeneration = generation
        let task: Task<String?, Never>
        if let existing = pending[key] {
            task = existing
        } else {
            let previous = previousLookup
            let lookup = self.lookup
            let delay = pacingNanoseconds
            task = Task {
                if let previous {
                    _ = await previous.value
                    do { try await Task.sleep(nanoseconds: delay) } catch { return nil }
                }
                guard !Task.isCancelled, await allowingOnline() else { return nil }
                return await Self.withTimeout(metadata, lookup: lookup)
            }
            pending[key] = task
            previousLookup = task
        }
        let name = ChineseCityCatalog.chineseName(await task.value)
        guard requestGeneration == generation else { return result }
        pending.removeValue(forKey: key)
        guard !task.isCancelled, !Task.isCancelled, await allowingOnline() else { return result }
        if let name {
            cache[key] = name
            if cache.count > 2000, let first = cache.keys.first { cache.removeValue(forKey: first) }
            defaults?.set(cache, forKey: Self.cacheKey)
            result.localizedCity = name
        } else {
            failures[key] = Date()
            if failures.count > 2000, let first = failures.keys.first { failures.removeValue(forKey: first) }
        }
        return result
    }

    func cancelPending() {
        generation &+= 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        previousLookup = nil
    }

    private static func withTimeout(_ metadata: NodeExitMetadata, lookup: @escaping Lookup) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await lookup(metadata) }
            group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @MainActor private static func appleLookup(_ metadata: NodeExitMetadata) async -> String? {
        guard await LabUtilityProcess.allowInternet(userInitiated: false) else { return nil }
        guard let latitude = metadata.latitude, let longitude = metadata.longitude else { return nil }
        let geocoder = CLGeocoder()
        return await withTaskCancellationHandler {
            guard let placemark = try? await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude), preferredLocale: Locale(identifier: "zh-Hans")).first else { return nil }
            if let country = metadata.countryCode, country.uppercased() != placemark.isoCountryCode?.uppercased() { return nil }
            return ChineseCityCatalog.chineseName(placemark.locality)
        } onCancel: {
            Task { @MainActor in geocoder.cancelGeocode() }
        }
    }
}
