import XCTest

final class LibrarySafetyTests: XCTestCase {
    private let key = Data(repeating: 0x71, count: 32)

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func fixture() -> LibrarySnapshot {
        let sub = Subscription(name: "Fixture", originalURL: "https://example.com/sub?token=secret-token",
                               shareLinksText: "trojan://secret-password@example.com:443")
        let node = ProxyNode(name: "Fixture", protocolType: .trojan, server: "example.com", port: 443,
                             password: "secret-password", subscriptionID: sub.id)
        return LibrarySnapshot(nodes: [node], subscriptions: [sub])
    }

    private func writeLegacy(_ snapshot: LibrarySnapshot, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot.nodes).write(to: directory.appendingPathComponent("nodes.json"))
        try encoder.encode(snapshot.subscriptions).write(to: directory.appendingPathComponent("subscriptions.json"))
        try encoder.encode(snapshot.updateLogs).write(to: directory.appendingPathComponent("subscription-logs.json"))
    }

    func testMigrationEncryptsAllSecretsAndRemovesLegacyOnlyAfterSuccessfulCommit() throws {
        let directory = try directory()
        let snapshot = fixture()
        try writeLegacy(snapshot, to: directory)
        let key = key
        let store = SecureLibraryStore(directory: directory) { _ in key }
        let loaded = try store.load()
        XCTAssertEqual(loaded.nodes, snapshot.nodes)
        XCTAssertEqual(loaded.subscriptions, snapshot.subscriptions)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(names), Set(["library.enc", "library.previous.enc"]))
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertNil(data.range(of: Data("secret-password".utf8)))
            XCTAssertNil(data.range(of: Data("secret-token".utf8)))
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
        }
        let reread = try SecureLibraryStore(directory: directory) { _ in key }.load()
        XCTAssertEqual(reread.nodes, snapshot.nodes)
        XCTAssertEqual(reread.subscriptions, snapshot.subscriptions)
    }

    func testKeychainFailurePreservesLegacyAndBlocksSavingEmptyLibrary() throws {
        let directory = try directory()
        try writeLegacy(fixture(), to: directory)
        let original = try Data(contentsOf: directory.appendingPathComponent("nodes.json"))
        let store = SecureLibraryStore(directory: directory) { _ in throw LibraryStoreError.locked }
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(LibrarySnapshot()))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("nodes.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.enc").path))
    }

    func testMalformedLegacyNeverBecomesAnEmptyCommit() throws {
        let directory = try directory()
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: directory.appendingPathComponent("nodes.json"))
        let key = key
        let store = SecureLibraryStore(directory: directory) { _ in key }
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(LibrarySnapshot()))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("nodes.json")), corrupt)
    }

    func testDamagedPrimaryRestoresWholePreviousCommitAndRetainsDamagedFile() throws {
        let directory = try directory()
        let key = key
        let store = SecureLibraryStore(directory: directory) { _ in key }
        _ = try store.load()
        let original = fixture()
        try store.save(original)
        var newer = original
        newer.nodes[0].name = "New node"
        newer.subscriptions[0].name = "New subscription"
        try store.save(newer)
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("library.enc"))
        let reloadedStore = SecureLibraryStore(directory: directory) { _ in key }
        let recovered = try reloadedStore.load()
        XCTAssertTrue(reloadedStore.recoveredBackup)
        XCTAssertEqual(recovered.nodes, original.nodes)
        XCTAssertEqual(recovered.subscriptions, original.subscriptions)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("library-unreadable-") })
        try reloadedStore.save(recovered)
    }

    func testWrongOrLostKeyCannotOverwriteEncryptedData() throws {
        let directory = try directory()
        let key = key
        let store = SecureLibraryStore(directory: directory) { _ in key }
        _ = try store.load()
        try store.save(fixture())
        let before = try Data(contentsOf: directory.appendingPathComponent("library.enc"))
        let wrong = SecureLibraryStore(directory: directory) { create in
            XCTAssertFalse(create)
            return Data(repeating: 3, count: 32)
        }
        XCTAssertThrowsError(try wrong.load())
        XCTAssertThrowsError(try wrong.save(LibrarySnapshot()))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library.enc")), before)
    }

    func testFailedCommitKeepsReadablePrimary() throws {
        let directory = try directory()
        let key = key
        let store = SecureLibraryStore(directory: directory) { _ in key }
        _ = try store.load()
        try store.save(fixture())
        let before = try Data(contentsOf: directory.appendingPathComponent("library.enc"))
        let backup = directory.appendingPathComponent("library.previous.enc")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(LibrarySnapshot()))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library.enc")), before)
    }

    func testPortableBackupRoundTrip() throws {
        let snapshot = fixture()
        let exported = try LibraryBackup.export(
            snapshot: snapshot,
            passphrase: "test-passphrase",
            includeCredentials: true
        )
        let imported = try LibraryBackup.importBackup(from: exported, passphrase: "test-passphrase")
        XCTAssertEqual(imported.snapshot.nodes.count, snapshot.nodes.count)
        XCTAssertEqual(imported.snapshot.subscriptions.first?.name, snapshot.subscriptions.first?.name)
        XCTAssertNil(imported.settings)
    }

    func testPortableBackupSelectiveSubscriptionsAndSettings() throws {
        let first = Subscription(name: "Keep", originalURL: "https://example.com/a")
        let second = Subscription(name: "Skip", originalURL: "https://example.com/b")
        let keepNode = ProxyNode(name: "Keep", protocolType: .trojan, server: "a.example.com", port: 443,
                                 password: "secret", subscriptionID: first.id)
        let skipNode = ProxyNode(name: "Skip", protocolType: .trojan, server: "b.example.com", port: 443,
                                 password: "secret", subscriptionID: second.id)
        let manual = ProxyNode(name: "Manual", protocolType: .trojan, server: "m.example.com", port: 443,
                               password: "secret", subscriptionID: nil)
        let snapshot = LibrarySnapshot(
            nodes: [keepNode, skipNode, manual],
            subscriptions: [first, second],
            updateLogs: [
                SubscriptionUpdateLog(subscriptionID: first.id, requestedURL: first.originalURL, success: true),
                SubscriptionUpdateLog(subscriptionID: second.id, requestedURL: second.originalURL, success: true)
            ]
        )
        var settings = AppSettings()
        settings.testConcurrency = 7
        settings.socksPort = 18080

        let exported = try LibraryBackup.export(
            snapshot: snapshot,
            passphrase: "test-passphrase",
            includeCredentials: true,
            subscriptionIDs: [first.id],
            includeManualNodes: false,
            settings: settings
        )
        let imported = try LibraryBackup.importBackup(from: exported, passphrase: "test-passphrase")
        XCTAssertEqual(imported.snapshot.subscriptions.map(\.name), ["Keep"])
        XCTAssertEqual(imported.snapshot.nodes.map(\.name), ["Keep"])
        XCTAssertEqual(imported.snapshot.updateLogs.map(\.subscriptionID), [first.id])
        XCTAssertEqual(imported.settings?.testConcurrency, 7)
        XCTAssertEqual(imported.settings?.socksPort, 18080)

        XCTAssertThrowsError(try LibraryBackup.export(
            snapshot: snapshot,
            passphrase: "test-passphrase",
            includeCredentials: false,
            subscriptionIDs: [],
            includeManualNodes: false,
            settings: nil
        )) { error in
            XCTAssertEqual(error as? LibraryBackupError, .emptyExport)
        }
    }

    func testGeneratedCoreConfigurationIsOwnerOnly() throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("config.json")
        try XrayConfigBuilder.writeJSON(["password": "fixture-secret"], to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try XrayConfigBuilder.writeJSON(["password": "updated-fixture"], to: file)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["config.json"])
    }

    func testRefreshPreservesChangesInOtherSubscriptions() throws {
        let original = fixture()
        let subID = try XCTUnwrap(original.subscriptions.first?.id)
        var other = original.nodes[0]
        other.subscriptionID = UUID()
        other.note = "Edited during download"
        var proposed = original.nodes
        proposed[0].name = "Updated from source"
        let committed = try XCTUnwrap(SubscriptionMerger.commitRefresh(
            subscriptionID: subID, baseline: original.nodes, proposed: proposed, current: original.nodes + [other]))
        XCTAssertEqual(committed, [other] + proposed)
    }

    func testRefreshRejectsDeletedOrEditedSourceNodes() throws {
        let snapshot = fixture()
        let id = try XCTUnwrap(snapshot.subscriptions.first?.id)
        XCTAssertNil(SubscriptionMerger.commitRefresh(subscriptionID: id, baseline: snapshot.nodes,
                                                      proposed: snapshot.nodes, current: []))
        var edited = snapshot.nodes
        edited[0].isFavorite = true
        XCTAssertNil(SubscriptionMerger.commitRefresh(subscriptionID: id, baseline: snapshot.nodes,
                                                      proposed: snapshot.nodes, current: edited))
    }

    func testRefreshAllowsConcurrentSpeedTestUpdates() throws {
        let snapshot = fixture()
        let id = try XCTUnwrap(snapshot.subscriptions.first?.id)
        var tested = snapshot.nodes
        tested[0].lastLatency = 120
        tested[0].lastTestStatus = .fast
        tested[0].lastTestDate = Date()
        let committed = SubscriptionMerger.commitRefresh(
            subscriptionID: id,
            baseline: snapshot.nodes,
            proposed: snapshot.nodes,
            current: tested
        )
        XCTAssertEqual(committed?.first?.lastLatency, 120)
        XCTAssertEqual(committed?.first?.lastTestStatus, .fast)
        XCTAssertEqual(committed?.first?.lastTestDate, tested[0].lastTestDate)
    }

    func testRefreshPreservesConcurrentApplicationProbesAndExitCountry() throws {
        let snapshot = fixture()
        let id = try XCTUnwrap(snapshot.subscriptions.first?.id)
        var current = snapshot.nodes
        current[0].lastAppProbePassedIDs = ["Google", "GitHub"]
        current[0].lastAppProbeOkCount = 2
        current[0].lastAppProbeLatency = 85
        current[0].lastAppProbeDate = Date()
        current[0].countryCode = "JP"
        current[0].countryName = "日本"
        current[0].exitMetadata = NodeExitMetadata(ip: "203.0.113.42", city: "Tokyo",
                                                 networkOperator: "Google LLC", asn: "AS15169")
        let committed = try XCTUnwrap(SubscriptionMerger.commitRefresh(
            subscriptionID: id, baseline: snapshot.nodes, proposed: snapshot.nodes, current: current
        ))
        XCTAssertEqual(committed[0].lastAppProbePassedIDs, current[0].lastAppProbePassedIDs)
        XCTAssertEqual(committed[0].lastAppProbeOkCount, 2)
        XCTAssertEqual(committed[0].lastAppProbeLatency, 85)
        XCTAssertEqual(committed[0].lastAppProbeDate, current[0].lastAppProbeDate)
        XCTAssertEqual(committed[0].countryCode, "JP")
        XCTAssertEqual(committed[0].countryName, "日本")
        XCTAssertEqual(committed[0].exitMetadata, current[0].exitMetadata)
    }

    func testConfigurationUpdateInvalidatesOldMeasurements() {
        var old = fixture().nodes[0]
        old.lastTestStatus = .fast
        old.lastLatency = 100
        old.lastTestDate = Date()
        old.lastAppProbePassedIDs = ["Google"]
        old.lastAppProbeOkCount = 1
        old.lastAppProbeDate = Date()
        old.exitMetadata = NodeExitMetadata(ip: "203.0.113.42", city: "Tokyo", asn: "AS15169")
        var incoming = old
        incoming.password = "updated-secret"
        let plan = SubscriptionMerger.buildPlan(mode: .merge, oldNodes: [old], newNodes: [incoming], missingLimit: 3)
        XCTAssertEqual(plan.resultingNodes.count, 1)
        XCTAssertEqual(plan.resultingNodes[0].id, old.id)
        XCTAssertEqual(plan.resultingNodes[0].lastTestStatus, .untested)
        XCTAssertNil(plan.resultingNodes[0].lastLatency)
        XCTAssertNil(plan.resultingNodes[0].lastAppProbeDate)
        XCTAssertNil(plan.resultingNodes[0].lastAppProbePassedIDs)
        XCTAssertNil(plan.resultingNodes[0].exitMetadata)
    }

    func testRefreshKeepsNodeConnectedDuringDownloadUntilDisconnect() throws {
        let snapshot = fixture()
        let id = try XCTUnwrap(snapshot.subscriptions.first?.id)
        let node = snapshot.nodes[0]
        let committed = try XCTUnwrap(SubscriptionMerger.commitRefresh(
            subscriptionID: id, baseline: snapshot.nodes, proposed: [], current: snapshot.nodes,
            preserveNodeIDs: [node.id]
        ))
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed[0].id, node.id)
        XCTAssertTrue(committed[0].pendingRemoval)
    }
}

