import XCTest
import Darwin

private actor CityLookupCounter {
    var count = 0
    func record() { count += 1 }
}

final class ChineseCityCatalogTests: XCTestCase {
    private func fixture() -> ChineseCityCatalog {
        ChineseCityCatalog(cities: [
            .init(geonameID: 1, countryCode: "US", admin1: "CA", aliases: ["Twin City"],
                  nameChinese: "甲城", latitude: 37.77, longitude: -122.42),
            .init(geonameID: 2, countryCode: "US", admin1: "IL", aliases: ["Twin City"],
                  nameChinese: "乙城", latitude: 39.8, longitude: -89.65),
            .init(geonameID: 3, countryCode: "CA", admin1: "BC", aliases: ["Twin City"],
                  nameChinese: "丙城", latitude: 49.28, longitude: -123.12)
        ], regions: ["US.CA": ["California", "CA"], "US.IL": ["Illinois", "IL"], "CA.BC": ["British Columbia"]])
    }

    func testCountryAndAdministrativeAreaDisambiguateNames() {
        let catalog = fixture()
        XCTAssertEqual(catalog.name(for: "Twin City", countryCode: "CA"), "丙城")
        XCTAssertEqual(catalog.name(for: "Twin City", countryCode: "us", region: "California"), "甲城")
        XCTAssertEqual(catalog.name(for: "Twin City", countryCode: "US", region: "IL"), "乙城")
        XCTAssertNil(catalog.name(for: "Twin City", countryCode: "GB"))
        XCTAssertNil(catalog.name(for: "Twin City", countryCode: "US"))
        XCTAssertNil(catalog.name(for: "Twin City"))
    }

    func testCoordinatesResolveAmbiguityWithoutPickingDistantPlaces() {
        let catalog = fixture()
        XCTAssertEqual(catalog.name(for: "Twin City", countryCode: "US", latitude: 37.78, longitude: -122.41), "甲城")
        XCTAssertNil(catalog.name(for: "Twin City", countryCode: "US", latitude: 0, longitude: 0))
        XCTAssertNil(catalog.name(for: "Twin City", latitude: .nan, longitude: 20))
    }

    func testCanonicalNameWinsOverAnotherCitysAlternateName() {
        let catalog = ChineseCityCatalog(cities: [
            .init(geonameID: 1, countryCode: "GB", admin1: "", aliases: ["London"], primaryNames: ["London"],
                  nameChinese: "伦敦", latitude: 51.5, longitude: -0.12),
            .init(geonameID: 2, countryCode: "GB", admin1: "", aliases: ["London", "City of London"],
                  primaryNames: ["City of London"], nameChinese: "伦敦金融城", latitude: 51.51, longitude: -0.09)
        ])
        XCTAssertEqual(catalog.name(for: "London (Tower)", countryCode: "GB"), "伦敦")
        XCTAssertEqual(catalog.name(for: "City of London", countryCode: "GB"), "伦敦金融城")
    }

    func testRegionAndCoordinatesTakePrecedenceOverAnotherCitysCanonicalName() {
        let catalog = ChineseCityCatalog(cities: [
            .init(geonameID: 1, countryCode: "US", admin1: "CA", aliases: ["Twin City"],
                  nameChinese: "甲城", latitude: 37.77, longitude: -122.42),
            .init(geonameID: 2, countryCode: "US", admin1: "IL", aliases: ["Twin City"], primaryNames: ["Twin City"],
                  nameChinese: "乙城", latitude: 39.8, longitude: -89.65)
        ], regions: ["US.CA": ["California"], "US.IL": ["Illinois"]])
        XCTAssertEqual(catalog.name(for: "Twin City", countryCode: "US", region: "California"), "甲城")
        XCTAssertEqual(catalog.name(for: "Twin City", countryCode: "US", latitude: 37.77, longitude: -122.42), "甲城")
    }

    func testUnresolvedNamesUseRawValueAndCachedNamesAreUsed() {
        XCTAssertEqual(ExitMetadataLocalization.city("Unlisted test locality", countryCode: "US"), "Unlisted test locality")
        XCTAssertEqual(ExitMetadataLocalization.city("Unlisted test locality", countryCode: "US", localizedCity: "测试城"), "测试城")
        XCTAssertEqual(ExitMetadataLocalization.city("New York", countryCode: "US", localizedCity: "约克"), "约克",
                       "A name resolved with region/coordinates must take precedence over a less specific UI lookup")
        XCTAssertEqual(ExitMetadataLocalization.city("Unlisted test locality", localizedCity: "English only"), "Unlisted test locality")
        XCTAssertEqual(ChineseCityCatalog.chineseName("聖彼得堡"), "圣彼得堡")
        XCTAssertNil(ChineseCityCatalog.chineseName("London 伦敦"))
        XCTAssertThrowsError(try ChineseCityCatalog(data: Data("invalid".utf8)))
    }

    func testOfflineMatchDoesNotCallOnlineService() async {
        let counter = CityLookupCounter()
        let resolver = ChineseCityResolver(catalog: fixture(), defaults: nil, pacingNanoseconds: 0) { _ in
            await counter.record(); return "不应调用"
        }
        let result = await resolver.resolve(NodeExitMetadata(ip: "203.0.113.1", city: "Twin City", countryCode: "CA"))
        XCTAssertEqual(result.localizedCity, "丙城")
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testConcurrentBackgroundRequestsShareOneLookupAndKeepRawName() async {
        let counter = CityLookupCounter()
        let resolver = ChineseCityResolver(catalog: .init(cities: []), defaults: nil, pacingNanoseconds: 0) { _ in
            await counter.record()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return "测试城"
        }
        let metadata = NodeExitMetadata(ip: "203.0.113.1", city: "Unlisted", countryCode: "US", latitude: 37, longitude: -122)
        async let a = resolver.resolve(metadata)
        async let b = resolver.resolve(metadata)
        let (first, second) = await (a, b)
        XCTAssertEqual(first.localizedCity, "测试城")
        XCTAssertEqual(second, first)
        XCTAssertEqual(first.city, "Unlisted")
        let cached = await resolver.resolve(metadata)
        XCTAssertEqual(cached, first)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulLookupCacheSurvivesResolverRecreation() async throws {
        let suite = "HopWorld.CityNames.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = CityLookupCounter()
        let lookup: ChineseCityResolver.Lookup = { _ in await counter.record(); return "测试城" }
        let metadata = NodeExitMetadata(ip: "203.0.113.1", city: "Unlisted", countryCode: "US", latitude: 37, longitude: -122)
        let first = ChineseCityResolver(catalog: .init(cities: []), defaults: defaults, pacingNanoseconds: 0, lookup: lookup)
        _ = await first.resolve(metadata)
        let second = ChineseCityResolver(catalog: .init(cities: []), defaults: defaults, pacingNanoseconds: 0, lookup: lookup)
        let result = await second.resolve(metadata)
        XCTAssertEqual(result.localizedCity, "测试城")
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testFailedOrEnglishLookupDoesNotInventChineseAndIsNotRepeatedImmediately() async {
        let counter = CityLookupCounter()
        let resolver = ChineseCityResolver(catalog: .init(cities: []), defaults: nil, pacingNanoseconds: 0) { _ in
            await counter.record(); return "Unlisted"
        }
        let metadata = NodeExitMetadata(ip: "203.0.113.1", city: "Unlisted", countryCode: "US", latitude: 37, longitude: -122)
        let first = await resolver.resolve(metadata)
        let second = await resolver.resolve(metadata)
        XCTAssertNil(first.localizedCity)
        XCTAssertNil(second.localizedCity)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
        let invalid = NodeExitMetadata(ip: "203.0.113.2", city: "Other", latitude: 91, longitude: 0)
        _ = await resolver.resolve(invalid)
        let afterInvalid = await counter.count
        XCTAssertEqual(afterInvalid, 1)
    }

    func testBackgroundTimeoutCancelsLookupAndAllowsTheNextCity() async {
        let resolver = ChineseCityResolver(catalog: .init(cities: []), defaults: nil, pacingNanoseconds: 0) { metadata in
            if metadata.city == "Slow" {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return nil
            }
            return "测试城"
        }
        let started = Date()
        let timedOut = await resolver.resolve(NodeExitMetadata(ip: "203.0.113.1", city: "Slow", latitude: 37, longitude: -122))
        XCTAssertNil(timedOut.localizedCity)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        let next = await resolver.resolve(NodeExitMetadata(ip: "203.0.113.2", city: "Next", latitude: 38, longitude: -122))
        XCTAssertEqual(next.localizedCity, "测试城")
    }

    func testCachedCityIsRetainedOnlyForUnchangedExitMetadata() {
        let previous = NodeExitMetadata(ip: "203.0.113.1", city: "Unlisted", countryCode: "US", localizedCity: "测试城")
        var refreshed = previous
        refreshed.localizedCity = nil
        XCTAssertEqual(refreshed.retainingKnownDetails(from: previous).localizedCity, "测试城")
        refreshed.ip = "203.0.113.2"
        XCTAssertNil(refreshed.retainingKnownDetails(from: previous).localizedCity)
    }
}

final class NodeExitMetadataTests: XCTestCase {
    private static let catalog = ChineseCityCatalog(cities: [
        .init(geonameID: 1, countryCode: "US", admin1: "CA", aliases: ["Los Angeles"],
              nameChinese: "洛杉矶", latitude: 34, longitude: -118),
        .init(geonameID: 2, countryCode: "GB", admin1: "ENG", aliases: ["London"],
              nameChinese: "伦敦", latitude: 51.5, longitude: -0.12),
        .init(geonameID: 3, countryCode: "US", admin1: "NY", aliases: ["New York"],
              nameChinese: "纽约", latitude: 40.7, longitude: -74),
        .init(geonameID: 463829, countryCode: "RU", admin1: "48", aliases: ["Zelenograd", "Зеленоград"],
              nameChinese: "泽列诺格勒", latitude: 55.98, longitude: 37.18)
    ])
    private func city(_ value: String?, countryCode: String? = nil) -> String {
        ExitMetadataLocalization.city(value, countryCode: countryCode, catalog: Self.catalog)
    }
    private let metadata = NodeExitMetadata(ip: "203.0.113.42", city: "Los Angeles",
                                            networkOperator: "Google LLC", asn: "AS15169", countryCode: "US",
                                            localizedCity: nil)

    func testChineseNamesAndUnknownValues() {
        XCTAssertEqual(city("Los Angeles", countryCode: "US"), "洛杉矶")
        XCTAssertEqual(city(" london ", countryCode: "GB"), "伦敦")
        XCTAssertEqual(city("东京"), "东京")
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("Google LLC"), "谷歌")
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("Microsoft Corporation"), "微软")
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("中国电信"), "中国电信")
        XCTAssertEqual(city(nil), "未知")
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("  "), "未知")
    }

    func testUnrecognizedNamesArePreservedWithoutInventedTranslation() {
        XCTAssertEqual(city("Small Town"), "Small Town")
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("Example Networks"), "Example Networks")
    }

    func testCityDistrictSuffixUsesChineseCityName() {
        for name in ["London (Tower)", " london（Tower） ", "LONDON  (Tower)"] {
            XCTAssertEqual(city(name, countryCode: "GB"), "伦敦")
        }
        XCTAssertTrue(city("New York (Manhattan)", countryCode: "US").hasPrefix("纽约"))
        XCTAssertEqual(city("Los  Angeles", countryCode: "US"), "洛杉矶")
        XCTAssertEqual(city("Small Town (Centre)"), "Small Town (Centre)")
    }

    func testZelenogradAndItsAdministrativeDistrictUseChineseCityName() {
        for name in ["Zelenograd", "Zelenograd (Zelenogradskiy administrativnyy okrug)",
                     " zelenograd（Zelenogradskiy administrativnyy okrug） ", "Зеленоград"] {
            XCTAssertEqual(city(name, countryCode: "RU"), "泽列诺格勒")
        }
    }

    func testOVHLegalNamesUseChineseServiceLabel() {
        for name in ["OVH SAS", "OVH   SAS", "ovh s.a.s.", "OVHcloud", "OVH Hosting, Inc."] {
            XCTAssertEqual(ExitMetadataLocalization.networkOperator(name), "OVH 云服务")
        }
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("OVH SAS Partner"), "OVH SAS Partner")
    }

    func testNetworkHealthExitInfoPrefersLiveConnectionOverSavedMetadata() {
        var node = ProxyNode(name: "未知地区 | TROJAN | 002", protocolType: .trojan, server: "example.com", port: 443)
        node.countryCode = "GB"
        node.exitMetadata = NodeExitMetadata(ip: "198.51.100.1", city: "London", networkOperator: "Example ISP",
                                             asn: "AS64500", networkType: .hosting, countryCode: "GB",
                                             localizedCity: "伦敦")
        var connection = ConnectionState()
        connection.status = .connected
        connection.currentNodeID = node.id
        connection.exitIP = "203.0.113.42"
        connection.exitIPType = .residential
        connection.exitCountry = "美国"
        connection.exitCity = "Los Angeles"
        connection.exitOperator = "Google LLC"
        connection.exitASN = "AS15169"

        let live = NetworkHealthExitInfo.resolve(node: node, connection: connection, catalog: Self.catalog)
        XCTAssertEqual(live.ip, "203.0.113.42")
        XCTAssertEqual(live.networkType, .residential)
        XCTAssertEqual(live.country, "United States（美国）")
        XCTAssertEqual(live.city, "洛杉矶")
        XCTAssertEqual(live.networkOperator, "谷歌")
        XCTAssertEqual(live.asn, "AS15169")
        XCTAssertTrue(live.isCurrentConnection)
        XCTAssertFalse(live.awaitingLive)

        connection.exitCountry = "Lithuania"
        connection.exitCity = "Vilnius"
        let lithuania = NetworkHealthExitInfo.resolve(node: node, connection: connection, catalog: Self.catalog)
        XCTAssertEqual(lithuania.country, "Lithuania（立陶宛）")
        XCTAssertEqual(lithuania.rawCountry, "Lithuania")
        XCTAssertEqual(lithuania.countryCode, "LT")
        XCTAssertEqual(ExitMetadataLocalization.country("Lithuania", showChinese: false), "Lithuania")
        XCTAssertEqual(ExitMetadataLocalization.country("LT", countryCode: "LT"), "Lithuania（立陶宛）")

        connection.exitIP = nil
        connection.exitIPType = nil
        connection.exitCountry = nil
        connection.exitCity = nil
        connection.exitOperator = nil
        connection.exitASN = nil
        let awaiting = NetworkHealthExitInfo.resolve(node: node, connection: connection, catalog: Self.catalog)
        XCTAssertEqual(awaiting.ip, "198.51.100.1")
        XCTAssertEqual(awaiting.city, "伦敦")
        XCTAssertTrue(awaiting.awaitingLive)

        connection.status = .disconnected
        let saved = NetworkHealthExitInfo.resolve(node: node, connection: connection, catalog: Self.catalog)
        XCTAssertEqual(saved.ip, "198.51.100.1")
        XCTAssertEqual(saved.country, "United Kingdom（英国）")
        XCTAssertEqual(saved.networkType, .hosting)
        XCTAssertFalse(saved.isCurrentConnection)
        XCTAssertFalse(saved.awaitingLive)
    }

    func testMetadataSurvivesNodePersistenceAndDoesNotChangeConnectionFingerprint() throws {
        var node = ProxyNode(name: "英国 | VLESS | 006", protocolType: .vless, server: "example.com", port: 443)
        let fingerprint = NodeFingerprint.make(from: node)
        node.exitMetadata = metadata
        let decoded = try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded.exitMetadata, metadata)
        XCTAssertEqual(NodeFingerprint.make(from: decoded), fingerprint)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        json.removeValue(forKey: "exitMetadata")
        let legacy = try JSONDecoder().decode(ProxyNode.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.exitMetadata)
    }

    func testTestResultPreservesExitMetadata() throws {
        var result = NodeTestResult(nodeID: UUID(), configValid: true, success: true)
        result.exitMetadata = metadata
        let decoded = try JSONDecoder().decode(NodeTestResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.exitMetadata, metadata)
    }

    func testNetworkTypeIsCarriedWithNodeMetadataAndOldRecordsStillDecode() throws {
        let info = try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(#"{"ip":"203.0.113.42","risk":{"is_datacenter":true}}"#.utf8)))
        let metadata = try XCTUnwrap(info.nodeMetadata)
        XCTAssertEqual(metadata.networkType, .hosting)
        let decoded = try JSONDecoder().decode(NodeExitMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded.networkType, .hosting)
        let legacy = try JSONDecoder().decode(NodeExitMetadata.self,
            from: Data(#"{"ip":"203.0.113.42","city":"London","asn":"AS16276"}"#.utf8))
        XCTAssertNil(legacy.networkType)
    }

    func testGeoResponseProducesMetadataForItsOwnExitIP() throws {
        let info = try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(#"{"ip":"203.0.113.42","location":{"city":"Los Angeles","country_code":"US"},"isp":{"isp":"Google LLC","asn":"AS15169"}}"#.utf8)))
        XCTAssertEqual(info.nodeMetadata, metadata)
        XCTAssertNil(ExitIPTester.ExitInfo(city: "London").nodeMetadata)
    }

    func testGeoCoordinatesAndRegionAreKeptForCityDisambiguation() throws {
        let info = try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(#"{"ip":"203.0.113.42","location":{"city":"London","country_code":"GB","state":"England","latitude":51.5,"longitude":-0.12}}"#.utf8)))
        let metadata = try XCTUnwrap(info.nodeMetadata)
        XCTAssertEqual(metadata.countryCode, "GB")
        XCTAssertEqual(metadata.region, "England")
        XCTAssertEqual(metadata.latitude, 51.5)
        XCTAssertEqual(metadata.longitude, -0.12)
        XCTAssertEqual(metadata.city, "London")
        XCTAssertNil(metadata.localizedCity)
    }
}

final class DashboardLatencyTests: XCTestCase {
    func testSuccessfulSampleDisplaysCurrentLatency() {
        var state = ConnectionState(status: .connected)
        state.recordLatency(780)
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: 200), "0.78 秒")
    }

    func testFailedSampleKeepsLastSuccessForDisplayButRemainsUnhealthy() {
        var state = ConnectionState(status: .connected)
        state.recordLatency(780)
        state.recordLatency(nil)
        XCTAssertNil(state.latency, "A failed live sample must still reach health checks as failure")
        XCTAssertEqual(state.lastSuccessfulLatency, 780)
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: 200), "0.78 秒（上次）")
        state.recordLatency(nil)
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: nil), "0.78 秒（上次）")
    }

    func testRecoveryReplacesPreviousLatencyAndClearsHistoricalLabel() {
        var state = ConnectionState(status: .connected)
        state.recordLatency(780)
        state.recordLatency(nil)
        state.recordLatency(85)
        XCTAssertEqual(state.lastSuccessfulLatency, 85)
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: nil), "85 ms")
    }

    func testMissingLiveAndSessionMeasurementsUseExplicitHistoricalFallback() {
        let state = ConnectionState(status: .connected)
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: 850), "0.85 秒（上次）")
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: nil), "暂不可测")
    }

    func testNewConnectionCannotReusePreviousSessionsLatency() {
        var state = ConnectionState(status: .connected)
        state.recordLatency(780)
        state.status = .connecting
        state.resetLatency()
        XCTAssertNil(state.latency)
        XCTAssertNil(state.lastSuccessfulLatency)
        // 连接时不再做连通性验证；可显示测速延迟，但不能沿用上一段会话的成功延迟。
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: 200), "200 ms")
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: nil), "连接中")
        state.status = .connected
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: nil), "暂不可测")
    }

    func testDisconnectedNodeUsesItsOwnTestResultOrUntestedLabel() {
        var state = ConnectionState()
        state.lastSuccessfulLatency = 780
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: 85), "85 ms")
        XCTAssertEqual(state.dashboardLatencyText(lastTestLatency: nil), "未测速")
    }
}

