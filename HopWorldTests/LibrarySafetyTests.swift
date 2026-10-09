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
        XCTAssertEqual(imported.nodes.count, snapshot.nodes.count)
        XCTAssertEqual(imported.subscriptions.first?.name, snapshot.subscriptions.first?.name)
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
        XCTAssertNotNil(committed)
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