final class NodeCredentialHydrationTests: XCTestCase {
    private let record = #"{"uuid":"22222222-2222-4222-8222-222222222222","publicKey":"stored-public-key","shortID":"aabb"}"#

    private func realityNode(publicKey: String? = nil) -> ProxyNode {
        ProxyNode(name: "REALITY fixture", protocolType: .vless, server: "example.com", port: 443,
                  credentialKey: "fixture-credentials", uuid: "11111111-1111-4111-8111-111111111111",
                  security: .reality, publicKey: publicKey, shortID: "0011")
    }

    func testExistingUUIDDoesNotPreventRestoringMissingRealityKey() {
        for publicKey in [nil, "", " \n "] as [String?] {
            var node = realityNode(publicKey: publicKey)
            let originalUUID = node.uuid
            var reads = 0
            KeychainStore.hydrateCredentials(&node, loadCredential: { account in
                XCTAssertEqual(account, "fixture-credentials")
                reads += 1
                return self.record
            })
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(node.publicKey, "stored-public-key")
            XCTAssertEqual(node.uuid, originalUUID)
            XCTAssertEqual(node.shortID, "0011")
        }
    }

    func testHydrationKeepsExistingRealityParameters() {
        var node = realityNode(publicKey: "current-public-key")
        KeychainStore.hydrateCredentials(&node, loadCredential: { _ in
            XCTFail("A complete node must not read credentials")
            return self.record
        })
        node.uuid = nil
        KeychainStore.hydrateCredentials(&node, loadCredential: { _ in self.record })
        XCTAssertEqual(node.uuid, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(node.publicKey, "current-public-key")
        XCTAssertEqual(node.shortID, "0011")
    }

    func testConfigurationValidationRestoresCredentialsOnALocalCopy() {
        for publicKey in [nil, "", " \n "] as [String?] {
            let node = realityNode(publicKey: publicKey)
            let (valid, error) = NodeConfigChecker.validate(node, loadCredential: { _ in self.record })
            XCTAssertTrue(valid)
            XCTAssertNil(error)
            XCTAssertEqual(node.publicKey, publicKey)
        }
    }

    func testMissingOrMalformedStoredRealityKeyStillFailsValidation() {
        for record in [nil, "{}", "invalid JSON", #"{"publicKey":""}"#, #"{"publicKey":"  "}"#] as [String?] {
            let node = realityNode()
            let (valid, error) = NodeConfigChecker.validate(node, loadCredential: { _ in record })
            XCTAssertFalse(valid)
            XCTAssertEqual(error, "REALITY 缺少 publicKey")
        }
    }
}

final class LibraryKeychainCompatibilityTests: XCTestCase {
    private let key = Data(repeating: 0x31, count: 32)
    private func encoded(_ data: Data) -> Data { Data(data.base64EncodedString().utf8) }