final class ExitIPTypeTests: XCTestCase {
    private func parse(_ risk: String) throws -> ExitIPTester.ExitInfo {
        let json = """
        {"ip":"8.8.8.8","isp":{"asn":"AS15169","isp":"Google LLC","org":"Google"},
         "location":{"country":"United States","country_code":"us","city":"Mountain View"},
         "risk":\(risk)}
        """
        return try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(json.utf8)))
    }

    func testFallbackGeoInformationGetsMissingTypeWithoutReplacingItsLocation() async {
        let original = ExitIPTester.ExitInfo(ip: "203.0.113.1", countryCode: "IT", city: "Milan", networkOperator: "Original ISP")
        let completed = await ExitIPTester.completingNetworkType(original) { ip in
            XCTAssertEqual(ip, "203.0.113.1")
            return .init(ip: ip, countryCode: "US", city: "Different City", networkType: .hosting)
        }
        XCTAssertEqual(completed.networkType, .hosting)
        XCTAssertEqual(completed.city, "Milan")
        XCTAssertEqual(completed.countryCode, "IT")
        XCTAssertEqual(completed.networkOperator, "Original ISP")
    }

    func testKnownTypeAndMissingOrInvalidExitIPDoNotTriggerLookup() async {
        for info in [ExitIPTester.ExitInfo(ip: "203.0.113.1", networkType: .mobile),
                     .init(city: "Milan"), .init(ip: "example.com/path"), .init(ip: "")] {
            let result = await ExitIPTester.completingNetworkType(info) { _ in
                XCTFail("Known types and invalid IPs must not be queried")
                return nil
            }
            XCTAssertEqual(result.ip, info.ip)
            XCTAssertEqual(result.networkType, info.networkType)
        }
    }

    func testMismatchedAndUnavailableTypeQueriesStayUnknown() async {
        let original = ExitIPTester.ExitInfo(ip: "203.0.113.1", city: "Milan")
        let mismatched = await ExitIPTester.completingNetworkType(original) { _ in
            .init(ip: "203.0.113.2", networkType: .hosting)
        }
        XCTAssertNil(mismatched.networkType)
        XCTAssertEqual(mismatched.city, "Milan")
        let failed = await ExitIPTester.completingNetworkType(original) { _ in nil }
        XCTAssertNil(failed.networkType)
        XCTAssertEqual(failed.ip, original.ip)
    }

    func testSameExitKeepsItsKnownTypeWhenFallbackProviderOmitsIt() {
        let previous = NodeExitMetadata(ip: "203.0.113.1", city: "Milan", networkType: .hosting, localizedCity: "米兰")
        var refreshed = NodeExitMetadata(ip: previous.ip, city: "Milan")
        let retained = refreshed.retainingKnownDetails(from: previous)
        XCTAssertEqual(retained.networkType, .hosting)
        XCTAssertEqual(retained.localizedCity, "米兰")
        refreshed.city = "Rome"
        XCTAssertEqual(refreshed.retainingKnownDetails(from: previous).networkType, .hosting)
        XCTAssertNil(refreshed.retainingKnownDetails(from: previous).localizedCity)
        refreshed.networkType = .vpn
        XCTAssertEqual(refreshed.retainingKnownDetails(from: previous).networkType, .vpn)
        refreshed.networkType = nil
        refreshed.ip = "203.0.113.2"
        XCTAssertNil(refreshed.retainingKnownDetails(from: previous).networkType)
    }

    func testTypeEnrichmentKeepsPendingCityLookupCompatible() {
        let original = NodeExitMetadata(ip: "203.0.113.1", city: "Milan", countryCode: "IT", latitude: 45.46, longitude: 9.19)
        var enriched = original
        enriched.networkType = .hosting
        XCTAssertTrue(enriched.hasSameCityObservation(as: original))
        enriched.city = "Rome"
        XCTAssertFalse(enriched.hasSameCityObservation(as: original))
        enriched = original
        enriched.ip = "203.0.113.2"
        XCTAssertFalse(enriched.hasSameCityObservation(as: original))
        enriched = original
        enriched.latitude = 41.90
        XCTAssertFalse(enriched.hasSameCityObservation(as: original))
    }

    func testLiveExitTypeIsRetainedOnlyForTheSameIP() {
        var state = ConnectionState(status: .connected)
        state.recordExitIP("203.0.113.1", type: .hosting)
        state.recordExitIP("203.0.113.1", type: nil)
        XCTAssertEqual(state.exitIPType, .hosting)
        state.recordExitIP("203.0.113.1", type: .vpn)
        XCTAssertEqual(state.exitIPType, .vpn)
        state.recordExitIP("203.0.113.2", type: nil)
        XCTAssertNil(state.exitIPType)
        state.recordExitIP("203.0.113.2", type: .hosting)
        state.recordExitIP(nil, type: nil)
        XCTAssertNil(state.exitIPType)
        XCTAssertNil(state.exitIP)
    }

    func testNestedIPQueryResponse() throws {
        let info = try parse(#"{"is_datacenter":true}"#)
        XCTAssertEqual(info.ip, "8.8.8.8")
        XCTAssertEqual(info.countryCode, "US")
        XCTAssertEqual(info.countryName, "United States")
        XCTAssertEqual(info.city, "Mountain View")
        XCTAssertEqual(info.asn, "AS15169")
        XCTAssertEqual(info.networkOperator, "Google LLC")
        XCTAssertEqual(info.networkType, .hosting)
    }

    func testKnownNetworkTypesAndPriority() throws {
        for (flag, type) in [("is_mobile", ExitIPType.mobile), ("is_datacenter", .hosting),
                             ("is_vpn", .vpn), ("is_proxy", .proxy), ("is_tor", .tor)] {
            XCTAssertEqual(try parse("{\"\(flag)\":true}").networkType, type)
        }
        XCTAssertEqual(try parse(#"{"is_mobile":true,"is_datacenter":true}"#).networkType, .hosting)
        XCTAssertEqual(try parse(#"{"is_vpn":true,"is_datacenter":true}"#).networkType, .vpn)
        XCTAssertEqual(try parse(#"{"is_tor":true,"is_vpn":true}"#).networkType, .tor)
    }

    func testResidentialRequiresAllKnownFlagsToBeFalseAndDisclosesInference() throws {
        let info = try parse(#"{"is_mobile":false,"is_vpn":false,"is_tor":false,"is_proxy":false,"is_datacenter":false}"#)
        XCTAssertEqual(info.networkType, .residential)
        XCTAssertTrue(try XCTUnwrap(info.networkType).displayName.contains("推测"))
    }

    func testMissingOrMalformedFlagsStayUnknown() throws {
        for risk in ["null", "{}", #"{"is_datacenter":false}"#,
                     #"{"is_mobile":"false","is_vpn":false,"is_tor":false,"is_proxy":false,"is_datacenter":false}"#] {
            XCTAssertNil(try parse(risk).networkType)
        }
    }

    func testLegacyProvidersKeepExitInformationWithoutGuessingType() throws {
        for json in [#"{"ip":"8.8.8.8","country_code":"US","country":"United States","asn":"AS15169"}"#,
                     #"{"query":"8.8.8.8","countryCode":"US","country":"United States","org":"Google"}"#] {
            let info = try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(json.utf8)))
            XCTAssertEqual(info.ip, "8.8.8.8")
            XCTAssertEqual(info.countryCode, "US")
            XCTAssertNil(info.networkType)
        }
        XCTAssertNil(ExitIPTester.parseGeoJSON(Data(#"{"error":"rate limited"}"#.utf8)))
        XCTAssertNil(ExitIPTester.parseGeoJSON(Data("invalid".utf8)))
    }

    func testOldConnectionStateStillDecodesAndResetClearsType() throws {
        var state = try JSONDecoder().decode(ConnectionState.self,
            from: Data(#"{"status":"connected","exitIP":"8.8.8.8","downloadMbps":0,"uploadMbps":0,"sessionDownloadBytes":0,"sessionUploadBytes":0,"autoSelectEnabled":true}"#.utf8))
        XCTAssertNil(state.exitIPType)
        XCTAssertNil(state.exitCity)
        XCTAssertNil(state.exitOperator)
        XCTAssertNil(state.exitASN)
        state.exitIPType = .hosting
        state.exitCity = "Mountain View"
        state.exitOperator = "Google LLC"
        state.exitASN = "AS15169"
        let restored = try JSONDecoder().decode(ConnectionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.exitIPType, .hosting)
        XCTAssertEqual(restored.exitCity, "Mountain View")
        XCTAssertEqual(restored.exitOperator, "Google LLC")
        XCTAssertEqual(restored.exitASN, "AS15169")
        state = ConnectionState()
        XCTAssertNil(state.exitIP)
        XCTAssertNil(state.exitIPType)
        XCTAssertNil(state.exitCity)
        XCTAssertNil(state.exitOperator)
        XCTAssertNil(state.exitASN)
    }

    func testOperatorAndASNRemainSeparateAcrossFallbackProviders() throws {
        for json in [
            #"{"ip":"8.8.8.8","city":"Mountain View","asn":15169,"isp":"Google LLC","asn_organization":"Google"}"#,
            #"{"ip":"8.8.8.8","city":"Mountain View","asn":"AS15169","org":"Google LLC"}"#,
            #"{"ip":"8.8.8.8","city":"Mountain View","asn":"AS15169","asn_org":"Google LLC"}"#
        ] {
            let info = try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(json.utf8)))
            XCTAssertEqual(info.city, "Mountain View")
            XCTAssertEqual(info.asn, "AS15169")
            XCTAssertEqual(info.networkOperator, "Google LLC")
        }
        let info = try XCTUnwrap(ExitIPTester.parseGeoJSON(Data(#"{"ip":"8.8.8.8","org":"Google LLC"}"#.utf8)))
        XCTAssertNil(info.city)
        XCTAssertNil(info.asn, "An organization name must not be presented as an ASN")
        XCTAssertEqual(info.networkOperator, "Google LLC")
    }
}

final class RoutingRulesTests: XCTestCase {
    func testNormalizeDomainsAndIPRanges() throws {
        let parsed = try RoutingRules().entries(" Example.COM \nfull:api.example.com\ndomain:test.com\n1.2.3.4\n10.0.0.0/8\n2001:db8::/32\n# comment\n")
        XCTAssertEqual(parsed.domains, ["domain:example.com", "full:api.example.com", "domain:test.com"])
        XCTAssertEqual(parsed.ips, ["1.2.3.4", "10.0.0.0/8", "2001:db8::/32"])
    }

    func testRejectMalformedRules() {
        for value in ["https://example.com", "example.com:443", "*.example.com", "1.2.3.4/33", "::1/129", "1.2.3.999", "geosite:cn", "bad..com", "-bad.com", "1.2.3.4/", "1.2.3.4/8/9", "1.2.3.4/+24"] {
            XCTAssertThrowsError(try RoutingRules().entries(value), value)
        }
    }

    func testCustomRulesPrecedeBuiltinsAndFallbackRemainsUnmatched() throws {
        var settings = RoutingRules()
        settings.blocked = "ads.example.com"
        settings.proxy = "example.com\n1.2.3.0/24"
        settings.direct = "internal.example.com"
        let config = try settings.xrayRouting()
        XCTAssertEqual(config["domainStrategy"] as? String, "IPOnDemand")
        let rules = try XCTUnwrap(config["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.prefix(5).compactMap { $0["outboundTag"] as? String }, ["api", "blocked", "proxy", "proxy", "direct"])
        XCTAssertTrue(rules.contains { ($0["domain"] as? [String]) == ["geosite:cn"] })
        XCTAssertTrue(rules.contains { ($0["ip"] as? [String]) == ["geoip:cn"] })
        XCTAssertFalse(rules.contains { $0["network"] != nil })
        settings.bypassChina = false
        let disabled = try JSONSerialization.data(withJSONObject: settings.xrayRouting())
        XCTAssertFalse(String(decoding: disabled, as: UTF8.self).contains(":cn"))
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.routingRules.proxy = "example.com"
        settings.routingRules.bypassChina = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testRealXrayAcceptsRoutingWithBundledData() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let binary = root.appendingPathComponent("HopWorld/Resources/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("本地未提供 Xray") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = RoutingRules()
        settings.proxy = "full:example.com\n2001:db8::/32"
        settings.blocked = "ads.example.com"
        let config: [String: Any] = [
            "routing": try settings.xrayRouting(),
            "outbounds": [["tag": "proxy", "protocol": "freedom"], ["tag": "direct", "protocol": "freedom"], ["tag": "blocked", "protocol": "blackhole"], ["tag": "api", "protocol": "freedom"]],
            "dns": ["servers": [["address": "223.5.5.5", "domains": ["geosite:cn"], "skipFallback": true] as [String: Any], "1.1.1.1"]]
        ]
        let file = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-test", "-config", file.path]
        var environment = ProcessInfo.processInfo.environment
        // Child processes may not inherit removable-volume access. Keep the
        // integration fixture self-contained while validating the bundled bytes.
        for name in ["geoip.dat", "geosite.dat"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        environment["XRAY_LOCATION_ASSET"] = directory.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }
}

final class DateTemplateTests: XCTestCase {
    @MainActor
    func testYesterdayFirstFetchOrderAndNormalUpdates() {
        var sub = Subscription(name: "日期测试", originalURL: "https://example.com/202610/1014Clash.yaml",
                               urlTemplate: "https://example.com/{yyyy}{MM}/{MM}{dd}Clash.yaml", urlMode: .dateTemplate)
        XCTAssertEqual(sub.initialFetchOffsets(includeYesterday: true), [-1, 0])
        XCTAssertEqual(sub.initialFetchOffsets(includeYesterday: false), [0])
        sub.urlMode = .fixed
        XCTAssertEqual(sub.initialFetchOffsets(includeYesterday: true), [0])
        sub.urlMode = .dateTemplate
        sub.dateOffset = -2
        XCTAssertEqual(sub.initialFetchOffsets(includeYesterday: false), [-2])
        XCTAssertEqual(sub.initialFetchOffsets(includeYesterday: true), [-1, 0])
    }

    func testYesterdayThenTodayAcrossYearBoundary() {
        let template = SubscriptionDateTemplate(template: "https://example.com/{yyyy}{MM}/{MM}{dd}Clash.yaml")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(template.resolve(date: yesterday, timeZone: calendar.timeZone), "https://example.com/202612/1231Clash.yaml")
        XCTAssertEqual(template.resolve(date: today, timeZone: calendar.timeZone), "https://example.com/202701/0101Clash.yaml")
    }

    func testYearMonthDirectoryAndMonthDayFilename() {
        let url = "https://aa.mibei77.com/202610/1013Clashikd.yaml"
        let detection = SubscriptionDateTemplateDetector.detect(from: url)
        XCTAssertTrue(detection.detected)
        XCTAssertEqual(detection.template, "https://aa.mibei77.com/{yyyy}{MM}/{MM}{dd}Clashikd.yaml")
        XCTAssertEqual(detection.matchedDateText, "20261013")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for (year, month, day, expected) in [(2026, 10, 15, "202610/1015"), (2026, 11, 1, "202611/1101"), (2027, 1, 1, "202701/0101")] {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
            XCTAssertEqual(detection.preview(for: date, timeZone: calendar.timeZone), "https://aa.mibei77.com/\(expected)Clashikd.yaml")
        }
    }

    func testSplitDatePreservesQueryAndRejectsFalseDates() {
        let url = "https://example.com/202610/1013Clash.yaml?token=2026101013#keep"
        XCTAssertEqual(SubscriptionDateTemplateDetector.detect(from: url).template,
                       "https://example.com/{yyyy}{MM}/{MM}{dd}Clash.yaml?token=2026101013#keep")
        for invalid in ["https://example.com/202610/1113Clash.yaml", "https://example.com/202602/0231Clash.yaml", "https://example.com/sub?path=/202610/1013Clash.yaml"] {
            XCTAssertFalse(SubscriptionDateTemplateDetector.detect(from: invalid).detected)
        }
    }

    func testNodeFreeTemplateDetection() {
        let url = "https://node.nodefree.me/2026/08/20260818.txt"
        let detection = SubscriptionDateTemplateDetector.detect(from: url)
        XCTAssertTrue(detection.detected)
        XCTAssertEqual(detection.template, "https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt")
    }

    func testClashGitHubTemplateDetection() {
        let url = "https://clashgithub.com/wp-content/uploads/rss/20260818.txt"
        let detection = SubscriptionDateTemplateDetector.detect(from: url)
        XCTAssertTrue(detection.detected)
        XCTAssertEqual(detection.template, "https://clashgithub.com/wp-content/uploads/rss/{yyyyMMdd}.txt")
    }

    func testResolveAcrossMonth() {
        let template = SubscriptionDateTemplate(template: "https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let resolved = template.resolve(date: date, timeZone: calendar.timeZone)
        XCTAssertEqual(resolved, "https://node.nodefree.me/2026/09/20260901.txt")
    }

    func testResolveAcrossYear() {
        let template = SubscriptionDateTemplate(template: "https://example.com/{yyyy}/{MM}/{yyyyMMdd}.txt")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let resolved = template.resolve(date: date, timeZone: calendar.timeZone)
        XCTAssertEqual(resolved, "https://example.com/2027/01/20270101.txt")
    }
}

final class NodeDisplayNameTests: XCTestCase {
    func testCountryLabelsOnlyFillMissingChineseNames() {
        var settings = AppSettings()
        var node = ProxyNode(name: "🇬🇧 英国 | VLESS | 001", protocolType: .vless, server: "example.com", port: 443)
        XCTAssertNil(settings.nodeCountryLabel(node))
        node.name = "US美国"
        XCTAssertNil(settings.nodeCountryLabel(node))
        node.name = "US - zhuhai.uk"
        XCTAssertEqual(settings.nodeCountryLabel(node, displayedCity: "圣荷西"), "美国")
        node.name = "HK - zhuhai.uk"
        XCTAssertEqual(settings.nodeCountryLabel(node), "香港")
        XCTAssertNil(settings.nodeCountryLabel(node, displayedCity: "香港"))
        XCTAssertEqual(settings.nodeCountryLabel(node, displayedCity: "Hong Kong"), "香港")
        node.name = "🇺🇸 [freenode.biz] US"
        node.countryCode = "IT"
        node.countryName = "Italy"
        XCTAssertEqual(settings.nodeCountryLabel(node, displayedCity: "米兰"), "意大利")
        node.name = "US美国"
        node.countryCode = "US"
        settings.nodeNameAdFilterText = "美国"
        XCTAssertEqual(settings.nodeCountryLabel(node), "美国")
    }

    func testFilteringIsOnByDefaultAndCanRestoreOriginalNames() {
        var settings = AppSettings()
        XCTAssertTrue(settings.filterNodeNameAds)
        for raw in ["US 美国（mibei77.com 米贝节点分享）", "US 美国 +v2cross.com", "US 美国 +CloudFlare 节点"] {
            let node = ProxyNode(name: raw, protocolType: .vless, server: "example.com", port: 443)
            settings.filterNodeNameAds = true
            XCTAssertEqual(settings.nodeDisplayTitle(node), "US 美国")
            settings.filterNodeNameAds = false
            XCTAssertEqual(settings.nodeDisplayTitle(node), raw)
            XCTAssertEqual(node.name, raw)
        }
    }

    func testCachedProbeLabelsFollowFilteringWithoutLosingOriginalText() {
        let raw = "🇺🇸 美国 · US 美国（mibei77.com 米贝节点分享）"
        var settings = AppSettings()
        XCTAssertEqual(settings.nodeDisplayName(raw), "🇺🇸 美国 · US 美国")
        settings.filterNodeNameAds = false
        XCTAssertEqual(settings.nodeDisplayName(raw), raw)
        settings.filterNodeNameAds = true
        XCTAssertEqual(settings.nodeDisplayName(raw), "🇺🇸 美国 · US 美国")
    }

    func testOldSettingsEnableFilteringWithoutResettingOtherPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.httpPort = 12809
        settings.autoFailover = false
        settings.autoSelectExcludedCountryCodes = ["CN"]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "filterNodeNameAds")
        legacy.removeValue(forKey: "nodeNameAdFilterText")
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("settings.json"))
        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertTrue(restored.filterNodeNameAds)
        XCTAssertEqual(restored.nodeNameAdFilterText, "")
        XCTAssertEqual(restored.httpPort, 12809)
        XCTAssertFalse(restored.autoFailover)
        XCTAssertEqual(restored.autoSelectExcludedCountryCodes, ["CN"])
    }

    func testFilteringPreferencePersistsAcrossReloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        let file = directory.appendingPathComponent("settings.json")
        for enabled in [false, true] {
            var settings = AppSettings()
            settings.filterNodeNameAds = enabled
            settings.nodeNameAdFilterText = "+推广来源\n（赞助片段）"
            store.saveSettings(settings)
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: file),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["filterNodeNameAds"] as? Bool == enabled { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let restored = PersistenceStore(directory: directory).loadSettings()
            XCTAssertEqual(restored.filterNodeNameAds, enabled)
            XCTAssertEqual(restored.nodeNameAdFilterText, settings.nodeNameAdFilterText)
        }
    }

    func testSettingsDraftCommitsFilteringAndPreservesConcurrentChanges() {
        let baseline = AppSettings()
        var draft = baseline
        draft.filterNodeNameAds = false
        draft.nodeNameAdFilterText = "（赞助片段）"
        var current = baseline
        current.testConcurrency = 8
        current.lastScheduledTestAt = Date(timeIntervalSince1970: 1234)
        let saved = current.applyingSettingsEdits(from: draft, comparedTo: baseline)
        XCTAssertFalse(saved.filterNodeNameAds)
        XCTAssertEqual(saved.nodeNameAdFilterText, draft.nodeNameAdFilterText)
        XCTAssertEqual(saved.testConcurrency, current.testConcurrency)
        XCTAssertEqual(saved.lastScheduledTestAt, current.lastScheduledTestAt)
        XCTAssertEqual(current.applyingSettingsEdits(from: baseline, comparedTo: baseline), current)
    }

    func testRemovesMibeiPromotionWithBothParenthesisStyles() {
        for raw in [
            "US 美国 (mibei77.com 米贝节点分享)",
            "US 美国（mibei77.com 米贝节点分享）",
            "US 美国 ( MIBEI88.COM  米贝节点分享 )  ",
            "US 美国（mibei.com 米贝节点分享）"
        ] {
            XCTAssertEqual(ProxyNode.sanitizedDisplayName(raw), "US 美国", raw)
        }
        XCTAssertEqual(ProxyNode.sanitizedDisplayName("🇺🇸 US 美国（mibei77.com 米贝节点分享）"), "🇺🇸 US 美国")
    }

    func testPreservesRouteDetailsAndUnrelatedNames() {
        let route = "US 美国（专线 01） [倍率 0.5x]"
        XCTAssertEqual(ProxyNode.sanitizedDisplayName(route + "（mibei77.com 米贝节点分享）"), route)
        for raw in ["US 美国（专线 01）", "美国 (example.com)", "mibei77.com 备用线路", "US 美国（米贝77线路）",
                    "Cloudflare 美国节点", "美国 +Cloudflare 节点优化"] {
            XCTAssertEqual(ProxyNode.sanitizedDisplayName(raw), raw)
        }
    }

    func testRemovesCloudflarePromotionAndPreservesRouteDetails() {
        for (raw, expected) in [
            ("美国 +CloudFlare 节点", "美国"),
            ("美国+CloudFlare节点", "美国"),
            ("🇺🇸 美国 ＋ cloudflare 节点", "🇺🇸 美国"),
            ("美国（专线 01） +CLOUDFLARE 节点", "美国（专线 01）"),
            ("美国 +CloudFlare 节点（专线 01）", "美国（专线 01）"),
            ("美国 +CloudFlare 节点 02", "美国 02"),
            ("美国 +CloudFlare 节点 +v2cross.com", "美国")
        ] {
            XCTAssertEqual(ProxyNode.sanitizedDisplayName(raw), expected, raw)
        }
    }

    func testExistingPromotionRuleAndEmptyNameFallback() {
        XCTAssertEqual(ProxyNode.sanitizedDisplayName("US 美国 +V2CROSS.COM"), "US 美国")
        XCTAssertEqual(ProxyNode.sanitizedDisplayName("US 美国（mibei77.com 米贝节点分享） +v2cross.com"), "US 美国")
        let promotionOnly = "（mibei77.com 米贝节点分享）"
        XCTAssertEqual(ProxyNode.sanitizedDisplayName(promotionOnly), promotionOnly)
        XCTAssertEqual(ProxyNode.sanitizedDisplayName(""), "")
    }

    func testGenericPromotionsDoNotRequireKnownProviderNames() {
        for (raw, expected) in [
            ("美国 +新来源节点", "美国"),
            ("🇯🇵 日本 ＋ ExampleSource 节点分享", "🇯🇵 日本"),
            ("香港 +another-source.example", "香港"),
            ("美国 +https://new-source.example", "美国"),
            ("日本（new-source.example 新来源节点分享）", "日本"),
            ("香港【新来源免费节点】", "香港"),
            ("美国 [new-source.example 订阅分享]", "美国"),
            ("美国 | 新来源免费节点", "美国"),
            ("美国 ｜ free-nodes", "美国"),
            ("美国（IPLC 01） [倍率 0.5x] +新来源节点（new-source.example 节点分享）", "美国（IPLC 01） [倍率 0.5x]")
        ] {
            XCTAssertEqual(ProxyNode.sanitizedDisplayName(raw), expected, raw)
        }
    }

    func testGenericFilteringPreservesTechnicalDescriptions() {
        for raw in [
            "香港 +中转节点", "美国 +直连节点", "日本 +IPLC 节点", "美国 +VLESS节点",
            "美国 +IPv6节点", "香港 +备用节点", "美国 +WS节点", "日本（https://cdn.example/path）",
            "美国 [倍率 0.5x]", "美国（中转入口）", "美国 | VLESS | 01", "香港 +新来源节点优化"
        ] {
            XCTAssertEqual(ProxyNode.sanitizedDisplayName(raw), raw)
        }
    }

    func testCustomFiltersMatchLiteralTextAndCleanEmptyDecorations() {
        let filters = ["", "  ", " 广告 ", "广告来源", "AD.+", "$promo[1]", "a+b"]
        for raw in ["美国（广告来源）", "美国 [AD.+]", "美国【$promo[1]】", "美国 +a+b"] {
            XCTAssertEqual(ProxyNode.sanitizedDisplayName(raw, customFilters: filters), "美国", raw)
        }
        XCTAssertEqual(ProxyNode.sanitizedDisplayName("美国 ADxyz", customFilters: filters), "美国 ADxyz")
        XCTAssertEqual(ProxyNode.sanitizedDisplayName("美国 01（ad.+） [倍率 0.5x]", customFilters: filters),
                       "美国 01 [倍率 0.5x]")
        XCTAssertEqual(ProxyNode.sanitizedDisplayName("美国", customFilters: ["美国"]), "美国")
    }

    func testCustomFiltersFollowTheSwitchAndPreserveOriginalNode() {
        var settings = AppSettings()
        settings.nodeNameAdFilterText = "\n  （赞助来源）  \n（额外标记）\n"
        let raw = "美国 +新来源节点（赞助来源）（额外标记）"
        let node = ProxyNode(name: raw, protocolType: .vless, server: "example.com", port: 443)
        XCTAssertEqual(settings.nodeDisplayTitle(node), "美国")
        settings.filterNodeNameAds = false
        XCTAssertEqual(settings.nodeDisplayTitle(node), raw)
        XCTAssertEqual(node.name, raw)
    }

    func testExistingSavedNodeUsesCleanTitleWithoutChangingStoredData() throws {
        let raw = "US 美国（mibei77.com 米贝节点分享）"
        let node = ProxyNode(name: raw, protocolType: .vless, server: "example.com", port: 443)
        let encoded = try JSONEncoder().encode(node)
        let restored = try JSONDecoder().decode(ProxyNode.self, from: encoded)
        XCTAssertEqual(restored.displayTitle, "US 美国")
        XCTAssertEqual(restored, node)
        XCTAssertEqual(restored.name, raw)
    }
}

final class MergeTests: XCTestCase {
    private func node(_ name: String, server: String, port: Int = 443) -> ProxyNode {
        var n = ProxyNode(
            name: name,
            protocolType: .vless,
            server: server,
            port: port,
            uuid: "11111111-1111-1111-1111-111111111111"
        )
        n.nodeFingerprint = NodeFingerprint.make(from: n)
        return n
    }

    func testOverwrite() {
        let a = node("A", server: "a.com")
        let b = node("B", server: "b.com")
        let c = node("C", server: "c.com")
        let d = node("D", server: "d.com")
        let plan = SubscriptionMerger.buildPlan(
            mode: .overwrite,
            oldNodes: [a, b, c],
            newNodes: [b, c, d],
            missingLimit: 3
        )
        XCTAssertEqual(Set(plan.resultingNodes.map(\.server)), Set(["b.com", "c.com", "d.com"]))
    }

    func testMerge() {
        let a = node("A", server: "a.com")
        let b = node("B", server: "b.com")
        let c = node("C", server: "c.com")
        let d = node("D", server: "d.com")
        let plan = SubscriptionMerger.buildPlan(
            mode: .merge,
            oldNodes: [a, b, c],
            newNodes: [b, c, d],
            missingLimit: 3
        )
        XCTAssertEqual(Set(plan.resultingNodes.map(\.server)), Set(["a.com", "b.com", "c.com", "d.com"]))
    }

    func testSmartMergeUpdatesExisting() {
        var old = node("B", server: "b.com")
        old.isFavorite = true
        var incoming = node("B-new", server: "b.com")
        incoming.nodeFingerprint = NodeFingerprint.make(from: incoming)
        let plan = SubscriptionMerger.buildPlan(
            mode: .smartMerge,
            oldNodes: [old],
            newNodes: [incoming],
            missingLimit: 3
        )
        XCTAssertEqual(plan.resultingNodes.count, 1)
        XCTAssertEqual(plan.resultingNodes[0].name, "B-new")
        XCTAssertTrue(plan.resultingNodes[0].isFavorite)
        XCTAssertEqual(plan.resultingNodes[0].id, old.id)
    }

    func testSmartMergeMatchesIdentityWhenPasswordChanges() {
        var old = node("JP-01", server: "1.2.3.4")
        old.isFavorite = true
        old.note = "office"
        var incoming = node("JP-01", server: "1.2.3.4")
        incoming.uuid = "22222222-2222-2222-2222-222222222222"
        incoming.nodeFingerprint = NodeFingerprint.make(from: incoming)
        let plan = SubscriptionMerger.buildPlan(
            mode: .smartMerge,
            oldNodes: [old],
            newNodes: [incoming],
            missingLimit: 3
        )
        XCTAssertEqual(plan.resultingNodes.count, 1)
        XCTAssertEqual(plan.resultingNodes[0].id, old.id)
        XCTAssertTrue(plan.resultingNodes[0].isFavorite)
        XCTAssertEqual(plan.resultingNodes[0].note, "office")
        XCTAssertEqual(plan.resultingNodes[0].uuid, incoming.uuid)
    }
}

final class ParserTests: XCTestCase {
    func testPastedBase64SubscriptionImportsAll26NodesIncludingAnyTLS() throws {
        // Same protocol mix and URL shapes as the 26-link report, with fixture credentials.
        let anyTLSVariants = [("first", "sni=tls.example"), ("second", "fp=chrome"),
                              ("first", "sni=tls.example&fp=chrome"), ("second", "sni=127.0.0.1"),
                              ("third", "sni=images.example&fp=chrome&alpn=http%2F1.1"),
                              ("first", "sni=tls.example&fp=chrome&alpn=http%2F1.1"),
                              ("second", "sni=images.example&fp=chrome")]
        let links = anyTLSVariants.map { "anytls://fixture@\($0.0).example.com:443?insecure=1&security=tls&type=tcp&headerType=none&\($0.1)#AnyTLS" }
            + (0..<5).map { "vless://11111111-1111-4111-8111-111111111111@v\($0).example.com:443?security=tls&type=ws&path=%2Fresource#VLESS" }
            + (0..<10).map { "ss://YWVzLTI1Ni1nY206Zml4dHVyZQ@ss\($0).example.com:19999?#SS" }
            + (0..<3).map { "trojan://fixture@t\($0).example.com:443?security=tls&type=ws&path=%2F%3Fed%3D2560#Trojan" }
            + ["socks://Og@proxy.example.com:10808#SOCKS"]
        let text = links.joined(separator: "\r\n") + "\r\n"
        let base64 = Data(text.utf8).base64EncodedString()
        for body in [text, base64, base64.replacingOccurrences(of: "=", with: ""), " \n" + base64 + "\r\n"] {
            XCTAssertEqual(NodeLinkParser.extractShareLinks(from: body), links)
            let pasted = NodeLinkParser.parseLines(body)
            XCTAssertEqual(pasted.validNodes.count, 26)
            XCTAssertEqual(SubscriptionMerger.deduplicate(pasted.validNodes).count, 26)
            XCTAssertEqual(pasted.invalidCount, 0)
            XCTAssertEqual(pasted.skippedLinksSummary, "")
            let subscription = try SubscriptionContentParser.parse(data: Data(body.utf8))
            XCTAssertEqual(subscription.validNodes.count, 26)
            XCTAssertEqual(subscription.invalidCount, 0)
        }
    }

    func testPastedBase64AcceptsURLSafeAlphabetAndWrappedLines() throws {
        let link = "trojan://fixture@example.com:443#\u{FFFF}"
        let encoded = Data(link.utf8).base64EncodedString()
        XCTAssertTrue(encoded.contains("/") || encoded.contains("+"))
        let urlSafe = encoded.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let wrapped = urlSafe.prefix(20) + "\r\n\t" + urlSafe.dropFirst(20)
        for body in [urlSafe, String(wrapped)] {
            XCTAssertEqual(NodeLinkParser.extractShareLinks(from: body), [link])
            let result = try SubscriptionContentParser.parse(data: Data(body.utf8))
            XCTAssertEqual(result.validNodes.count, 1)
            XCTAssertEqual(result.skippedLinksSummary, "")
        }
        XCTAssertTrue(NodeLinkParser.parseLines("invalid base64?!").validNodes.isEmpty)
        XCTAssertThrowsError(try SubscriptionContentParser.parse(data: Data("invalid base64?!".utf8)))
    }

    func testShadowsocksEmptyQueryAndEndpointValidation() throws {
        for suffix in ["", "?", "/", "/?"] {
            let node = try ShadowsocksParser.parse("ss://YWVzLTI1Ni1nY206Zml4dHVyZQ@example.com:19999" + suffix + "#%E6%B5%8B%E8%AF%95")
            XCTAssertEqual(node.server, "example.com")
            XCTAssertEqual(node.port, 19999)
            XCTAssertEqual(node.method, "aes-256-gcm")
            XCTAssertEqual(node.password, "fixture")
            XCTAssertEqual(node.name, "测试")
        }
        let ipv6 = try ShadowsocksParser.parse("ss://YWVzLTI1Ni1nY206Zml4dHVyZQ@[::1]:443?")
        XCTAssertEqual(ipv6.server, "::1")
        for endpoint in ["example.com:0", "example.com:65536", "example.com:443/?plugin=unsupported", "example.com:443/path"] {
            XCTAssertThrowsError(try ShadowsocksParser.parse("ss://YWVzLTI1Ni1nY206Zml4dHVyZQ@" + endpoint))
        }
    }

    func testSOCKSBase64CredentialsAndAnonymousPlaceholder() throws {
        for scheme in ["socks", "socks5"] {
            for userInfo in ["Og", "Og==", ":"] {
                let node = try NodeLinkParser.parse("\(scheme)://\(userInfo)@example.com:10808#SOCKS")
                XCTAssertEqual(node.protocolType, .socks5)
                XCTAssertNil(node.username)
                XCTAssertNil(node.password)
            }
            let credentials = Data("user:p:a:ss".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let node = try NodeLinkParser.parse("\(scheme)://\(credentials)@example.com:1080")
            XCTAssertEqual(node.username, "user")
            XCTAssertEqual(node.password, "p:a:ss")
            for userInfo in ["user", "user:", ":pass", "invalid-encoding", "dXNlcjo="] {
                XCTAssertThrowsError(try NodeLinkParser.parse("\(scheme)://\(userInfo)@example.com:1080"))
            }
        }
    }

    func testGRPCAllowsEmptyServiceNameWithoutBypassingRealityKeyCheck() throws {
        for proto in [ProxyProtocolType.vless, .vmess, .trojan] {
            for serviceName in [nil, "", "custom-service"] as [String?] {
                var node = ProxyNode(name: "gRPC", protocolType: proto, server: "example.com", port: 443,
                                     uuid: "11111111-1111-4111-8111-111111111111", password: "fixture",
                                     transport: .grpc, security: .tls, serviceName: serviceName)
                XCTAssertTrue(NodeConfigChecker.validate(node).0, "\(proto) / \(serviceName ?? "nil")")
                node.security = .reality
                for key in [nil, ""] as [String?] {
                    node.publicKey = key
                    let (valid, error) = NodeConfigChecker.validate(node)
                    XCTAssertFalse(valid)
                    XCTAssertEqual(error, "REALITY 缺少 publicKey")
                }
            }
        }
    }

    func testVLESSParse() throws {
        let link = "vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk=abc&sid=abcd&type=tcp#Japan-01"
        let node = try VLESSParser.parse(link)
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.server, "example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.security, .reality)
        XCTAssertEqual(node.name, "Japan-01")
    }

    func testVLESSRealityKeyAliasesSurviveSubscriptionAndExport() throws {
        for field in ["pbk", "publicKey", "publickey", "public-key", "public_key", "password"] {
            let link = "vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&\(field)=fixture-key&shortId=00ab&fp=chrome#Reality"
            for body in [link, Data(link.utf8).base64EncodedString()] {
                let node = try XCTUnwrap(SubscriptionContentParser.parse(data: Data(body.utf8)).validNodes.first)
                XCTAssertEqual(node.publicKey, "fixture-key", field)
                XCTAssertEqual(node.shortID, "00ab", field)
                XCTAssertTrue(NodeConfigChecker.validate(node).0, field)
                let exported = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: node))
                let roundTrip = try VLESSParser.parse(exported)
                XCTAssertEqual(roundTrip.publicKey, node.publicKey)
                XCTAssertEqual(roundTrip.shortID, node.shortID)
            }
        }
    }

    func testVLESSRealityKeyPrefersNonemptyCanonicalFieldAndStillRequiresAKey() throws {
        let prefix = "vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality&"
        for (query, expected) in [("pbk=canonical&publicKey=alias", "canonical"),
                                  ("pbk=&publicKey=%20alias%20", "alias"),
                                  ("pbk=%20%20&public_key=alias", "alias")] {
            XCTAssertEqual(try VLESSParser.parse(prefix + query).publicKey, expected)
        }
        for query in ["", "pbk=", "publicKey=%20%20", "pqv=unrelated-key"] {
            let node = try VLESSParser.parse(prefix + query)
            XCTAssertNil(node.publicKey)
            XCTAssertEqual(NodeConfigChecker.validate(node).1, "REALITY 缺少 publicKey")
        }
        let tls = try VLESSParser.parse(prefix.replacingOccurrences(of: "security=reality", with: "security=tls") + "password=other")
        XCTAssertNil(tls.publicKey)
        XCTAssertEqual(tls.security, .tls)
    }

    func testTrojanParse() throws {
        let link = "trojan://password@example.com:443?security=tls&sni=example.com#HK"
        let node = try TrojanParser.parse(link)
        XCTAssertEqual(node.protocolType, .trojan)
        XCTAssertEqual(node.password, "password")
        XCTAssertEqual(node.name, "HK")
    }

    func testTrojanParseFinalMask() throws {
        let fm = #"{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","lengths":["5","94","1"],"delays":["0"],"maxSplit":"0"}}]}"#
        let encoded = fm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fm
        let link = "trojan://password@104.21.70.21:443?security=tls&sni=id1.nathaya.web.id&fp=unsafe&fm=\(encoded)&type=ws&host=id1.nathaya.web.id&path=%2Ftrojan#T"
        let node = try TrojanParser.parse(link)
        XCTAssertNotNil(node.finalMaskJSON)
        XCTAssertEqual(node.fingerprint, "unsafe")
        XCTAssertEqual(node.transport, .ws)
        let object = FinalMaskCodec.jsonObject(from: node) as? [String: Any]
        let tcp = object?["tcp"] as? [[String: Any]]
        let settings = tcp?.first?["settings"] as? [String: Any]
        XCTAssertEqual(settings?["lengths"] as? [String], ["5", "94", "1"])
        XCTAssertEqual(settings?["delays"] as? [String], ["0"])
    }
}

final class XrayTrafficStatisticsTests: XCTestCase {
    func testCountsApplicationAndSystemTrafficWithoutProbesOrAPI() throws {
        let data = Data(#"{"stat":[{"name":"inbound>>>application-in>>>traffic>>>uplink","value":"1234"},{"name":"inbound>>>application-in>>>traffic>>>downlink","value":5678},{"name":"inbound>>>socks-in>>>traffic>>>uplink","value":10},{"name":"inbound>>>http-in>>>traffic>>>downlink","value":20},{"name":"inbound>>>probe-in>>>traffic>>>downlink","value":9999},{"name":"inbound>>>api>>>traffic>>>uplink","value":9999},{"name":"outbound>>>proxy>>>traffic>>>downlink","value":5698}]}"#.utf8)
        let snapshot = try XCTUnwrap(XrayStatsClient.parse(data))
        XCTAssertEqual(snapshot.uploadBytes, 1244)
        XCTAssertEqual(snapshot.downloadBytes, 5698)
    }
}

final class AutoSelectAppReachabilityTests: XCTestCase {
    func testFailedProbeExcludesFavoriteUntilSuccessfulProbe() {
        let settings = AppSettings()
        var node = ProxyNode(name: "US test", protocolType: .vless, server: "example.com", port: 443)
        node.isFavorite = true
        node.lastLatency = 100
        node.lastTestStatus = .fast
        XCTAssertTrue(settings.allowsAutoSelectNode(node), "Untested nodes must remain available for probing")
        node.lastAppProbeDate = Date()
        node.lastAppProbeOkCount = 0
        XCTAssertFalse(settings.allowsAutoSelectNode(node), "Favorite must not override failed reachability")
        node.lastAppProbeOkCount = 2
        node.lastAppProbeLatency = 100
        XCTAssertTrue(settings.allowsAutoSelectNode(node))
        node.lastTestStatus = .unavailable
        XCTAssertFalse(settings.allowsAutoSelectNode(node), "Old app success must not override a failed connection")
    }
}

final class Hysteria2ImportTests: XCTestCase {
    func testConcatenatedLinksAndEmbeddedHTTPS() throws {
        let text = "hysteria2://secret@example.com:443?sni=tls.example.com#JP_01"
            + "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@example.org:80#US"
            + "vless://00000000-0000-0000-0000-000000000001@example.net:443?security=tls&type=ws&path=/https://example.com#FR"
            + "trojan://secret@example.org:443#Last"
        let parsed = NodeLinkParser.parseLines(text)
        XCTAssertEqual(parsed.validNodes.map(\.protocolType), [.hysteria2, .shadowsocks, .vless, .trojan])
        XCTAssertEqual(parsed.validNodes.map(\.name), ["JP_01", "US", "FR", "Last"])
        XCTAssertEqual(parsed.validNodes[2].path, "/https://example.com")
        XCTAssertEqual(parsed.invalidCount, 0)
        XCTAssertEqual(try SubscriptionContentParser.parse(data: Data(text.utf8).base64EncodedData()).validNodes.count, 4)
    }

    func testDefaultsCredentialsPersistenceAndExport() throws {
        let node = try NodeLinkParser.parse("hy2://user:pass@[::1]?sni=example.com&insecure=1#Test")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.password, "user:pass")
        XCTAssertEqual(node.allowInsecure, true)
        let restored = try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(restored.allowInsecure, true)
        let exported = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: restored))
        let roundTrip = try NodeLinkParser.parse(exported)
        XCTAssertEqual(roundTrip.password, node.password)
        XCTAssertEqual(roundTrip.sni, node.sni)
        XCTAssertEqual(roundTrip.allowInsecure, true)
        XCTAssertThrowsError(try NodeLinkParser.parse("hysteria2://example.com:443"))
        XCTAssertThrowsError(try NodeLinkParser.parse("hysteria2://secret@example.com:443?obfs=salamander"))
    }

    func testCoreConfig() throws {
        let node = try NodeLinkParser.parse("hysteria2://secret@127.0.0.1:24443?sni=localhost")
        let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 24580)])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        let outbound = try XCTUnwrap(outbounds.first { $0["protocol"] as? String == "hysteria" })
        let stream = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "hysteria")
        XCTAssertEqual((stream["hysteriaSettings"] as? [String: Any])?["auth"] as? String, "secret")
        XCTAssertNil((stream["tlsSettings"] as? [String: Any])?["allowInsecure"])
        var insecure = node
        insecure.allowInsecure = true
        let fallback = try XrayConfigBuilder.buildTestConfig(nodes: [(insecure, 24580)])
        let fallbacks = try XCTUnwrap(fallback["outbounds"] as? [[String: Any]])
        XCTAssertNotNil(fallbacks.first { $0[SingBoxConnectionConfig.marker] != nil })
        XCTAssertTrue(NodeConfigChecker.validate(insecure).0)
        XCTAssertTrue(NodeConfigChecker.validate(node).0)
    }
    func testUDPProbesDoNotRequireServerTCP() async {
        let node = ProxyNode(name: "UDP", protocolType: .hysteria2, server: "127.0.0.1", port: 1, password: "secret", security: .tls)
        let batch = await NodeProbeEngine.batchProxyProbe(node: node, localPort: 1, testURL: nil, tcpTimeout: 0.1, httpsTimeout: 0.1)
        XCTAssertEqual(batch?.failureStage, .http)
        let quick = await NodeProbeEngine.quickProxyProbe(node: node, localPort: 1, testURL: nil, timeout: 0.1)
        XCTAssertEqual(quick.failureStage, .http)
        let fallback = await NodeProbeEngine.tcpOnly(node: node, timeout: 0.1)
        XCTAssertFalse(fallback.success)
        XCTAssertEqual(fallback.failureStage, .config)
    }

    func testRealCoreLocalHysteria2Forwarding() async throws {
        try await localHysteria2Forwarding(useSingBox: false)
    }

    func testRealSingBoxInsecureHysteria2Forwarding() async throws {
        try await localHysteria2Forwarding(useSingBox: true)
    }

    @MainActor
    private func localHysteria2Forwarding(useSingBox: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("HopWorld/Resources/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("本地未提供 Xray") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func start(_ executable: String, _ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let log = directory.appendingPathComponent("process-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            return process
        }
        let cert = directory.appendingPathComponent("cert.pem").path
        let key = directory.appendingPathComponent("key.pem").path
        let openssl = try start("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost"])
        openssl.waitUntilExit()
        XCTAssertEqual(openssl.terminationStatus, 0)
        let base = Int.random(in: 30000...50000)
        let serverConfig: [String: Any] = [
            "log": ["loglevel": "debug"],
            "inbounds": [["listen": "127.0.0.1", "port": base, "protocol": "hysteria", "settings": ["version": 2],
                          "streamSettings": ["network": "hysteria", "security": "tls",
                                             "tlsSettings": ["alpn": ["h3"], "certificates": [["certificateFile": cert, "keyFile": key]]],
                                             "hysteriaSettings": ["version": 2, "auth": "secret"]]]],
            "outbounds": [["protocol": "freedom", "settings": ["finalRules": [["action": "allow", "network": "tcp", "ip": ["127.0.0.1"], "port": "\(base + 2)"]]]]]
        ]
        let serverFile = directory.appendingPathComponent("server.json")
        try XrayConfigBuilder.writeJSON(serverConfig, to: serverFile)
        let server = try start(binary.path, ["run", "-config", serverFile.path])
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let derFile = directory.appendingPathComponent("cert.der")
        let convert = try start("/usr/bin/openssl", ["x509", "-in", cert, "-outform", "DER", "-out", derFile.path])
        convert.waitUntilExit()
        let pin = CryptoUtil.sha256Hex(try Data(contentsOf: derFile))
        let tlsQuery = useSingBox ? "insecure=1" : "pinSHA256=\(pin)"
        let node = try NodeLinkParser.parse("hysteria2://secret@127.0.0.1:\(base)?sni=localhost&\(tlsQuery)")
        let clientFile = directory.appendingPathComponent("client.json")
        var clientConfig = try XrayConfigBuilder.buildTestConfig(nodes: [(node, base + 1)])
        clientConfig["log"] = ["loglevel": "debug"]
        try XrayConfigBuilder.writeJSON(clientConfig, to: clientFile)
        let manager = XrayProcessManager(binaryURL: binary)
        try await manager.start(configURL: clientFile)
        defer { Task { await manager.stop() } }
        // The local HTTP target makes the assertion independent of public servers and node credentials.
        let target = try start("/usr/bin/python3", ["-m", "http.server", "\(base + 2)", "--bind", "127.0.0.1", "--directory", directory.path])
        defer { if target.isRunning { target.terminate(); target.waitUntilExit() } }
        for _ in 0..<50 {
            if await TCPTester.measure(host: "127.0.0.1", port: base + 1, timeout: 0.1) != nil,
               await TCPTester.measure(host: "127.0.0.1", port: base + 2, timeout: 0.1) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(server.isRunning)
        if !(await manager.isRunning()) || !server.isRunning {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "log" {
                print(try String(contentsOf: file, encoding: .utf8))
            }
        }
        let clientRunning = await manager.isRunning()
        XCTAssertTrue(clientRunning)
        XCTAssertTrue(target.isRunning)
        let output = directory.appendingPathComponent("received.pem")
        let curl = try start("/usr/bin/curl", ["--silent", "--fail", "--max-time", "10", "--noproxy", "", "--proxy", "http://127.0.0.1:\(base + 1)", "http://127.0.0.1:\(base + 2)/cert.pem", "-o", output.path])
        curl.waitUntilExit()
        if curl.terminationStatus != 0 {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "log" {
                print(try String(contentsOf: file, encoding: .utf8))
            }
        }
        XCTAssertEqual(curl.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: URL(fileURLWithPath: cert)))
        await manager.stop()
        let stopped = await manager.isRunning()
        XCTAssertFalse(stopped)
        let bridgePaths = await manager.connectionCoreExecutables()
        XCTAssertTrue(bridgePaths.isEmpty)
    }

}

final class NodeFailureLoggingTests: XCTestCase {
    func testSameReasonGroupedWithoutDuplicatingNodeOrLoggingSuccess() {
        var log = NodeTestFailureLog()
        let first = NodeTestResult(nodeID: UUID(), configValid: false, success: false, failureStage: .config, errorMessage: "缺少密码")
        log.add(first)
        log.add(first)
        log.add(NodeTestResult(nodeID: UUID(), configValid: false, failureStage: .config, errorMessage: "缺少密码"))
        log.add(NodeTestResult(nodeID: UUID(), configValid: true, success: true))
        XCTAssertEqual(log.messages, ["节点测试失败 · 配置检查：缺少密码 · 2 个节点"])
    }

    func testDifferentReasonsStaySeparateAndSecretsAreRedacted() {
        var log = NodeTestFailureLog()
        log.add(NodeTestResult(nodeID: UUID(), failureStage: .http, errorMessage: "HTTPS 探测超时（2 秒）"))
        log.add(NodeTestResult(nodeID: UUID(), failureStage: .http, errorMessage: "HTTPS/TLS 握手失败"))
        log.add(NodeTestResult(nodeID: UUID(), failureStage: .config, errorMessage: "https://example.com/sub?token=private-secret"))
        XCTAssertEqual(log.messages.count, 3)
        XCTAssertFalse(log.messages.joined().contains("private-secret"))
    }

    func testLargeFailureGroupKeepsReasonAndCountWithoutLongNodeNames() {
        var log = NodeTestFailureLog()
        let reason = "REALITY 缺少 publicKey"
        for index in 1...48 {
            let name = "节点\(index)-" + String(repeating: "超长名称", count: 20)
            let node = ProxyNode(name: name, protocolType: .vless, server: "127.0.0.1", port: 443)
            let result = NodeTestResult(nodeID: node.id, configValid: false, failureStage: .config, errorMessage: reason)
            log.add(result)
            log.add(result)
        }

        XCTAssertEqual(log.messages, ["节点测试失败 · 配置检查：REALITY 缺少 publicKey · 48 个节点"])
        XCTAssertFalse(log.messages.joined().contains("超长名称"))
    }

    func testFailureSummaryCountBoundaries() {
        XCTAssertTrue(NodeTestFailureLog().messages.isEmpty)
        for count in [1, 3, 4, 48] {
            var log = NodeTestFailureLog()
            for _ in 0..<count {
                log.add(NodeTestResult(nodeID: UUID(), failureStage: .config, errorMessage: "gRPC 缺少 serviceName"))
            }
            XCTAssertEqual(log.messages, ["节点测试失败 · 配置检查：gRPC 缺少 serviceName · \(count) 个节点"])
        }
    }

    func testFailureCountUsesUniqueIDsEvenWhenNamesMatchAndRedactsReason() {
        var log = NodeTestFailureLog()
        let nodes = (0..<4).map { _ in
            ProxyNode(name: "重名-token=name-secret", protocolType: .vless, server: "127.0.0.1", port: 443)
        }
        for node in nodes {
            let result = NodeTestResult(nodeID: node.id, failureStage: .config, errorMessage: "password=reason-secret")
            log.add(result)
            log.add(result)
        }

        XCTAssertEqual(log.messages, ["节点测试失败 · 配置检查：password=•••••• · 4 个节点"])
        XCTAssertFalse(log.messages.joined().contains("secret"))
        XCTAssertFalse(log.messages.joined().contains("重名"))
    }

    func testCoreErrorsBelongToTheCorrectOutbound() {
        let output = """
        [Info] [101] app/dispatcher: taking detour [proxy-0] for [tcp:example.com:443]
        [Info] [102] app/dispatcher: taking detour [proxy-1] for [tcp:example.com:443]
        [Error] [101] transport/internet/websocket: failed to dial > EOF
        [Info] [102] proxy/trojan: read: connection reset by peer
        [Info] [103] proxy/trojan: x509: unrelated certificate error
        """
        XCTAssertEqual(NodeCoreFailure.reason(in: output, outboundTag: "proxy-0"), "代理握手或传输提前关闭（EOF）")
        XCTAssertEqual(NodeCoreFailure.reason(in: output, outboundTag: "proxy-1"), "代理连接被重置（远端或中间网络）")
        XCTAssertNil(NodeCoreFailure.reason(in: output, outboundTag: "proxy-2"))
        let singBox = "[ERROR] connection: open using outbound/hysteria2[proxy-2]: x509: unknown authority"
        XCTAssertEqual(NodeCoreFailure.reason(in: output + "\n" + singBox, outboundTag: "proxy-2"), "节点 TLS 证书校验失败")
        XCTAssertNil(NodeCoreFailure.reason(in: singBox, outboundTag: "proxy-20"))
    }

    func testCurlFailureCategories() {
        XCTAssertEqual(ProxyHTTPTester.failureReason(status: 60, timedOut: false, timeout: 2,
            diagnostic: "curl: (60) SSL: no alternative certificate subject name matches target host name 'chatgpt.com'"), "HTTPS 证书域名不匹配")
        XCTAssertEqual(ProxyHTTPTester.failureReason(status: 28, timedOut: false, timeout: 2), "HTTPS 探测超时（2 秒）")
        XCTAssertEqual(ProxyHTTPTester.failureReason(status: 35, timedOut: false, timeout: 2), "HTTPS/TLS 握手失败")
        XCTAssertEqual(ProxyHTTPTester.failureReason(status: 60, timedOut: false, timeout: 2), "HTTPS 证书校验失败")
        XCTAssertEqual(ProxyHTTPTester.failureReason(status: 56, timedOut: false, timeout: 2), "连接中断或被重置")
    }
    @MainActor
    func testBatchWritesMergedFailureToAppLogger() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = NodeTestManager(binaryURL: root.appendingPathComponent("HopWorld/Resources/xray"), testDirectory: directory)
        let nodes = [
            ProxyNode(name: "日志验证一", protocolType: .vless, server: "127.0.0.1", port: 1),
            ProxyNode(name: "日志验证二", protocolType: .vless, server: "127.0.0.1", port: 1)
        ]
        let started = Date()
        _ = await manager.startTest(nodes: nodes, settings: AppSettings(), silent: true) { _, _ in }
        let warnings = AppLogger.shared.entries.filter { $0.date >= started && $0.category == .test && $0.message.contains("缺少 UUID") }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.message, "节点测试失败 · 配置检查：缺少 UUID · 2 个节点")
        let details = try XCTUnwrap(manager.lastFinishedSummary).detailLines.joined(separator: "\n")
        XCTAssertTrue(details.contains("日志验证一"))
        XCTAssertTrue(details.contains("日志验证二"))
    }

}

@MainActor
final class XrayUpdateTests: XCTestCase {
    func testDailyCheckPersistsAcrossLaunchesAndResetsAtLocalMidnight() throws {
        let suite = "xray-update-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = ISO8601DateFormatter().date(from: "2026-10-12T15:59:00Z")!
        XCTAssertTrue(XrayUpdateManager.claimDailyCheck(defaults: defaults, now: start, calendar: calendar))
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(XrayUpdateManager.claimDailyCheck(defaults: relaunched, now: start.addingTimeInterval(30), calendar: calendar))
        XCTAssertTrue(XrayUpdateManager.claimDailyCheck(defaults: relaunched, now: start.addingTimeInterval(61), calendar: calendar))
        XCTAssertFalse(XrayUpdateManager.claimDailyCheck(defaults: defaults, now: start.addingTimeInterval(90), calendar: calendar))
    }

    func testReleaseValidationDigestAndNumericVersionOrdering() throws {
        let digest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let asset = XrayRelease.Asset(name: "fixture.zip", digest: digest)
        XCTAssertNoThrow(try asset.verify(Data("abc".utf8)))
        XCTAssertThrowsError(try asset.verify(Data("changed".utf8)))
        XCTAssertThrowsError(try XrayRelease.Asset(name: "fixture.zip", digest: nil).verify(Data()))
        XCTAssertTrue(XrayInstaller.isVersion("26.10.1", atLeast: "26.9.9"))
        XCTAssertFalse(XrayInstaller.isVersion("26.3.27", atLeast: "26.9.9"))
        XCTAssertTrue(XrayInstaller.isVersion("26.9.9", atLeast: "26.9.9"))
        for tag in ["v26.9.9-rc1", "v../../tmp", "26.9", "26.9.-1"] {
            XCTAssertThrowsError(try XrayRelease(tag_name: tag, draft: false, prerelease: false, assets: []).validatedVersion())
        }
        XCTAssertThrowsError(try XrayRelease(tag_name: "v26.10.1", draft: false, prerelease: true, assets: []).validatedVersion())
        XCTAssertThrowsError(try XrayRelease(tag_name: "v26.10.1", draft: true, prerelease: false, assets: []).validatedVersion())
        let decoded = try JSONDecoder().decode(XrayRelease.self, from: Data(#"{"tag_name":"v26.10.1","draft":false,"prerelease":false,"assets":[]}"#.utf8))
        XCTAssertEqual(try decoded.validatedVersion(), "26.10.1")
        XCTAssertThrowsError(try decoded.archiveAsset())
    }

    func testBothReleaseChannelsPersistAndPrereleaseRequiresExplicitOptIn() throws {
        let suite = "xray-channel-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let newest = XrayRelease(tag_name: "v26.10.10", draft: false, prerelease: true, assets: [])
        let stable = XrayRelease(tag_name: "v26.3.27", draft: false, prerelease: false, assets: [])
        XCTAssertThrowsError(try newest.validatedVersion())
        XCTAssertEqual(try newest.validatedVersion(allowPrerelease: true), "26.10.10")
        XCTAssertEqual(try stable.validatedVersion(), "26.3.27")
        defaults.set(try JSONEncoder().encode(newest), forKey: "xray.latestRelease")
        defaults.set(try JSONEncoder().encode(stable), forKey: "xray.stableRelease")
        let restored = XrayUpdateManager(defaults: defaults)
        XCTAssertEqual(restored.latestVersion, "26.10.10")
        XCTAssertEqual(restored.stableVersion, "26.3.27")
        XCTAssertEqual(restored.latestRelease?.prerelease, true)
        XCTAssertEqual(restored.stableRelease?.prerelease, false)
    }

    func testDownloadMirrorDefaultsToGitHubAndRewritesReleaseURL() throws {
        let suite = "xray-mirror-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = XrayUpdateManager(defaults: defaults)
        XCTAssertEqual(manager.downloadMirror, .github)
        let official = URL(string: "https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-macos-arm64-v8a.zip")!
        XCTAssertEqual(XrayDownloadMirror.github.rewrite(official), official)
        XCTAssertEqual(
            XrayDownloadMirror.ghproxyNet.rewrite(official).absoluteString,
            "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-macos-arm64-v8a.zip"
        )
        XCTAssertEqual(
            XrayDownloadMirror.ghfastTop.rewrite(official).absoluteString,
            "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-macos-arm64-v8a.zip"
        )
        manager.downloadMirror = .ghProxyCom
        XCTAssertEqual(defaults.string(forKey: XrayInstaller.downloadMirrorKey), XrayDownloadMirror.ghProxyCom.rawValue)
        let restored = XrayUpdateManager(defaults: defaults)
        XCTAssertEqual(restored.downloadMirror, .ghProxyCom)
    }

    func testAtomicActivationKeepsOldCoreAndRejectsBrokenPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-activation-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let first = try package(at: root.appendingPathComponent("first"), version: "26.9.9")
        let old = try await XrayInstaller.activateExtractedRelease(at: first, version: "26.9.9", directory: support)
        let pointer = support.appendingPathComponent("current/xray")
        XCTAssertEqual(pointer.resolvingSymlinksInPath(), old)
        let second = try package(at: root.appendingPathComponent("second"), version: "26.10.1")
        let new = try await XrayInstaller.activateExtractedRelease(at: second, version: "26.10.1", directory: support)
        XCTAssertEqual(pointer.resolvingSymlinksInPath(), new)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: old.path), "Running cores must retain their binary and assets")
        XCTAssertEqual(try Data(contentsOf: old.deletingLastPathComponent().appendingPathComponent("geoip.dat")), Data("fixture".utf8))
        try Data().write(to: second.appendingPathComponent("geosite.dat"))
        do {
            _ = try await XrayInstaller.activateExtractedRelease(at: second, version: "26.10.1", directory: support)
            XCTFail("Empty rule data must reject the update")
        } catch { }
        XCTAssertEqual(pointer.resolvingSymlinksInPath(), new)
        try Data("fixture".utf8).write(to: second.appendingPathComponent("geosite.dat"))
        do {
            _ = try await XrayInstaller.activateExtractedRelease(at: second, version: "26.11.1", directory: support)
            XCTFail("Binary version mismatch must reject the update")
        } catch { }
        XCTAssertEqual(pointer.resolvingSymlinksInPath(), new)
        let cores = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("cores"), includingPropertiesForKeys: nil)
        XCTAssertEqual(cores.count, 2, "Failed staging directories must be removed")
        let selectedStable = try await XrayInstaller.activateExtractedRelease(at: first, version: "26.9.9", directory: support)
        XCTAssertEqual(pointer.resolvingSymlinksInPath(), selectedStable, "Explicit stable selection must replace a newer preview")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: new.path))
    }

    private func package(at directory: URL, version: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf 'Xray \(version) fixture\\n'\n".utf8).write(to: directory.appendingPathComponent("xray"))
        for name in ["geoip.dat", "geosite.dat"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }
}

final class ThemeSettingsTests: XCTestCase {
    func testLegacySettingsFollowSystemWithoutResettingOtherPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.httpPort = 12809
        settings.autoFailover = false
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "theme")
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("settings.json"))
        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(restored.theme, .system)
        XCTAssertEqual(restored.httpPort, 12809)
        XCTAssertFalse(restored.autoFailover)
    }

    func testEveryThemePersistsAcrossReloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        let file = directory.appendingPathComponent("settings.json")
        for theme in AppTheme.allCases {
            var settings = AppSettings()
            settings.theme = theme
            settings.httpPort = 12809
            store.saveSettings(settings)
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: file),
                   let saved = try? JSONDecoder().decode(AppSettings.self, from: data), saved.theme == theme { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let restored = PersistenceStore(directory: directory).loadSettings()
            XCTAssertEqual(restored.theme, theme)
            XCTAssertEqual(restored.httpPort, 12809)
        }
    }

    func testApplyingOtherSettingsPreservesImmediateThemeChoice() {
        let baseline = AppSettings()
        var draft = baseline
        draft.httpPort = 12809
        var current = baseline
        current.theme = .dark
        let applied = current.applyingSettingsEdits(from: draft, comparedTo: baseline)
        XCTAssertEqual(applied.theme, .dark)
        XCTAssertEqual(applied.httpPort, 12809)
        draft.theme = .light
        XCTAssertEqual(current.applyingSettingsEdits(from: draft, comparedTo: baseline).theme, .light)
    }
}