    func testAdHocSignatureUsesLoginKeychainForFirstMigration() throws {
        var writes: [LibraryKeyResolver.Backend] = []
        let resolved = try LibraryKeyResolver.resolve(createIfMissing: true, read: { backend in
            (backend == .dataProtection ? -34018 : -25300, nil)
        }, add: { backend, value in
            writes.append(backend)
            XCTAssertEqual(value.count, 32)
            return 0
        })
        XCTAssertEqual(resolved.count, 32)
        XCTAssertEqual(writes, [.login])
    }

    func testSigningUpgradeReusesLoginKeyInsteadOfGeneratingNewKey() throws {
        let resolved = try LibraryKeyResolver.resolve(createIfMissing: false, read: { backend in
            backend == .dataProtection ? (-25300, nil) : (0, encoded(key))
        }, add: { _, _ in XCTFail("Existing library key must never be replaced"); return 0 })
        XCTAssertEqual(resolved, key)
    }

    func testAdHocRelaunchReadsExistingLoginKey() throws {
        let resolved = try LibraryKeyResolver.resolve(createIfMissing: false, read: { backend in
            backend == .dataProtection ? (-34018, nil) : (0, encoded(key))
        }, add: { _, _ in XCTFail("Must not create a key"); return 0 })
        XCTAssertEqual(resolved, key)
    }