final class SubscriptionTimeZoneSettingsTests: XCTestCase {
    func testDefaultRegionUsesTheCurrentSystemTimeZone() {
        XCTAssertEqual(AppSettings().defaultTimeZoneID, TimeZone.current.identifier)
    }

    func testMissingRegionUsesCurrentTimeZoneWithoutResettingOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.httpPort = 12809
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        saved.removeValue(forKey: "defaultTimeZoneID")
        try JSONSerialization.data(withJSONObject: saved).write(to: directory.appendingPathComponent("settings.json"))

        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(restored.defaultTimeZoneID, TimeZone.current.identifier)
        XCTAssertEqual(restored.httpPort, 12809)
    }

    func testManualRegionPersistsAndMergesWithSettingsDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var baseline = AppSettings()
        baseline.defaultTimeZoneID = "America/New_York"
        try JSONEncoder().encode(baseline).write(to: directory.appendingPathComponent("settings.json"))
        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(restored.defaultTimeZoneID, "America/New_York")

        var draft = restored
        draft.defaultTimeZoneID = "Europe/London"
        var current = restored
        current.testConcurrency = 8
        let merged = current.applyingSettingsEdits(from: draft, comparedTo: restored)
        XCTAssertEqual(merged.defaultTimeZoneID, "Europe/London")
        XCTAssertEqual(merged.testConcurrency, 8)
        XCTAssertEqual(restored.defaultTimeZoneID, "America/New_York")
    }
}

final class TestURLSettingsTests: XCTestCase {
    func testReachabilityAccepts403And429WithoutPageWarnings() {
        for status in [200, 204, 302, 403, 429, 503] {
            let outcome = ProxyHTTPTester.httpReachabilityOutcome(status: status, latency: 120,
                                                                  acceptAnyHTTPResponse: true)
            XCTAssertEqual(outcome.latency, 120)
            XCTAssertEqual(outcome.statusCode, status)
            XCTAssertNil(outcome.error)
            XCTAssertNil(outcome.warning)
        }
    }

    func testReachabilityRejectsMissingOrInvalidHTTPStatus() {
        for status in [0, 99, 600] {
            XCTAssertNil(ProxyHTTPTester.httpReachabilityOutcome(status: status, latency: 100,
                                                                acceptAnyHTTPResponse: true).latency)
        }
        XCTAssertNil(ProxyHTTPTester.httpReachabilityOutcome(status: 403, latency: 100).latency)
        XCTAssertNotNil(ProxyHTTPTester.httpReachabilityOutcome(status: 204, latency: 100).latency)
    }

    func testTracePresetSelectionMigratesToConnectivityEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.testURL = "https://chatgpt.com/cdn-cgi/trace"
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        XCTAssertEqual(PersistenceStore(directory: directory).loadSettings().testURL, AppSettings.chatGPTConnectivityTestURL)
    }

    func testHomepageSelectionMigratesToGenerate204AndKeepsName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.testURL = "https://chatgpt.com/"
        settings.customTestURLNames = [settings.testURL: "我的 ChatGPT 检测"]
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(restored.testURL, AppSettings.chatGPTConnectivityTestURL)
        XCTAssertEqual(restored.testURLDisplayTitle(restored.testURL), "我的 ChatGPT 检测")
    }

    func testRemovedStrictChatGPTSettingIsIgnoredWithoutResettingPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.httpPort = 12809
        settings.connectTimeoutSeconds = 99
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        old["strictChatGPTConnectivity"] = true
        try JSONSerialization.data(withJSONObject: old).write(to: directory.appendingPathComponent("settings.json"))
        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(restored.httpPort, 12809)
        XCTAssertEqual(restored.connectTimeoutSeconds, 99)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil(encoded["strictChatGPTConnectivity"])
    }

    func testConnectionTimeoutDefaultsToFifteenAndKeepsSavedCustomValues() throws {
        XCTAssertEqual(AppSettings().connectTimeoutSeconds, 15)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        var settings = AppSettings()
        settings.httpPort = 12809
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "connectTimeoutSeconds")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let defaults = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(defaults.connectTimeoutSeconds, 15)
        XCTAssertEqual(defaults.httpPort, 12809)
        for value in [1, 3, 15, 30, 99] {
            settings.connectTimeoutSeconds = value
            try JSONEncoder().encode(settings).write(to: file)
            XCTAssertEqual(PersistenceStore(directory: directory).loadSettings().connectTimeoutSeconds, value)
        }
        var draft = defaults
        draft.connectTimeoutSeconds = 99
        XCTAssertEqual(defaults.applyingSettingsEdits(from: draft, comparedTo: defaults).connectTimeoutSeconds, 99)
    }

    func testConnectionTimeoutLoadsWithinOneToNinetyNineSeconds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        var settings = AppSettings()
        for (stored, expected) in [(-1, 1), (0, 1), (100, 99), (Int.max, 99)] {
            settings.connectTimeoutSeconds = stored
            try JSONEncoder().encode(settings).write(to: file)
            XCTAssertEqual(PersistenceStore(directory: directory).loadSettings().connectTimeoutSeconds, expected)
        }
    }

    func testCodexConnectivityPresetPersistsAsOwnProbe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.testURL = AppSettings.codexConnectivityTestURL
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        let restored = PersistenceStore(directory: directory).loadSettings()
        XCTAssertEqual(restored.testURL, AppSettings.codexConnectivityTestURL)
        XCTAssertEqual(AppSettings.testURLTitle(restored.testURL), "Codex连通性检测")
        XCTAssertTrue(AppSettings.presetTestURLs.contains(restored.testURL))
        XCTAssertEqual(restored.testURLDisplayTitle(restored.testURL), "Codex连通性检测")
    }

    func testPresetsAndCustomURLsPersistWithoutDuplicates() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.availableTestURLs.count, 8)
        XCTAssertTrue(settings.availableTestURLs.contains("http://www.msftconnecttest.com/connecttest.txt"))
        XCTAssertTrue(settings.availableTestURLs.contains(AppSettings.codexConnectivityTestURL))
        settings.customTestURLs = ["https://example.com/probe", AppSettings.presetTestURLs[0]]
        settings.testURL = "https://legacy.example.com/check"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.availableTestURLs.count, 10)
        XCTAssertEqual(restored.testURL, settings.testURL)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "customTestURLs")
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).customTestURLs)
    }

    func testHTTPSelectionPreservesProtocolAndValidatesInput() throws {
        let raw = "http://www.msftconnecttest.com/connecttest.txt"
        let url = try XCTUnwrap(AppSettings.validatedTestURL(raw))
        XCTAssertEqual(ProxyHTTPTester.primaryHTTPURL(from: url)?.absoluteString, raw)
        for invalid in ["ftp://example.com/test", "https://", "example.com", "https://user:pass@example.com"] {
            XCTAssertNil(AppSettings.validatedTestURL(invalid))
        }
        var baseline = AppSettings()
        baseline.customTestURLs = []
        var draft = baseline
        draft.customTestURLs = [raw]
        draft.testURL = raw
        let merged = baseline.applyingSettingsEdits(from: draft, comparedTo: baseline)
        XCTAssertEqual(merged.customTestURLs, [raw])
        XCTAssertEqual(merged.testURL, raw)
    }

    func testCustomURLNamesPersistAndMergeWithSettingsDraft() throws {
        let baseline = AppSettings()
        let url = "https://example.com/check"
        var draft = baseline
        draft.customTestURLs = [url]
        draft.customTestURLNames = [url: "我的连通检测"]
        let merged = baseline.applyingSettingsEdits(from: draft, comparedTo: baseline)
        let data = try JSONEncoder().encode(merged)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored.testURLDisplayTitle(url), "我的连通检测")
        XCTAssertEqual(restored.testURLDisplayTitle(AppSettings.chatGPTConnectivityTestURL), "ChatGPT 连通性检测")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "customTestURLNames")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.testURLDisplayTitle(url), "example.com")
    }

    func testGenerate204AdditionPreservesHostAndReplacesPath() {
        let raw = "https://example.com:8443/old/path?q=1#section"
        XCTAssertEqual(AppSettings.testURLForAddition(raw, useGenerate204: false)?.absoluteString, raw)
        XCTAssertEqual(AppSettings.testURLForAddition(raw, useGenerate204: true)?.absoluteString,
                       "https://example.com:8443/generate_204")
        XCTAssertEqual(AppSettings.testURLForAddition("http://example.com/generate_204", useGenerate204: true)?.absoluteString,
                       "http://example.com/generate_204")
        XCTAssertNil(AppSettings.testURLForAddition("ftp://example.com", useGenerate204: true))
        XCTAssertNil(AppSettings.testURLForAddition("https://user:pass@example.com", useGenerate204: true))
    }
}