    func testExistingEncryptedLibraryNeverCreatesReplacementForInaccessibleKey() {
        XCTAssertThrowsError(try LibraryKeyResolver.resolve(createIfMissing: false, read: { backend in
            (backend == .dataProtection ? -34018 : -25300, nil)
        }, add: { _, _ in XCTFail("Do not orphan encrypted data"); return 0 }))
    }

    func testDeniedOrCancelledAccessDoesNotCreateOrSwitchKeys() {
        for status: Int32 in [-25293, -25308, -128] {
            XCTAssertThrowsError(try LibraryKeyResolver.resolve(createIfMissing: true, read: { _ in
                (status, nil)
            }, add: { _, _ in XCTFail("Do not bypass denied access"); return 0 }))
            XCTAssertThrowsError(try LibraryKeyResolver.resolve(createIfMissing: true, read: { backend in
                (backend == .dataProtection ? -34018 : status, nil)
            }, add: { _, _ in XCTFail("Do not overwrite a locked key"); return 0 }))
        }
    }

    func testEntitlementFailureOnInsertionFallsBackAndDuplicateReadsWinner() throws {
        var writes: [LibraryKeyResolver.Backend] = []
        var loginReads = 0
        let resolved = try LibraryKeyResolver.resolve(createIfMissing: true, read: { backend in
            if backend == .dataProtection { return (-25300, nil) }
            loginReads += 1
            return loginReads == 3 ? (0, encoded(key)) : (-25300, nil)
        }, add: { backend, _ in
            writes.append(backend)
            return backend == .dataProtection ? -34018 : -25299
        })
        XCTAssertEqual(writes, [.dataProtection, .login])
        XCTAssertEqual(resolved, key)
    }

    func testMalformedExistingKeyFailsWithoutReplacement() {
        XCTAssertThrowsError(try LibraryKeyResolver.resolve(createIfMissing: true, read: { _ in
            (0, Data("invalid-key".utf8))
        }, add: { _, _ in XCTFail("Do not replace malformed key"); return 0 }))
    }
}