final class TemporaryNodeBlockTests: XCTestCase {
    func testBlockIsPerNodePersistentAndReversible() throws {
        var settings = AppSettings()
        var node = ProxyNode(name: "US blocked", protocolType: .vless, server: "example.com", port: 443)
        node.lastLatency = 100
        node.lastTestStatus = .fast
        var other = ProxyNode(name: "US other", protocolType: .vless, server: "other.example.com", port: 443)
        other.lastLatency = 100
        other.lastTestStatus = .fast
        settings.temporarilyBlockedNodeIDs = [node.id]
        XCTAssertFalse(settings.allowsAutoSelectNode(node))
        XCTAssertTrue(settings.allowsAutoSelectNode(other))
        XCTAssertTrue(settings.allowsAutoSelectNode(node, includingTemporarilyBlocked: true))
        var restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.isTemporarilyBlocked(node.id))
        restored.temporarilyBlockedNodeIDs?.remove(node.id)
        XCTAssertTrue(restored.allowsAutoSelectNode(node))
        var oldSettings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        oldSettings.removeValue(forKey: "temporarilyBlockedNodeIDs")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: oldSettings))
        XCTAssertFalse(migrated.isTemporarilyBlocked(node.id))
    }
}

@MainActor
final class ConnectionCandidatesGuidanceTests: XCTestCase {
    func testGuidanceExplainsBlocksAndRecoveryWithoutUnblocking() {
        let message = AppSettings.connectionCandidatesGuidance(blockedCount: 3, hasNodes: true)
        XCTAssertTrue(message.contains("3 个节点"))
        XCTAssertTrue(message.contains("关闭临时屏蔽"))
        XCTAssertTrue(message.contains("测试应用连通"))
        XCTAssertTrue(message.contains("不会自动解除"))
        let empty = AppSettings.connectionCandidatesGuidance(blockedCount: 0, hasNodes: false)
        XCTAssertTrue(empty.contains("添加订阅"))
        XCTAssertFalse(empty.contains("3 个节点"))
    }
}

final class QuickSwitchCountsTests: XCTestCase {
    func testCountsSeparateFilteredAndBlockedNodes() {
        var settings = AppSettings()
        var available = ProxyNode(name: "US available", protocolType: .vless, server: "example.com", port: 443)
        available.lastLatency = 100
        available.lastTestStatus = .fast
        var filtered = ProxyNode(name: "HK filtered", protocolType: .vless, server: "example.com", port: 443)
        filtered.lastTestStatus = .fast
        filtered.lastLatency = 100
        let blocked = ProxyNode(name: "US blocked", protocolType: .vless, server: "example.com", port: 443)
        settings.autoSelectExcludedCountryCodes = ["HK"]
        settings.temporarilyBlockedNodeIDs = [blocked.id]
        let counts = settings.quickSwitchCounts(for: [available, filtered, blocked])
        XCTAssertEqual(counts.available, 1)
        XCTAssertEqual(counts.filtered, 1)
        XCTAssertEqual(counts.blocked, 1)
    }
}

final class MasqueTests: XCTestCase {
    func testLinkRoundTripWithIPv6AndEncodedCredentials() throws {
        let node = ProxyNode(name: "MASQUE 测试", protocolType: .masque, server: "2001:db8::1", port: 8443,
                             password: "p:%40@/?#", username: "user%40@example.com",
                             masqueHeaders: ["X-Token": "a,b"], masqueRemoteDNS: ["1.1.1.1", "2606:4700:4700::1111"],
                             transport: .masque, security: .tls, sni: "masque.example.com", host: "authority.example.com:8443",
                             path: "/ip/{target}/{ipproto}/", alpn: "h2", pinnedCertSHA256: String(repeating: "ab", count: 32))
        let link = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: node))
        let parsed = try NodeLinkParser.parse(link)
        XCTAssertEqual(parsed.server, node.server)
        XCTAssertEqual(parsed.password, node.password)
        XCTAssertEqual(parsed.username, node.username)
        XCTAssertEqual(parsed.name, node.name)
        XCTAssertEqual(parsed.masqueHeaders, node.masqueHeaders)
        XCTAssertEqual(parsed.masqueRemoteDNS, node.masqueRemoteDNS)
        XCTAssertEqual(NodeFingerprint.make(from: parsed), NodeFingerprint.make(from: node))
        XCTAssertFalse(LogRedactor.redact(link).contains("user%40"))
        XCTAssertFalse(LogRedactor.redact(link).contains("headers="))
        let bearer = try MasqueParser.parse("masque://example.com?headers=%7B%22Authorization%22:%22Bearer%20fixture-token%22%7D")
        XCTAssertEqual(bearer.port, 443)
        XCTAssertEqual(bearer.masqueHeaders?["Authorization"], "Bearer fixture-token")
        let bearerLink = try XCTUnwrap(ShareLinkExporter.makeShareLink(from: bearer))
        XCTAssertEqual(try MasqueParser.parse(bearerLink).masqueHeaders, bearer.masqueHeaders)
    }

    func testClashAndBase64SubscriptionImport() throws {
        let yaml = """
        proxies:
          - name: MASQUE test
            type: masque
            server: example.com
            port: 443
            username: alice
            password: secret
            alpn: [h2]
            host: example.com
            path: /ip/{target}/{ipproto}/
            headers:
              X-Token: test
            remote-dns: [1.1.1.1, '2606:4700:4700::1111']
        """
        let node = try XCTUnwrap(ClashYAMLParser.parse(yaml).validNodes.first)
        XCTAssertEqual(node.protocolType, .masque)
        XCTAssertEqual(node.username, "alice")
        XCTAssertEqual(node.masqueHeaders?["x-token"], "test")
        XCTAssertEqual(node.masqueRemoteDNS, ["1.1.1.1", "2606:4700:4700::1111"])
        let links = "masque://alice:secret@example.com:443#One" + "vless://11111111-1111-4111-8111-111111111111@example.com:443?security=tls#Two"
        let plain = try SubscriptionContentParser.parse(data: Data(links.utf8))
        XCTAssertEqual(plain.validNodes.map(\.protocolType), [.masque, .vless])
        let base64 = Data(Data(links.utf8).base64EncodedString().utf8)
        XCTAssertEqual(try SubscriptionContentParser.parse(data: base64).validNodes.map(\.protocolType), [.masque, .vless])
    }

    func testMalformedAndUnsupportedOptionsFailClosed() throws {
        for suffix in [":0", ":65536", ":443?security=none", ":443?type=ws", ":443?insecure=1",
                       ":443?warp=true", ":443?alpn=http/1.1", ":443?path=relative", ":443?path=/%7Bother%7D",
                       ":443?remoteDNS=example.com", ":443?pinSHA256=abc", ":443?headers=invalid",
                       ":443?alpn=h2&alpn=h3", ":443?host=example.com/path", ":443?headers=%7B%22Host%22:%22x%22%7D",
                       ":443?headers=%7B%22X-Token%22:%22a%5Cr%5Cnb%22%7D",
                       ":443?headers=%7B%22Authorization%22:%22Bearer%20token%22%7D"] {
            XCTAssertThrowsError(try MasqueParser.parse("masque://user:pass@example.com" + suffix), suffix)
        }
        XCTAssertThrowsError(try MasqueParser.parse("masque://user%3Aname:pass@example.com:443"))
        let invalid = Data("masque://example.com:443?insecure=1".utf8)
        XCTAssertThrowsError(try SubscriptionContentParser.parse(data: invalid))
        XCTAssertThrowsError(try ClashYAMLParser.parse("proxies: [{type: masque, name: n, server: example.com, port: 443, skip-cert-verify: true}]"))
    }

    func testPersistenceAndSubscriptionAuthenticationChanges() throws {
        var old = try MasqueParser.parse("masque://alice:old-password@example.com:443?alpn=h2#Stable")
        old.isFavorite = true
        old.note = "keep"
        old.lastTestStatus = .fast
        old.lastLatency = 100
        var incoming = old
        incoming.username = nil
        incoming.password = nil
        incoming.masqueHeaders = ["Authorization": "Bearer new-token"]
        incoming.masqueRemoteDNS = ["1.0.0.1"]
        incoming.pinnedCertSHA256 = String(repeating: "ab", count: 32)
        XCTAssertNotEqual(NodeFingerprint.make(from: old), NodeFingerprint.make(from: incoming))
        let merged = try XCTUnwrap(SubscriptionMerger.buildPlan(mode: .smartMerge, oldNodes: [old], newNodes: [incoming], missingLimit: 3).resultingNodes.first)
        XCTAssertEqual(merged.id, old.id)
        XCTAssertTrue(merged.isFavorite)
        XCTAssertEqual(merged.note, "keep")
        XCTAssertNil(merged.username)
        XCTAssertNil(merged.password)
        XCTAssertEqual(merged.masqueHeaders, incoming.masqueHeaders)
        XCTAssertEqual(merged.masqueRemoteDNS, incoming.masqueRemoteDNS)
        XCTAssertEqual(merged.pinnedCertSHA256, incoming.pinnedCertSHA256)
        XCTAssertEqual(merged.lastTestStatus, .untested)
        let restored = try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(restored, merged)
        let snapshot = LibrarySnapshot(nodes: [merged], subscriptions: [], updateLogs: [])
        let redacted = try LibraryBackup.export(snapshot: snapshot, passphrase: "fixture", includeCredentials: false)
        let redactedNode = try XCTUnwrap(LibraryBackup.importBackup(from: redacted, passphrase: "fixture").snapshot.nodes.first)
        XCTAssertNil(redactedNode.masqueHeaders)
        XCTAssertNil(redactedNode.username)
        XCTAssertNil(redactedNode.password)
        let complete = try LibraryBackup.export(snapshot: snapshot, passphrase: "fixture", includeCredentials: true)
        XCTAssertEqual(try LibraryBackup.importBackup(from: complete, passphrase: "fixture").snapshot.nodes.first?.masqueHeaders, incoming.masqueHeaders)
        let legacy = ProxyNode(name: "old", protocolType: .trojan, server: "example.com", port: 443, password: "fixture")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        for key in ["username", "masqueHeaders", "masqueRemoteDNS"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ProxyNode.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.protocolType, .trojan)
        XCTAssertNil(decoded.masqueHeaders)
        var changed = incoming
        changed.masqueRemoteDNS = ["8.8.8.8"]
        XCTAssertNotEqual(NodeFingerprint.make(from: incoming), NodeFingerprint.make(from: changed))
    }

    func testCoreConfigurationsAndOldCoreUpgradeMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        var node = try MasqueParser.parse("masque://alice:secret@example.com:443?alpn=h3")
        let ports = XrayConfigBuilder.LocalPorts(socksHost: "127.0.0.1", socksPort: 29001, httpHost: "127.0.0.1", httpPort: 29002)
        for alpn in ["h2", "h3"] {
            node.alpn = alpn
            for mode in RoutingMode.allCases {
                let config = try XrayConfigBuilder.build(node: node, ports: ports, routingMode: mode)
                let outputs = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
                let outbound = try XCTUnwrap(outputs.first { $0["tag"] as? String == "proxy" })
                XCTAssertEqual(outbound["protocol"] as? String, "masque")
                XCTAssertNil(outbound["mux"])
                let file = directory.appendingPathComponent("config.json")
                try XrayConfigBuilder.writeJSON(config, to: file)
                let valid = try await XrayValidator.validateConfigFile(at: file, xrayURL: binary)
                XCTAssertTrue(valid, "\(alpn) / \(mode)")
            }
        }
        let ordinary = ProxyNode(name: "TLS", protocolType: .vless, server: "example.com", port: 443,
                                 uuid: "11111111-1111-4111-8111-111111111111", security: .tls)
        let batch = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 29001), (ordinary, 29002)])
        let file = directory.appendingPathComponent("mixed.json")
        try XrayConfigBuilder.writeJSON(batch, to: file)
        let mixedValid = try await XrayValidator.validateConfigFile(at: file, xrayURL: binary)
        XCTAssertTrue(mixedValid)
        let oldBinary = directory.appendingPathComponent("old-xray")
        try Data("#!/bin/sh\necho 'Xray 26.9.9'\n".utf8).write(to: oldBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oldBinary.path)
        let manager = XrayProcessManager(binaryURL: oldBinary)
        do {
            try await manager.start(configURL: file)
            XCTFail("An old core must provide an upgrade message")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("MASQUE 需要 Xray"))
        }
        await manager.stop()
    }

    func testRealHTTP2Tunnel() async throws { try await localTunnel(alpn: "h2") }
    func testRealHTTP3Tunnel() async throws { try await localTunnel(alpn: "h3") }

    @MainActor
    private func localTunnel(alpn: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        let reservation = try LocalTestPorts(count: 5)
        let ports = reservation.ports
        let cert = directory.appendingPathComponent("cert.pem")
        let key = directory.appendingPathComponent("key.pem")
        let generation = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path,
            "-days", "1", "-subj", "/CN=localhost"
        ], timeout: 5)
        XCTAssertEqual(generation.status, 0)
        let der = directory.appendingPathComponent("cert.der")
        let convert = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: [
            "x509", "-in", cert.path, "-outform", "DER", "-out", der.path
        ], timeout: 5)
        XCTAssertEqual(convert.status, 0)
        let pin = CryptoUtil.sha256Hex(try Data(contentsOf: der))
        let serverConfig: [String: Any] = [
            "log": ["loglevel": "info"],
            "inbounds": [["listen": "127.0.0.1", "port": ports[0], "protocol": "masque",
                "settings": ["users": [["email": "alice", "pass": "secret"]], "address": ["10.77.0.1/24"]],
                "streamSettings": ["network": "masque", "security": "tls", "masqueSettings": ["path": "/test/ip/{target}/{ipproto}/"],
                    "tlsSettings": ["alpn": [alpn], "certificates": [["certificateFile": cert.path, "keyFile": key.path]]]]]],
            // The client netstack owns loopback; route documentation IPs to local fixtures at the server.
            "outbounds": [
                ["tag": "target-tcp", "protocol": "freedom", "settings": ["redirect": "127.0.0.1:\(ports[1])", "finalRules": [
                    ["action": "allow", "network": "tcp", "ip": ["127.0.0.1", "203.0.113.7"], "port": "\(ports[1])"]
                ]]],
                ["tag": "target-udp", "protocol": "freedom", "settings": ["redirect": "127.0.0.1:\(ports[3])", "finalRules": [
                    ["action": "allow", "network": "udp", "ip": ["127.0.0.1", "203.0.113.7"], "port": "\(ports[3])"]
                ]]]
            ],
            "routing": ["rules": [["type": "field", "network": "udp", "outboundTag": "target-udp"]]]
        ]
        let serverFile = directory.appendingPathComponent("server.json")
        try XrayConfigBuilder.writeJSON(serverConfig, to: serverFile)
        reservation.release()
        let server = XrayProcessManager(binaryURL: binary)
        defer { Task { await server.stop() } }
        try await server.start(configURL: serverFile)
        let payload = Data("MASQUE \(alpn) verified tunnel payload".utf8)
        try payload.write(to: directory.appendingPathComponent("probe.txt"))
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        target.arguments = ["-m", "http.server", "\(ports[1])", "--bind", "127.0.0.1", "--directory", directory.path]
        target.standardOutput = FileHandle.nullDevice
        target.standardError = FileHandle.nullDevice
        try target.run()
        defer { if target.isRunning { target.terminate(); target.waitUntilExit() } }
        let node = try MasqueParser.parse("masque://alice:secret@127.0.0.1:\(ports[0])?alpn=\(alpn)&sni=localhost&pinSHA256=\(pin)&path=%2Ftest%2Fip%2F%7Btarget%7D%2F%7Bipproto%7D%2F")
        XCTAssertTrue(NodeConfigChecker.validate(node).0)
        let clientFile = directory.appendingPathComponent("client.json")
        var config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, ports[2])])
        var inbounds = config["inbounds"] as! [[String: Any]]
        inbounds.append(["tag": "udp-test", "listen": "127.0.0.1", "port": ports[4], "protocol": "socks",
                         "settings": ["udp": true, "auth": "noauth"]])
        config["inbounds"] = inbounds
        var routing = config["routing"] as! [String: Any]
        var rules = routing["rules"] as! [[String: Any]]
        rules.insert(["type": "field", "inboundTag": ["udp-test"], "outboundTag": "proxy-0"], at: 0)
        routing["rules"] = rules
        config["routing"] = routing
        try XrayConfigBuilder.writeJSON(config, to: clientFile)
        let client = XrayProcessManager(binaryURL: binary)
        defer { Task { await client.stop() } }
        try await client.start(configURL: clientFile)
        for _ in 0..<30 {
            if await TCPTester.measure(host: "127.0.0.1", port: ports[1], timeout: 0.1) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let output = directory.appendingPathComponent("received.txt")
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
            "--silent", "--fail", "--noproxy", "", "--max-time", "5", "--proxy", "http://127.0.0.1:\(ports[2])",
            "http://203.0.113.7:\(ports[1])/probe.txt", "-o", output.path
        ], timeout: 7)
        if result.status != 0 {
            print(await server.readRecentOutput())
            print(await client.readRecentOutput())
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: output), payload)
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        echo.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',int(sys.argv[1]))); s.settimeout(10); d,a=s.recvfrom(4096); s.sendto(d,a)", "\(ports[3])"]
        echo.standardOutput = FileHandle.nullDevice
        echo.standardError = FileHandle.nullDevice
        try echo.run()
        defer { if echo.isRunning { echo.terminate(); echo.waitUntilExit() } }
        let udpCheck = #"""
        import socket, struct, sys
        with socket.create_connection(('127.0.0.1', int(sys.argv[1])), 5) as control:
            control.sendall(b'\x05\x01\x00')
            reader = control.makefile('rb')
            assert reader.read(2) == b'\x05\x00'
            control.sendall(b'\x05\x03\x00\x01' + bytes(6))
            reply = reader.read(10)
            assert reply[:4] == b'\x05\x00\x00\x01', reply
            relay = (socket.inet_ntoa(reply[4:8]), struct.unpack('!H', reply[8:10])[0])
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.bind(('127.0.0.1', 0))
                udp.settimeout(5)
                payload = b'masque-udp-round-trip'
                packet = b'\x00\x00\x00\x01' + socket.inet_aton('203.0.113.7') + struct.pack('!H', int(sys.argv[2])) + payload
                udp.sendto(packet, relay)
                response = udp.recvfrom(4096)[0]
                assert response == packet, response
        """#
        let udp = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", udpCheck, "\(ports[4])", "\(ports[3])"], timeout: 7)
        XCTAssertEqual(udp.status, 0, String(decoding: udp.output, as: UTF8.self))
        await client.stop()
        if alpn == "h2" {
            for badCertificate in [false, true] {
                var invalid = node
                if badCertificate { invalid.pinnedCertSHA256 = String(repeating: "00", count: 32) }
                else { invalid.password = "wrong-password" }
                try XrayConfigBuilder.writeJSON(XrayConfigBuilder.buildTestConfig(nodes: [(invalid, ports[2])]), to: clientFile)
                try await client.start(configURL: clientFile)
                let rejected = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                    "--silent", "--fail", "--noproxy", "", "--max-time", "2", "--proxy", "http://127.0.0.1:\(ports[2])",
                    "http://203.0.113.7:\(ports[1])/probe.txt", "-o", "/dev/null"
                ], timeout: 4)
                XCTAssertNotEqual(rejected.status, 0, badCertificate ? "Wrong certificate pin must fail" : "Wrong credentials must fail")
                await client.stop()
            }
        }
        await server.stop()
    }
}

final class SingBoxConnectionTests: XCTestCase {
    func testLegacyHTTPTransportSelectionAndImport() throws {
        for protocolType in [ProxyProtocolType.vless, .vmess, .trojan] {
            for transport in [TransportType.h2, .http] {
                var node = ProxyNode(name: "HTTP transport", protocolType: protocolType, server: "example.com", port: 443,
                                     uuid: "11111111-1111-4111-8111-111111111111", password: "fixture",
                                     transport: transport, security: .tls, sni: "tls.example.com", host: "one.example,two.example",
                                     path: "/legacy", fingerprint: "chrome", alpn: "h2")
                XCTAssertTrue(SingBoxConnectionConfig.requiresSingBox(node))
                XCTAssertTrue(NodeConfigChecker.validate(node).0)
                let upstream = try SingBoxConnectionConfig.outbound(node)
                let http = try XCTUnwrap(upstream["transport"] as? [String: Any])
                XCTAssertEqual(http["type"] as? String, "http")
                XCTAssertEqual(http["host"] as? [String], ["one.example", "two.example"])
                XCTAssertEqual(http["path"] as? String, "/legacy")
                let tls = try XCTUnwrap(upstream["tls"] as? [String: Any])
                XCTAssertEqual(tls["server_name"] as? String, "tls.example.com")
                XCTAssertEqual(tls["insecure"] as? Bool, false)
                XCTAssertEqual(tls["alpn"] as? [String], ["h2"])
                let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 29001)])
                let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
                XCTAssertNotNil(outbounds.first { $0["tag"] as? String == "proxy-0" }?[SingBoxConnectionConfig.marker])
                let connection = try XrayConfigBuilder.build(node: node, ports: .init(socksHost: "127.0.0.1", socksPort: 10808,
                    httpHost: "127.0.0.1", httpPort: 10809), routingMode: .global)
                XCTAssertNotNil((connection["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }?[SingBoxConnectionConfig.marker])
                node.pinnedCertSHA256 = String(repeating: "ab", count: 32)
                XCTAssertFalse(NodeConfigChecker.validate(node).0)
                node.pinnedCertSHA256 = nil
                node.security = .reality
                node.publicKey = "public-key"
                XCTAssertFalse(NodeConfigChecker.validate(node).0)
            }
        }
        let yaml = """
        proxies:
        - name: H2 fixture
          type: vless
          server: example.com
          port: 80
          uuid: 11111111-1111-4111-8111-111111111111
          network: h2
          h2-opts:
            host:
            - one.example
            - two.example
            path: /legacy
        """
        let node = try XCTUnwrap(ClashYAMLParser.parse(yaml).validNodes.first)
        XCTAssertEqual(node.host, "one.example,two.example")
        XCTAssertEqual(node.path, "/legacy")
        XCTAssertTrue(NodeConfigChecker.validate(node).0)
        XCTAssertEqual(try TrojanParser.parse("trojan://fixture@example.com:443?type=h2").transport, .h2)
    }

    func testRealLegacyHTTPAndH2Forwarding() async throws {
        func stop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        guard let xray = await XrayProcessManager.resolveBinaryURLForTesting() else { throw XCTSkip("Xray unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("h2-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try await SingBoxInstaller.prepare(in: directory)
        let generated = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-days", "1",
            "-keyout", directory.appendingPathComponent("key.pem").path, "-out", directory.appendingPathComponent("cert.pem").path
        ], timeout: 10)
        XCTAssertEqual(generated.status, 0)
        let payload = Data("legacy-http-transport-round-trip".utf8)
        try payload.write(to: directory.appendingPathComponent("probe.txt"))
        for protocolType in [ProxyProtocolType.vless, .vmess, .trojan] {
            for useTLS in [false, true] where useTLS || protocolType != .trojan {
                let reservation = try LocalTestPorts(count: 3)
                let ports = reservation.ports
                let uuid = "11111111-1111-4111-8111-111111111111"
                var inbound: [String: Any] = ["type": protocolType.rawValue, "listen": "127.0.0.1", "listen_port": ports[0],
                    "users": protocolType == .trojan ? [["password": "fixture"]] : [["uuid": uuid]],
                    "transport": ["type": "http", "host": ["transport.example"], "path": "/legacy"]]
                if useTLS {
                    inbound["tls"] = ["enabled": true, "alpn": ["h2"], "certificate_path": directory.appendingPathComponent("cert.pem").path,
                                      "key_path": directory.appendingPathComponent("key.pem").path]
                }
                let serverFile = directory.appendingPathComponent("server.json")
                try XrayConfigBuilder.writeJSON(["inbounds": [inbound], "outbounds": [["type": "direct"]]], to: serverFile)
                func start(_ executable: String, _ arguments: [String]) throws -> Process {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    return process
                }
                reservation.release()
                let server = try start(binary.path, ["run", "-c", serverFile.path])
                defer { stop(server) }
                let target = try start("/usr/bin/python3", ["-m", "http.server", "\(ports[1])", "--bind", "127.0.0.1", "--directory", directory.path])
                defer { stop(target) }
                var node = ProxyNode(name: "H2 fixture", protocolType: protocolType, server: "127.0.0.1", port: ports[0],
                    uuid: uuid, password: "fixture", transport: .h2, security: useTLS ? .tls : .none,
                    sni: "localhost", host: "transport.example", path: "/legacy", allowInsecure: useTLS)
                let file = directory.appendingPathComponent("client.json")
                let manager = XrayProcessManager(binaryURL: xray)
                do {
                    for rejectCertificate in useTLS ? [true, false] : [false] {
                        node.allowInsecure = useTLS && !rejectCertificate
                        try await XrayConfigBuilder.writeTestConfig(nodes: [(node, ports[2])], to: file)
                        try await manager.start(configURL: file)
                        let output = directory.appendingPathComponent("received")
                        let curl = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                            "--silent", "--fail", "--noproxy", "", "--max-time", "3", "--proxy", "http://127.0.0.1:\(ports[2])",
                            "http://127.0.0.1:\(ports[1])/probe.txt", "-o", output.path
                        ], timeout: 4)
                        if rejectCertificate { XCTAssertNotEqual(curl.status, 0, "Untrusted certificate must fail") }
                        else {
                            let diagnostic = await manager.readRecentOutput()
                            XCTAssertEqual(curl.status, 0, "\(protocolType) TLS=\(useTLS): \(diagnostic)")
                            XCTAssertEqual(try Data(contentsOf: output), payload)
                        }
                        await manager.stop()
                    }
                } catch { await manager.stop(); throw error }
                let executables = await manager.connectionCoreExecutables()
                XCTAssertTrue(executables.isEmpty)
            }
        }
    }

    func testCFBBridgeSelectionAndValidation() throws {
        for method in ["aes-128-cfb", "aes-192-cfb", "aes-256-cfb"] {
            var node = ProxyNode(name: "legacy", protocolType: .shadowsocks, server: "example.com", port: 443,
                                 password: "fixture-password", method: " \(method.uppercased()) ")
            XCTAssertTrue(SingBoxConnectionConfig.requiresSingBox(node))
            XCTAssertTrue(NodeConfigChecker.validate(node).0)
            let upstream = try SingBoxConnectionConfig.outbound(node)
            XCTAssertEqual(upstream["method"] as? String, method)
            let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 29001)])
            let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
            XCTAssertNotNil(outbounds.first { $0["tag"] as? String == "proxy-0" }?[SingBoxConnectionConfig.marker])
            let ports = XrayConfigBuilder.LocalPorts(socksHost: "127.0.0.1", socksPort: 10808, httpHost: "127.0.0.1", httpPort: 10809)
            let connection = try XrayConfigBuilder.build(node: node, ports: ports, routingMode: .global)
            let outputs = try XCTUnwrap(connection["outbounds"] as? [[String: Any]])
            XCTAssertNotNil(outputs.first { $0["tag"] as? String == "proxy" }?[SingBoxConnectionConfig.marker])
            node.transport = .ws
            XCTAssertFalse(NodeConfigChecker.validate(node).0)
            node.transport = .tcp
            node.security = .tls
            XCTAssertFalse(NodeConfigChecker.validate(node).0)
            node.security = .none
            node.finalMaskJSON = #"{"tcp":[{"type":"fragment"}]}"#
            XCTAssertFalse(NodeConfigChecker.validate(node).0)
        }
    }

    func testRC4MD5BridgeSelectionAndValidation() throws {
        var node = ProxyNode(name: "legacy", protocolType: .shadowsocks, server: "example.com", port: 443,
                             password: "fixture-password", method: " RC4-MD5 ")
        XCTAssertTrue(SingBoxConnectionConfig.requiresSingBox(node))
        XCTAssertTrue(NodeConfigChecker.validate(node).0)
        let upstream = try SingBoxConnectionConfig.outbound(node)
        XCTAssertEqual(upstream["type"] as? String, "shadowsocks")
        XCTAssertEqual(upstream["method"] as? String, "rc4-md5")
        XCTAssertEqual(upstream["password"] as? String, node.password)
        var aead = node
        aead.method = "aes-128-gcm"
        XCTAssertFalse(SingBoxConnectionConfig.requiresSingBox(aead))
        let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 29001), (aead, 29002)])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertNotNil(outbounds.first { $0["tag"] as? String == "proxy-0" }?[SingBoxConnectionConfig.marker])
        XCTAssertEqual(outbounds.first { $0["tag"] as? String == "proxy-1" }?["protocol"] as? String, "shadowsocks")
        let ports = XrayConfigBuilder.LocalPorts(socksHost: "127.0.0.1", socksPort: 10808, httpHost: "127.0.0.1", httpPort: 10809)
        for mode in RoutingMode.allCases {
            let connection = try XrayConfigBuilder.build(node: node, ports: ports, routingMode: mode)
            let outputs = try XCTUnwrap(connection["outbounds"] as? [[String: Any]])
            XCTAssertNotNil(outputs.first { $0["tag"] as? String == "proxy" }?[SingBoxConnectionConfig.marker])
        }
        node.transport = .ws
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
        node.transport = .tcp
        node.security = .tls
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
        node.security = .none
        node.finalMaskJSON = #"{"tcp":[{"type":"fragment"}]}"#
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
        node.finalMaskJSON = nil
        node.password = nil
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
        node.password = "fixture-password"
        node.method = "unknown-cipher"
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
    }

    func testMalformedBridgeConfigCleansUpWithoutStartingPrimary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.json")
        try XrayConfigBuilder.writeJSON(["outbounds": [["tag": "proxy", SingBoxConnectionConfig.marker: true]]], to: file)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manager = XrayProcessManager(binaryURL: root.appendingPathComponent("HopWorld/Resources/xray"))
        do {
            try await manager.start(configURL: file)
            XCTFail("Malformed bridge configuration must fail")
        } catch {
            let running = await manager.isRunning()
            let executables = await manager.connectionCoreExecutables()
            XCTAssertFalse(running)
            XCTAssertTrue(executables.isEmpty)
        }
        await manager.stop()
    }

    func testAutomaticSelectionAndMixedBatch() throws {
        var node = ProxyNode(name: "VLESS", protocolType: .vless, server: "example.com", port: 80,
                             uuid: "11111111-1111-4111-8111-111111111111", transport: .ws, host: "cdn.example.com", path: "/ws")
        XCTAssertTrue(SingBoxConnectionConfig.requiresSingBox(node))
        XCTAssertTrue(NodeConfigChecker.validate(node).0)
        let upstream = try SingBoxConnectionConfig.outbound(node)
        let transport = try XCTUnwrap(upstream["transport"] as? [String: Any])
        XCTAssertEqual(transport["path"] as? String, "/ws")
        XCTAssertEqual((transport["headers"] as? [String: String])?["Host"], "cdn.example.com")
        var tlsNode = node
        tlsNode.security = .tls
        XCTAssertFalse(SingBoxConnectionConfig.requiresSingBox(tlsNode))
        let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 29001), (tlsNode, 29002)])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.filter { $0[SingBoxConnectionConfig.marker] != nil }.count, 1)
        XCTAssertEqual(outbounds.first { $0["tag"] as? String == "proxy-1" }?["protocol"] as? String, "vless")
        node.transport = .xhttp
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
        node.transport = .ws
        node.uuid = nil
        XCTAssertFalse(NodeConfigChecker.validate(node).0)
    }

    @MainActor
    func testRealPlainVLESSForwardingAndCleanup() async throws {
        try await checkRealForwardingAndCleanup(legacyShadowsocks: false)
    }

    @MainActor
    func testRealRC4MD5ForwardingAndCleanup() async throws {
        try await checkRealForwardingAndCleanup(legacyShadowsocks: true)
    }

    @MainActor
    func testRealCFBForwardingAndCleanup() async throws {
        for method in ["aes-128-cfb", "aes-192-cfb", "aes-256-cfb"] {
            try await checkRealForwardingAndCleanup(legacyShadowsocks: true, shadowsocksMethod: method)
        }
    }

    @MainActor
    private func checkRealForwardingAndCleanup(legacyShadowsocks: Bool, shadowsocksMethod: String = "rc4-md5") async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try await SingBoxInstaller.prepare(in: directory)
        let reservation = try LocalTestPorts(count: 3)
        let ports = reservation.ports
        let uuid = "11111111-1111-4111-8111-111111111111"
        let password = "fixture-password"
        let serverConfig: [String: Any] = [
            "inbounds": [["type": "vless", "listen": "127.0.0.1", "listen_port": ports[0], "users": [["uuid": uuid]]]],
            "outbounds": [["type": "direct", "tag": "direct"]]
        ]
        let serverFile = directory.appendingPathComponent("server.json")
        try XrayConfigBuilder.writeJSON(serverConfig, to: serverFile)
        func start(_ executable: String, _ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        reservation.release()
        // sing-box supports legacy ciphers only outbound; use an independent loopback fixture as the server.
        let legacyServer = #"""
        import hashlib, os, pathlib, socket, struct, subprocess, sys
        def stream(key):
            state = list(range(256))
            j = 0
            for i in range(256):
                j = (j + state[i] + key[i % len(key)]) % 256
                state[i], state[j] = state[j], state[i]
            i = j = 0
            while True:
                i = (i + 1) % 256
                j = (j + state[i]) % 256
                state[i], state[j] = state[j], state[i]
                yield state[(state[i] + state[j]) % 256]
        def crypt(data, cipher):
            return bytes(value ^ next(cipher) for value in data)
        assert crypt(b'Plaintext', stream(b'Key')).hex() == 'bbf316e8d940af0ad3'
        method = sys.argv[4]
        key_size = 16 if method == 'rc4-md5' else int(method.split('-')[1]) // 8
        master = previous = b''
        while len(master) < key_size:
            previous = hashlib.md5(previous + b'fixture-password').digest()
            master += previous
        master = master[:key_size]
        def cfb(data, iv, decrypt=False):
            args = ['/usr/bin/openssl', 'enc', '-' + method, '-K', master.hex(), '-iv', iv.hex()]
            if decrypt: args.append('-d')
            return subprocess.run(args, input=data, capture_output=True, check=True).stdout
        with socket.socket() as server:
            server.bind(('127.0.0.1', int(sys.argv[1])))
            server.listen()
            server.settimeout(10)
            with server.accept()[0] as peer:
                peer.settimeout(5)
                iv = b''
                while len(iv) < 16:
                    part = peer.recv(16 - len(iv))
                    assert part, 'missing client IV'
                    iv += part
                cipher = stream(hashlib.md5(master + iv).digest()) if method == 'rc4-md5' else None
                request = encrypted = b''
                while b'\r\n\r\n' not in request:
                    part = peer.recv(4096)
                    assert part, 'missing request'
                    if cipher is not None:
                        request += crypt(part, cipher)
                    else:
                        encrypted += part
                        request = cfb(encrypted, iv, True)
                expected = b'\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', int(sys.argv[2]))
                assert request.startswith(expected + b'GET /probe.txt '), request
                payload = pathlib.Path(sys.argv[3]).read_bytes()
                response = b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload
                iv = os.urandom(16)
                encoded = crypt(response, stream(hashlib.md5(master + iv).digest())) if method == 'rc4-md5' else cfb(response, iv)
                peer.sendall(iv + encoded)
        """#
        let server = legacyShadowsocks
            ? try start("/usr/bin/python3", ["-c", legacyServer, "\(ports[0])", "\(ports[1])", directory.appendingPathComponent("probe.txt").path, shadowsocksMethod])
            : try start(binary.path, ["run", "-c", serverFile.path])
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let payload = Data("sing-box-vless-round-trip".utf8)
        try payload.write(to: directory.appendingPathComponent("probe.txt"))
        let target = try start("/usr/bin/python3", ["-m", "http.server", "\(ports[1])", "--bind", "127.0.0.1", "--directory", directory.path])
        defer { if target.isRunning { target.terminate(); target.waitUntilExit() } }
        let node = ProxyNode(name: "local", protocolType: legacyShadowsocks ? .shadowsocks : .vless,
                             server: "127.0.0.1", port: ports[0], uuid: uuid, password: password, method: shadowsocksMethod)
        var config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, ports[2])])
        if !legacyShadowsocks {
            var outbounds = config["outbounds"] as! [[String: Any]]
            let index = try XCTUnwrap(outbounds.firstIndex { $0["tag"] as? String == "proxy-0" })
            // Force the VLESS bridge against loopback; RC4-MD5 uses automatic selection.
            outbounds[index] = ["tag": "proxy-0", "protocol": "socks", "settings": [:], SingBoxConnectionConfig.marker: try SingBoxConnectionConfig.outbound(node)]
            config["outbounds"] = outbounds
        }
        let file = directory.appendingPathComponent("client.json")
        try XrayConfigBuilder.writeJSON(config, to: file)
        guard let xray = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        let manager = XrayProcessManager(binaryURL: xray)
        defer { Task { await manager.stop() } }
        try await manager.start(configURL: file)
        let executables = await manager.connectionCoreExecutables()
        XCTAssertEqual(executables.count, 1)
        for _ in 0..<30 {
            if await TCPTester.measure(host: "127.0.0.1", port: ports[1], timeout: 0.1) != nil,
               await TCPTester.measure(host: "127.0.0.1", port: ports[2], timeout: 0.1) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let output = directory.appendingPathComponent("received.txt")
        let curl = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
            "--silent", "--fail", "--noproxy", "", "--max-time", "10", "--proxy", "http://127.0.0.1:\(ports[2])",
            "http://127.0.0.1:\(ports[1])/probe.txt", "-o", output.path
        ], timeout: 12)
        if curl.status != 0 { print(await manager.readRecentOutput(maxBytes: 8192)) }
        XCTAssertEqual(curl.status, 0, String(decoding: curl.output, as: UTF8.self))
        XCTAssertEqual(try Data(contentsOf: output), payload)
        await manager.stop()
        let running = await manager.isRunning()
        XCTAssertFalse(running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(executables.first)))
    }
}

final class OptionalChineseCityLibraryTests: XCTestCase {
    func testChineseSettingDefaultsOnAndOnlyUsableNodesQualify() throws {
        var settings = AppSettings()
        XCTAssertTrue(settings.showChineseNodeMetadata)
        var node = ProxyNode(name: "test", protocolType: .vless, server: "example.com", port: 443)
        XCTAssertFalse(settings.shouldResolveChineseCity(for: node))
        node.lastTestStatus = .fast
        XCTAssertTrue(settings.shouldResolveChineseCity(for: node))
        node.lastTestStatus = .unavailable
        XCTAssertFalse(settings.shouldResolveChineseCity(for: node))
        node.lastTestStatus = .fast
        settings.showChineseNodeMetadata = false
        XCTAssertFalse(settings.shouldResolveChineseCity(for: node))
        XCTAssertEqual(ExitMetadataLocalization.city("London (Tower)", countryCode: "GB", localizedCity: "伦敦", showChinese: false), "London (Tower)")
        XCTAssertEqual(ExitMetadataLocalization.networkOperator("Google LLC", showChinese: false), "Google LLC")
        let baseline = AppSettings()
        let applied = baseline.applyingSettingsEdits(from: settings, comparedTo: baseline)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(applied)).showChineseNodeMetadata)
    }

    func testPendingChineseNameOnlyAppearsInTooltipWhenEnabled() {
        XCTAssertEqual(ExitMetadataLocalization.city("Unlisted", catalog: .init(cities: [])), "Unlisted")
        XCTAssertTrue(ExitMetadataLocalization.help(raw: "Unlisted", displayed: "Unlisted", showChinese: true).contains("中文名待补充"))
        XCTAssertFalse(ExitMetadataLocalization.help(raw: "Unlisted", displayed: "Unlisted", showChinese: false).contains("中文名待补充"))
        XCTAssertFalse(ExitMetadataLocalization.help(raw: "London", displayed: "伦敦", showChinese: true).contains("中文名待补充"))
        XCTAssertFalse(ExitMetadataLocalization.help(raw: "OVH SAS", displayed: "OVH 云服务", showChinese: true).contains("中文名待补充"))
        XCTAssertFalse(ExitMetadataLocalization.help(raw: nil, displayed: "未知", showChinese: true).contains("中文名待补充"))
    }

    func testDisallowedOnlineLookupDoesNotRun() async {
        let counter = CityLookupCounter()
        let resolver = ChineseCityResolver(catalog: .init(cities: []), defaults: nil, pacingNanoseconds: 0) { _ in
            await counter.record(); return "测试城"
        }
        let result = await resolver.resolve(.init(ip: "203.0.113.1", city: "Unlisted", countryCode: "US", latitude: 1, longitude: 2), allowingOnline: { false })
        XCTAssertNil(result.localizedCity)
        let count = await counter.count
        XCTAssertEqual(count, 0)
    }

    func testCancellingOnlineWorkDoesNotCacheFailureOrBlockNextRequest() async throws {
        let counter = CityLookupCounter()
        let resolver = ChineseCityResolver(catalog: .init(cities: []), defaults: nil, pacingNanoseconds: 0) { _ in
            await counter.record()
            if await counter.count == 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            return "测试城"
        }
        let metadata = NodeExitMetadata(ip: "203.0.113.1", city: "Unlisted", countryCode: "US", latitude: 1, longitude: 2)
        let first = Task { await resolver.resolve(metadata) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await resolver.cancelPending()
        _ = await first.value
        let second = await resolver.resolve(metadata)
        XCTAssertEqual(second.localizedCity, "测试城")
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testEligibleCitiesAreQueuedInsteadOfSilentlyDropped() async {
        let counter = CityLookupCounter()
        let resolver = ChineseCityResolver(catalog: .init(cities: []), defaults: nil, pacingNanoseconds: 0) { _ in
            await counter.record()
            try? await Task.sleep(nanoseconds: 1_000_000)
            return "测试城"
        }
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let result = await resolver.resolve(.init(ip: "203.0.113.1", city: "Unlisted \(index)",
                        countryCode: "US", latitude: 1, longitude: 2))
                    return result.localizedCity == "测试城"
                }
            }
            var resolved = 0
            for await success in group { if success { resolved += 1 } }
            return resolved
        }
        XCTAssertEqual(count, 20)
        let calls = await counter.count
        XCTAssertEqual(calls, 20)
    }

    func testInvalidInstallationPreservesPreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ChineseCities.json")
        let catalog = ChineseCityCatalog(cities: [
            .init(geonameID: 1, countryCode: "GB", admin1: "ENG", aliases: ["London"],
                  nameChinese: "伦敦", latitude: 51.5, longitude: -0.12)
        ])
        let data = try catalog.encodedData()
        let installed = try ChineseCityLibrary.install(data, at: url)
        XCTAssertEqual(installed.cityCount, 1)
        XCTAssertThrowsError(try ChineseCityLibrary.install(Data("invalid".utf8), at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try ChineseCityCatalog.read(from: url).name(for: "London", countryCode: "GB"), "伦敦")
        XCTAssertNil(Bundle.main.url(forResource: "ChineseCities", withExtension: "json"))
    }

    func testNativeGeoNamesConversionUsesCurrentPreferredNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let city = ["1", "London", "London", "Historic", "51.5", "-0.12", "P", "PPLC", "GB", "", "ENG", "", "", "", "1", "", "", "Europe/London", "2026-10-25"].joined(separator: "\t")
        let alternates = [
            ["1", "1", "zh", "伦敦", "1", "", "", "", "", ""],
            ["2", "1", "zh", "旧名", "1", "", "", "1", "", ""],
            ["3", "1", "en", "Greater London", "1", "", "", "", "", ""],
            ["4", "1", "en", "Old London", "1", "", "1", "", "", ""]
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n")
        try Data((city + "\n").utf8).write(to: directory.appendingPathComponent("cities500.txt"))
        try Data((alternates + "\n").utf8).write(to: directory.appendingPathComponent("alternateNamesV2.txt"))
        try Data("GB.ENG\tEngland\tEngland\t1\n".utf8).write(to: directory.appendingPathComponent("admin1CodesASCII.txt"))
        for name in ["cities500", "alternateNamesV2"] {
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/zip"),
                arguments: ["-j", directory.appendingPathComponent(name + ".zip").path, directory.appendingPathComponent(name + ".txt").path], timeout: 5)
            XCTAssertEqual(result.status, 0)
        }
        let catalog = try GeoNamesCityBuilder.build(in: directory)
        XCTAssertEqual(catalog.cityCount, 1)
        XCTAssertEqual(catalog.name(for: "Greater London", countryCode: "GB"), "伦敦")
        XCTAssertNil(catalog.name(for: "Old London", countryCode: "GB"))
        XCTAssertNil(catalog.name(for: "Historic", countryCode: "GB"))
        try Data("bad zip".utf8).write(to: directory.appendingPathComponent("cities500.zip"))
        XCTAssertThrowsError(try GeoNamesCityBuilder.build(in: directory))
    }
}
