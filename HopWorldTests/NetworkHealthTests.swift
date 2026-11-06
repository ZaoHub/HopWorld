import XCTest

final class NetworkHealthTests: XCTestCase {
    @MainActor
    func testLegacyResponseFragmentsDescribeActivityWithoutPublicNodeCredit() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        for age in (0..<14).map({ Double($0 * 3) }) {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: .responseProgress),
                         nodeKey: "A", context: "wifi", now: now)
        }
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.diagnostic.state, .responding)
        XCTAssertEqual(snapshot.diagnostic.lastResponseAt, now)
        XCTAssertTrue(snapshot.diagnostic.connectionSummary.contains("数据到达"))
        XCTAssertEqual(snapshot.responseFragmentCount, 10)
        XCTAssertEqual(snapshot.attributedEventCount, 0)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertNil(snapshot.score)
        XCTAssertNil(snapshot.failureSince)
        XCTAssertFalse(snapshot.quarantined)
    }

    func testDiagnosticTransportReadyDoesNotHidePendingRequestFailure() {
        let now = Date()
        let failed = CodexHealthEvent(date: now.addingTimeInterval(-20), kind: .requestFailure,
                                     recoveryOrigin: .request)
        let ready = CodexHealthEvent(date: now.addingTimeInterval(-10), kind: .connectionReady,
                                    scope: "durable", recoveryOrigin: .appServerBridge)
        let snapshot = AppDiagnosticSnapshot(events: [failed, ready], now: now)
        XCTAssertEqual(snapshot.state, .networkFailure)
        XCTAssertTrue(snapshot.connectionSummary.contains("部分内容暂未加载成功"))
        XCTAssertEqual(snapshot.lastNetworkFailureAt, failed.date)
        let response = CodexHealthEvent(date: now.addingTimeInterval(-1), kind: .responseProgress,
                                       recoveryOrigin: .businessResponse)
        let recovered = AppDiagnosticSnapshot(events: [failed, ready, response], now: now)
        XCTAssertEqual(recovered.state, .responding)
        XCTAssertEqual(recovered.lastResponseAt, response.date)
    }

    func testDiagnosticLayersShowObservedServiceAndWorkspaceEvents() {
        let now = Date()
        let service = CodexHealthEvent(date: now.addingTimeInterval(-20), kind: .authenticationFailure)
        let workspace = CodexHealthEvent(date: now.addingTimeInterval(-10), kind: .workspaceFailure)
        let snapshot = AppDiagnosticSnapshot(events: [service, workspace], now: now)
        XCTAssertEqual(snapshot.state, .workspaceIssue)
        XCTAssertTrue(snapshot.serviceSummary.contains(service.title))
        XCTAssertTrue(snapshot.workspaceSummary.contains(workspace.title))
        let restored = CodexHealthEvent(date: now.addingTimeInterval(-1), kind: .workspaceRecovered)
        let recovered = AppDiagnosticSnapshot(events: [workspace, restored], now: now)
        XCTAssertEqual(recovered.state, .workspaceRecovered)
        XCTAssertTrue(recovered.workspaceSummary.contains(restored.title))
        let unresolvedNetwork = CodexHealthEvent(date: now.addingTimeInterval(-2), kind: .requestFailure)
        XCTAssertEqual(AppDiagnosticSnapshot(events: [unresolvedNetwork, restored], now: now).state, .networkFailure,
                       "Workspace recovery cannot conceal an unresolved network request failure")
    }

    func testDiagnosticIdleKeepsLastKnownResponseAndIgnoresFutureEvents() {
        let now = Date()
        let response = CodexHealthEvent(date: now.addingTimeInterval(-180), kind: .responseProgress)
        let future = CodexHealthEvent(date: now.addingTimeInterval(1), kind: .requestFailure)
        let snapshot = AppDiagnosticSnapshot(events: [future, response], now: now)
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.lastEventAt, response.date)
        XCTAssertEqual(snapshot.lastResponseAt, response.date)
        XCTAssertNil(snapshot.lastNetworkFailureAt)
        XCTAssertTrue(snapshot.connectionSummary.contains("未发起对话"))
    }

    func testEventPaginationIncludesAllRecordsWithoutGapsOrOversizedPages() {
        let records = (0..<103).map { index in
            let date = Date(timeIntervalSince1970: Double(index))
            return AppHealthRecord(nodeKey: "A", context: "wifi", date: date,
                                   event: .init(date: date, kind: .reconnecting))
        }
        let first = AppHealthEventPage(records: records, number: 1)
        let last = AppHealthEventPage(records: records, number: 11)
        XCTAssertEqual(first.records.map(\.id), Array(records.prefix(10)).map(\.id))
        XCTAssertEqual(first.totalCount, 103)
        XCTAssertEqual(first.pageCount, 11)
        XCTAssertEqual(last.records.count, 3)
        let pages = (1...first.pageCount).map { AppHealthEventPage(records: records, number: $0) }
        XCTAssertTrue(pages.allSatisfy { $0.records.count <= 10 })
        XCTAssertEqual(pages.flatMap(\.records).map(\.id), records.map(\.id))
    }

    func testEventPaginationClampsEmptyAndOutOfRangePages() {
        let empty = AppHealthEventPage(records: [], number: 8)
        XCTAssertEqual(empty.number, 1)
        XCTAssertEqual(empty.pageCount, 1)
        XCTAssertTrue(empty.records.isEmpty)
        let date = Date()
        let records = [AppHealthRecord(nodeKey: "A", context: "wifi", date: date,
                                      event: .init(date: date, kind: .reconnecting))]
        XCTAssertEqual(AppHealthEventPage(records: records, number: -10).number, 1)
        XCTAssertEqual(AppHealthEventPage(records: records, number: Int.max).number, 1)
        XCTAssertEqual(AppHealthEventPage(records: records, number: 2).records.count, 1)
    }

    func testLogParserClassifiesCanonicalEventsAndRejectsRepeatedStatePayloads() throws {
        let prefix = "2026-10-26T03:00:00.000Z warning [AppServerConnection] "
        let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "app_server_connection.connection_failed_before_ready hostId=durable errorMessage=secret"))
        XCTAssertEqual(event.kind, .connectionFailure)
        XCTAssertEqual(event.scope, "durable")
        XCTAssertFalse(event.isNetworkFailure, "A remote app-server bridge is not proof of this node's public request failing")
        XCTAssertFalse(event.detail.contains("secret"))
        XCTAssertNil(CodexHealthLogParser.parse(prefix + "app_server_connection.state_changed cause=connection_failed_before_ready"))
        XCTAssertNil(CodexHealthLogParser.parse(prefix + "response_routed method=config/read errorCode=null"))
        let ready = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "connection_ready hostId=durable"))
        XCTAssertFalse(ready.isBusinessSuccess)
        let progress = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "Reasoning summary item completed summary=secret"))
        XCTAssertFalse(progress.isBusinessSuccess, "A response with unknown execution host must not credit the current node")
    }

    func testOnlyExplicitOfficialPublicEndpointCanCreditNode() throws {
        let prefix = "2026-10-26T03:00:00.000Z error [electron-message-handler] sa_server_request_failed "
        for address in ["https://chatgpt.com/backend-api/test", "https://api.openai.com/v1/responses"] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "url=\(address) errorCode=ERR_CONNECTION_CLOSED status=500"))
            XCTAssertEqual(event.kind, .requestFailure)
            XCTAssertEqual(event.scope, "public")
            XCTAssertTrue(event.isNetworkFailure)
        }
        for address in ["/backend-api/test", "https://chatgpt.com.evil.example/test", "http://chatgpt.com/test"] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "url=\(address) errorCode=ERR_TIMED_OUT"))
            XCTAssertFalse(event.isNetworkFailure)
        }
        XCTAssertEqual(CodexHealthLogParser.parse(prefix + "url=https://chatgpt.com/test status=403")?.kind, .authenticationFailure)
        XCTAssertEqual(CodexHealthLogParser.parse(prefix + "status=429")?.kind, .rateLimited)
        XCTAssertEqual(CodexHealthLogParser.parse(prefix + "status=503")?.kind, .serviceFailure)
    }

    func testRecoverySignalsUseCanonicalSourcesWithoutInventingPublicAttribution() throws {
        let prefix = "2026-10-26T03:00:00.000Z warning [AppServerConnection] "
        let failed = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "app_server_connection.connection_failed_before_ready transport=websocket errorMessage=\"websocket error\""))
        XCTAssertEqual(failed.recoveryOrigin, .appServerBridge)
        XCTAssertEqual(failed.scope, "unknown")
        XCTAssertFalse(failed.isNetworkFailure)
        let reconnect = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "app_server_connection.reconnect_started hostId=durable reconnectAttempt=3"))
        XCTAssertEqual(reconnect.recoveryOrigin, .appServerBridge)
        XCTAssertEqual(reconnect.scope, "durable")
        let ready = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "initialize_handshake_result outcome=success hostId=durable"))
        XCTAssertEqual(ready.kind, .connectionReady)
        XCTAssertEqual(ready.recoveryOrigin, .appServerBridge)
        XCTAssertFalse(ready.isBusinessSuccess)
        XCTAssertNil(CodexHealthLogParser.parse(prefix + "app_server_connection.reconnect_failed errorMessage=\"websocket error\""), "A second message about the same reconnect attempt must not duplicate failure evidence")
        XCTAssertNil(CodexHealthLogParser.parse(prefix + "app_server_connection.reconnect_started hostId=local")?.recoveryOrigin)
    }

    func testRelativeBackgroundRequestsRemainDiagnosticWithoutDrivingRecovery() throws {
        let prefix = "2026-10-26T03:00:00.000Z error [electron-message-handler] "
        let request = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "sa_server_request_failed url=/backend-api/test errorCode=ERR_CONNECTION_TIMED_OUT status=500"))
        XCTAssertEqual(request.kind, .requestFailure, "An Electron network failure may have a synthetic 500 wrapper status")
        XCTAssertEqual(request.recoveryOrigin, .request)
        XCTAssertFalse(request.drivesRecovery)
        XCTAssertEqual(request.scope, "unknown")
        XCTAssertFalse(request.isNetworkFailure)
        for address in ["https://other.example/test", "//other.example/test", "https://chatgpt.com.evil.example/test"] {
            XCTAssertNil(CodexHealthLogParser.parse(prefix + "sa_server_request_failed url=\(address) errorCode=ERR_TIMED_OUT")?.recoveryOrigin)
        }
        let progress = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "Reasoning summary item completed summary=private"))
        XCTAssertEqual(progress.recoveryOrigin, .businessResponse)
        XCTAssertFalse(progress.isBusinessSuccess)
        XCTAssertFalse(progress.detail.contains("private"))
    }

    func testUnrecognizedSourcesCannotInjectRecoverySignals() throws {
        let prefix = "2026-10-26T03:00:00.000Z warning [OtherComponent] "
        for payload in [
            "app_server_connection.connection_failed_before_ready source=AppServerConnection",
            "sa_server_request_failed url=/backend-api/test errorCode=ERR_TIMED_OUT source=electron-message-handler",
            "Reasoning summary item completed source=electron-message-handler",
            "connection_ready source=AppServerConnection"
        ] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix + payload))
            XCTAssertNil(event.recoveryOrigin)
        }
    }

    func testRecoverySignalsPreserveAuthenticationRateLimitAndServiceClassifications() {
        let request = "2026-10-26T03:00:00.000Z error [electron-message-handler] sa_server_request_failed url=/backend-api/test "
        for (code, expected) in [(403, CodexHealthEvent.Kind.authenticationFailure), (429, .rateLimited), (503, .serviceFailure)] {
            let event = CodexHealthLogParser.parse(request + "status=\(code)")
            XCTAssertEqual(event?.kind, expected)
            XCTAssertEqual(event?.recoveryOrigin, .request)
        }
        let bridge = "2026-10-26T03:00:00.000Z error [AppServerConnection] app_server_connection.connection_failed_before_ready "
        XCTAssertEqual(CodexHealthLogParser.parse(bridge + "errorMessage=\"Unexpected server response: 403\"")?.kind, .authenticationFailure)
        XCTAssertEqual(CodexHealthLogParser.parse(bridge + "errorMessage=\"Unexpected server response: 429\"")?.kind, .rateLimited)
        XCTAssertEqual(CodexHealthLogParser.parse(bridge + "errorMessage=\"Unexpected server response: 503\"")?.kind, .serviceFailure)
    }

    func testQuotedDiagnosticTextCannotInjectEventOrPublicProvenance() throws {
        let prefix = "2026-10-26T03:00:00.000Z info [electron-message-handler] "
        let quoted = try String(data: JSONEncoder().encode("sa_server_request_failed url=https://chatgpt.com/test errorCode=ERR_TIMED_OUT requestId=private"), encoding: .utf8)!
        let progress = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "Reasoning summary item completed summary=" + quoted))
        XCTAssertEqual(progress.kind, .responseProgress)
        XCTAssertEqual(progress.scope, "unknown")
        XCTAssertNil(progress.observationID)
        let fail = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "sa_server_request_failed errorCode=ERR_TIMED_OUT errorMessage=" + quoted))
        XCTAssertEqual(fail.kind, .requestFailure)
        XCTAssertEqual(fail.scope, "unknown")
    }

    @MainActor
    func testContinuousFailureNeedsFreshRepeatedEvidenceAndNoActualResponse() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        func record(_ kind: CodexHealthEvent.Kind, age: TimeInterval, scope: String = "public") {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: kind, scope: scope), nodeKey: "node-A", context: "wifi-exit", now: now)
        }
        record(.connectionFailure, age: 65)
        XCTAssertNil(store.snapshot(nodeKey: "node-A", context: "wifi-exit", now: now).failureSince)
        for age in [50.0, 35, 20, 5] { record(.connectionFailure, age: age) }
        var snapshot = store.snapshot(nodeKey: "node-A", context: "wifi-exit", now: now)
        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertTrue(snapshot.quarantined)
        record(.connectionReady, age: 4)
        XCTAssertTrue(store.snapshot(nodeKey: "node-A", context: "wifi-exit", now: now).quarantined, "Transport ready cannot prove recovery")
        record(.responseProgress, age: 3)
        snapshot = store.snapshot(nodeKey: "node-A", context: "wifi-exit", now: now)
        XCTAssertFalse(snapshot.quarantined)
        XCTAssertEqual(snapshot.status, .mild)
        XCTAssertNil(snapshot.failureSince)
        XCTAssertNotNil(snapshot.lastSuccessAt)
        XCTAssertNil(store.snapshot(nodeKey: "node-B", context: "wifi-exit", now: now).lastObservedAt)
        XCTAssertNil(store.snapshot(nodeKey: "node-A", context: "different-wifi", now: now).lastObservedAt)
        XCTAssertEqual(store.snapshot(nodeKey: "node-A", context: "wifi-exit", now: now.addingTimeInterval(180)).status, .unknown)
    }

    @MainActor
    func testBridgeFailuresAndServiceErrorsDoNotQuarantineNode() {
        let store = NetworkHealthStore(fileURL: temporaryURL())
        let now = Date()
        for age in [65.0, 50, 35, 20, 5] {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: .connectionFailure, scope: "durable"), nodeKey: "A", context: "wifi", now: now)
        }
        var snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertNil(snapshot.failureSince)
        XCTAssertNil(snapshot.score)
        for kind: CodexHealthEvent.Kind in [.authenticationFailure, .rateLimited, .serviceFailure, .workspaceFailure] {
            store.record(event: .init(date: now, kind: kind, scope: "public"), nodeKey: "A", context: "wifi", now: now)
        }
        snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertFalse(snapshot.quarantined)
        XCTAssertNil(snapshot.failureSince)
    }

    @MainActor
    func testDiagnosticCountsRemainVisibleWithoutGivingTheNodeAScore() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        let events: [(CodexHealthEvent.Kind, String, TimeInterval)] = [
            (.connectionFailure, "unknown", 40), (.reconnecting, "durable", 30),
            (.responseProgress, "unknown", 20), (.connectionReady, "durable", 10),
            (.responseProgress, "unknown", 901)
        ]
        for (kind, scope, age) in events {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: kind, scope: scope),
                         nodeKey: "A", context: "wifi", now: now)
        }
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.diagnosticEventCount, 4)
        XCTAssertEqual(snapshot.diagnosticFailureCount, 1)
        XCTAssertEqual(snapshot.diagnosticReconnectCount, 1)
        XCTAssertEqual(snapshot.responseFragmentCount, 1)
        XCTAssertEqual(snapshot.attributedEventCount, 0)
        XCTAssertEqual(snapshot.verifiedRequestCount, 0)
        XCTAssertNotNil(snapshot.scoreUnavailableReason)
        XCTAssertNil(snapshot.score)
        XCTAssertNil(snapshot.failureSince)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertEqual(store.snapshot(nodeKey: "B", context: "wifi", now: now).diagnosticEventCount, 0)
    }

    @MainActor
    func testPartialRequestResultsExposeSamplingProgressWithoutInventingAScore() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        store.record(event: .init(date: now, kind: .responseCompleted, scope: "public", observationID: "request"),
                     nodeKey: "A", context: "wifi", now: now)
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.attributedEventCount, 1)
        XCTAssertEqual(snapshot.verifiedRequestCount, 1)
        XCTAssertEqual(snapshot.successRate, 1)
        XCTAssertEqual(snapshot.stabilityRatio, 1)
        XCTAssertEqual(snapshot.verifiedRequestSpan, 0)
        XCTAssertEqual(snapshot.observedSeconds, 0)
        XCTAssertNotNil(snapshot.scoreUnavailableReason)
        XCTAssertNil(snapshot.score)
    }

    @MainActor
    func testKnownMetricsRemainVisibleBeforeOverallScoreHasEnoughRequests() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        let events: [(CodexHealthEvent.Kind, TimeInterval, String?, String)] = [
            (.responseCompleted, 30, "one", "public"),
            (.connectionFailure, 25, nil, "public"),
            (.requestFailure, 20, "two", "public"),
            (.reconnecting, 15, nil, "public"),
            (.responseCompleted, 10, "three", "public"),
            (.connectionFailure, 5, nil, "durable")
        ]
        for (kind, age, requestID, scope) in events {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: kind, scope: scope, observationID: requestID),
                         nodeKey: "A", context: "wifi", now: now)
        }
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.verifiedRequestCount, 3)
        XCTAssertEqual(snapshot.verifiedRequestSpan, 20)
        XCTAssertEqual(snapshot.observedSeconds, 20)
        XCTAssertEqual(snapshot.instabilityEventCount, 2, "Unattributed bridge failures must not penalize this node")
        XCTAssertEqual(snapshot.observedAvailability ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.successRate ?? -1, 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(snapshot.stabilityRatio ?? -1, 1.0 / 3, accuracy: 0.0001)
        XCTAssertNil(snapshot.score, "Known partial metrics do not bypass the five-request score minimum")
        XCTAssertNotNil(snapshot.scoreUnavailableReason)
    }

    @MainActor
    func testScoreKeepsOriginalMetricWeightsAndExcludesIdleTime() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        for age in [40.0, 30, 20, 10, 0] {
            let kind: CodexHealthEvent.Kind = age == 20 ? .requestFailure : .responseCompleted
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: kind, scope: "public", observationID: String(age)),
                         nodeKey: "A", context: "wifi", now: now)
        }
        store.record(event: .init(date: now.addingTimeInterval(-15), kind: .reconnecting, scope: "public"),
                     nodeKey: "A", context: "wifi", now: now)
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.score, 74, "45 × 75% availability + 30 × 80% request success + 20 × 80% stability")
        XCTAssertEqual(snapshot.scoreCoverage, 95)
        XCTAssertEqual(snapshot.verifiedRequestSpan, 40)
        XCTAssertEqual(snapshot.observedSeconds, 40)
        XCTAssertNil(snapshot.scoreUnavailableReason)

        let idle = NetworkHealthStore(fileURL: file.deletingLastPathComponent().appendingPathComponent("idle.json"))
        for age in [60.0, 0] {
            idle.record(event: .init(date: now.addingTimeInterval(-age), kind: .responseCompleted, scope: "public", observationID: String(age)),
                        nodeKey: "A", context: "wifi", now: now)
        }
        let idleSnapshot = idle.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(idleSnapshot.verifiedRequestSpan, 60)
        XCTAssertEqual(idleSnapshot.observedSeconds, 0)
        XCTAssertNil(idleSnapshot.observedAvailability, "Unobserved idle time cannot be counted as available")
        XCTAssertEqual(idleSnapshot.successRate, 1)
        XCTAssertEqual(idleSnapshot.stabilityRatio, 1)
        XCTAssertNil(idleSnapshot.score)
    }

    @MainActor
    func testHistoryPersistsOnlyClassificationsAndUnknownScoreStaysUnknown() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        store.record(event: .init(date: now, kind: .responseCompleted, scope: "public", observationID: "initial"), nodeKey: "A", context: "wifi", now: now)
        XCTAssertNil(store.snapshot(nodeKey: "A", context: "wifi", now: now).score)
        for age in [10.0, 20, 30, 40] {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: .responseCompleted, scope: "public", observationID: String(age)), nodeKey: "A", context: "wifi", now: now)
        }
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.score, 95, "No latency evidence means no fabricated latency points")
        XCTAssertEqual(snapshot.scoreCoverage, 95)
        XCTAssertEqual(snapshot.verifiedRequestCount, 5)
        XCTAssertNil(snapshot.scoreUnavailableReason)
        store.recordSwitch(from: "A", to: "B", context: "wifi", reason: "持续网络失败", result: "待验证", now: now)
        await store.flush()
        XCTAssertNil(store.persistenceError)
        let restored = NetworkHealthStore(fileURL: file)
        XCTAssertEqual(restored.records.count, 5)
        XCTAssertEqual(restored.switches.count, 1)
        XCTAssertEqual(restored.snapshot(nodeKey: "A", context: "wifi", now: now).score, 95)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testUnknownRequestIdentityCannotScoreAndFragmentsCannotInflateSuccessRate() {
        let store = NetworkHealthStore(fileURL: temporaryURL())
        let now = Date()
        for age in 0..<100 {
            store.record(event: .init(date: now.addingTimeInterval(Double(-age)), kind: .responseProgress, scope: "public"), nodeKey: "A", context: "wifi", now: now)
        }
        XCTAssertNil(store.snapshot(nodeKey: "A", context: "wifi", now: now).score)
        for age in [0.0, 10, 20, 30, 40] {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: .responseCompleted, scope: "public"), nodeKey: "A", context: "wifi", now: now)
        }
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertNil(snapshot.score)
        XCTAssertNil(snapshot.successRate)
    }

    @MainActor
    func testDistinctRequestsInSameBurstAreNotDeduplicated() {
        let store = NetworkHealthStore(fileURL: temporaryURL())
        let now = Date()
        for key in ["request-one", "request-two", "request-one"] {
            store.record(event: .init(date: now, kind: .responseCompleted, scope: "public", observationID: key), nodeKey: "A", context: "wifi", now: now)
        }
        XCTAssertEqual(store.records.count, 2)
        XCTAssertNil(store.snapshot(nodeKey: "A", context: "wifi", now: now).score)
    }

    @MainActor
    func testQuarantineOutlastsLiveEvidenceAndCorruptHistoryIsNotOverwritten() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        for age in [165.0, 150, 135, 120, 105] {
            store.record(event: .init(date: now.addingTimeInterval(-age), kind: .connectionFailure, scope: "public"), nodeKey: "A", context: "wifi", now: now)
        }
        let oldFailure = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertTrue(oldFailure.quarantined)
        XCTAssertNil(oldFailure.failureSince, "Old quarantine is not a live failure trigger")
        XCTAssertEqual(store.snapshot(nodeKey: "A", context: "wifi", now: now.addingTimeInterval(901)).quarantined, false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupted = Data("corrupted history".utf8)
        try corrupted.write(to: file)
        let unreadable = NetworkHealthStore(fileURL: file)
        unreadable.record(event: .init(date: now, kind: .connectionReady), nodeKey: "A", context: "wifi", now: now)
        await unreadable.flush()
        XCTAssertNotNil(unreadable.persistenceError)
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }

    func testIncrementalReaderIgnoresExistingHistoryHandlesPartialLinesAndRotation() async throws {
        let file = temporaryURL().deletingLastPathComponent().appendingPathComponent("codex.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = Date().addingTimeInterval(-1)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = timestamp + " error [electron-message-handler] sa_server_request_failed url=https://chatgpt.com/test errorCode=ERR_TIMED_OUT\n"
        try Data(line.utf8).write(to: file)
        let reader = CodexHealthMonitor(directory: file.deletingLastPathComponent(), startedAt: start)
        let initial = await reader.poll()
        XCTAssertTrue(initial.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let bytes = Data(line.utf8)
        try handle.write(contentsOf: bytes.prefix(bytes.count / 2))
        let partial = await reader.poll()
        XCTAssertTrue(partial.isEmpty)
        try handle.write(contentsOf: bytes.suffix(bytes.count - bytes.count / 2))
        try handle.close()
        let completed = await reader.poll()
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.kind, .requestFailure)
        let unchanged = await reader.poll()
        XCTAssertTrue(unchanged.isEmpty)
        try FileManager.default.removeItem(at: file)
        try Data(line.utf8).write(to: file)
        let rotated = await reader.poll()
        XCTAssertEqual(rotated.count, 1)
    }

    func testOversizedPartialLineDiscardsRemainderUntilNewline() async throws {
        let file = temporaryURL().deletingLastPathComponent().appendingPathComponent("codex.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data().write(to: file)
        let reader = CodexHealthMonitor(directory: file.deletingLastPathComponent(), startedAt: Date().addingTimeInterval(-1))
        _ = await reader.poll()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = timestamp + " error [electron-message-handler] sa_server_request_failed url=https://chatgpt.com/test errorCode=ERR_TIMED_OUT\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 65, count: 70 * 1024))
        let oversized = await reader.poll()
        XCTAssertTrue(oversized.isEmpty)
        try handle.write(contentsOf: Data((line + line).utf8))
        try handle.close()
        let events = await reader.poll()
        XCTAssertEqual(events.count, 1, "The date-looking tail of the discarded line is not a new event")
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HopWorld-health-" + UUID().uuidString).appendingPathComponent("history.json")
    }
}

extension NetworkHealthTests {
    func testHistoryQuerySeparatesNodesEnvironmentsTimeAndCategories() {
        let now = Date(timeIntervalSince1970: 10_000)
        func record(_ kind: CodexHealthEvent.Kind, age: Double, context: String = "current", node: String = "A") -> AppHealthRecord {
            let date = now.addingTimeInterval(-age)
            return AppHealthRecord(nodeKey: node, context: context, date: date,
                                   event: .init(date: date, kind: kind))
        }
        let recent = record(.reconnecting, age: 10)
        let records = [record(.connectionFailure, age: 3601), recent,
                       record(.workspaceFailure, age: 20, context: "old"),
                       record(.rateLimited, age: 30), record(.connectionReady, age: -1),
                       record(.reconnecting, age: 5, node: "B"), record(.reconnecting, age: 86401)]
        let query = AppHealthRecordQuery(period: .hour, category: .connection)
        XCTAssertEqual(query.apply(to: records, nodeKey: "A", context: "current", now: now).map(\.id), [recent.id])
        let history = AppHealthRecordQuery(period: .day, category: .workspace, currentEnvironmentOnly: false)
        XCTAssertEqual(history.apply(to: records, nodeKey: "A", context: "current", now: now).count, 1)
        XCTAssertTrue(AppHealthRecordQuery(period: .day, category: .workspace, currentEnvironmentOnly: true)
            .apply(to: records, nodeKey: "A", context: "current", now: now).isEmpty)
    }

    func testVerifiedRequestFilterAndExportExcludePrivateIdentifiers() throws {
        let now = Date()
        let verified = AppHealthRecord(nodeKey: "private-node", context: "private-network", date: now,
            event: .init(date: now, kind: .responseCompleted, scope: "public", observationID: "private-request"))
        let records = [verified,
            AppHealthRecord(nodeKey: "private-node", context: "private-network", date: now,
                event: .init(date: now, kind: .responseProgress, scope: "public", observationID: "fragment")),
            AppHealthRecord(nodeKey: "private-node", context: "private-network", date: now,
                event: .init(date: now, kind: .requestFailure, scope: "unknown", observationID: "unknown"))]
        let filtered = AppHealthRecordQuery(category: .verifiedRequests)
            .apply(to: records, nodeKey: "private-node", context: "private-network", now: now)
        XCTAssertEqual(filtered.map(\.id), [verified.id])
        let data = try AppHealthRecordQuery.export(filtered, currentContext: "private-network", generatedAt: now)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for secret in ["private-node", "private-network", "private-request", verified.id.uuidString] {
            XCTAssertFalse(text.contains(secret))
        }
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(report["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["title"] as? String, verified.event.title)
        XCTAssertEqual(events.first?["environment"] as? String, "当前环境")
        XCTAssertEqual(events.first?["provenance"] as? String, "已确认公网路径")
    }
}

extension NetworkHealthTests {
    @MainActor
    func testRecoveryPipelineUsesExplicitReconnectsWithoutInventingPublicScores() async throws {
        let file = temporaryURL().deletingLastPathComponent().appendingPathComponent("codex.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data().write(to: file)
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 - 60))
        let reader = CodexHealthMonitor(directory: file.deletingLastPathComponent(), startedAt: start)
        let store = NetworkHealthStore(fileURL: file.deletingLastPathComponent().appendingPathComponent("history.json"))
        var tracker = CodexRecoveryTracker()
        tracker.setScope("new-node-session", since: start)
        _ = await reader.poll(now: start)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for age in [0.0, 10, 20] {
            let date = start.addingTimeInterval(age)
            let text = formatter.string(from: date) + " warning [AppServerConnection] app_server_connection.reconnect_started hostId=durable\n"
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            for event in await reader.poll(now: date.addingTimeInterval(0.1)) {
                tracker.observe(event, now: date.addingTimeInterval(0.1))
                store.record(event: event, nodeKey: "A", context: "wifi", now: date.addingTimeInterval(0.1))
            }
        }
        XCTAssertFalse(tracker.shouldRecover(now: start.addingTimeInterval(29.9)))
        XCTAssertTrue(tracker.shouldRecover(now: start.addingTimeInterval(30)))
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: start.addingTimeInterval(30))
        XCTAssertEqual(snapshot.diagnosticFailureCount, 0)
        XCTAssertEqual(snapshot.diagnosticReconnectCount, 3)
        XCTAssertEqual(snapshot.attributedEventCount, 0)
        XCTAssertNil(snapshot.score)
        XCTAssertTrue(ApplicationHealthFailoverPolicy.candidateCanBeProbed(AppHealthSnapshot()))
    }

    func testCanonicalResponseStopsReconnectAndSettingsFailureStartsItsOwnEpisode() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var tracker = CodexRecoveryTracker()
        tracker.setScope("session", since: start)
        let messages = [
            (0.0, "AppServerConnection", "app_server_connection.reconnect_started hostId=durable"),
            (10, "AppServerConnection", "app_server_connection.reconnect_started hostId=durable"),
            (20, "electron-message-handler", "Reasoning summary item completed summary=ignored"),
            (25, "electron-message-handler", "workspace_settings_load_failed")
        ]
        for (age, source, message) in messages {
            let date = start.addingTimeInterval(age)
            let event = try XCTUnwrap(CodexHealthLogParser.parse(formatter.string(from: date)
                + " warning [" + source + "] " + message))
            tracker.observe(event, now: date)
        }
        XCTAssertFalse(tracker.shouldRecover(now: start.addingTimeInterval(54.9)))
        XCTAssertTrue(tracker.shouldRecover(now: start.addingTimeInterval(55)))
        XCTAssertEqual(tracker.failureSince, start.addingTimeInterval(25))
        XCTAssertEqual(tracker.latestProgressAt, start.addingTimeInterval(20))
    }

}

extension NetworkHealthTests {
    @MainActor
    func testHealthHistorySurvivesAgeRestartAndNewObservations() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date()
        let oldDate = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let store = NetworkHealthStore(fileURL: file)
        store.record(event: .init(date: oldDate, kind: .responseProgress), nodeKey: "A", context: "old-network", now: now)
        store.recordSwitch(from: "A", to: "B", context: "old-network", reason: "持续故障", result: "已回退", now: oldDate)
        await store.flush()
        let restored = NetworkHealthStore(fileURL: file)
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertEqual(restored.switches.count, 1)
        restored.record(event: .init(date: now, kind: .connectionReady), nodeKey: "A", context: "current-network", now: now)
        restored.recordSwitch(from: "B", to: "A", context: "current-network", reason: "持续故障", result: "已恢复", now: now)
        await restored.flush()
        let reopened = NetworkHealthStore(fileURL: file)
        XCTAssertEqual(reopened.records.count, 2)
        XCTAssertEqual(reopened.switches.count, 2)
        XCTAssertTrue(reopened.records.contains { $0.date == oldDate })
        XCTAssertEqual(AppHealthRecordQuery().apply(to: reopened.records, nodeKey: "A", context: "current-network", now: now).count, 2)
        XCTAssertNil(reopened.snapshot(nodeKey: "A", context: "old-network", now: now).lastObservedAt,
                     "Retained history must not become current scoring or switching evidence")
    }

    @MainActor
    func testHistoryKeepsOnlyLatestTenOnLoadAndAcrossRestart() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date()
        let records = (0..<8_000).map { index in
            let date = now.addingTimeInterval(Double(index - 8_000) * 3)
            return AppHealthRecord(nodeKey: "A", context: "network", date: date,
                                   event: .init(date: date, kind: .responseProgress))
        }
        let switches = (0..<200).map { index in
            HealthSwitchRecord(date: now.addingTimeInterval(Double(index - 200)), from: "A", to: "B",
                               context: "network", reason: "持续故障", result: "未恢复")
        }
        let checks = (0..<12).map { index in
            ApplicationCheckRecord(date: now.addingTimeInterval(Double(index - 12)), application: .codex,
                                   nodeKey: "A", available: true, title: "检查正常", detail: "测试")
        }
        struct HistoryFixture: Encodable {
            let records: [AppHealthRecord]
            let switches: [HealthSwitchRecord]
            let checks: [ApplicationCheckRecord]
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(HistoryFixture(records: records, switches: switches, checks: checks)).write(to: file)
        let store = NetworkHealthStore(fileURL: file)
        XCTAssertEqual(store.records.count, 10)
        XCTAssertEqual(store.switches.count, 10)
        XCTAssertEqual(store.checks.count, 10)
        XCTAssertEqual(store.records.first?.id, records.suffix(10).first?.id)
        await store.flush()
        let normalized = try JSONDecoder().decode(HistoryReadback.self, from: Data(contentsOf: file))
        XCTAssertEqual(normalized.records.count, 10)
        XCTAssertEqual(normalized.switches.count, 10)
        XCTAssertEqual(normalized.checks?.count, 10)
        store.record(event: .init(date: now, kind: .reconnecting), nodeKey: "A", context: "network", now: now)
        store.recordSwitch(from: "B", to: "A", context: "network", reason: "持续故障", result: "恢复", now: now)
        await store.flush()
        let restored = NetworkHealthStore(fileURL: file)
        XCTAssertEqual(restored.records.count, 10)
        XCTAssertEqual(restored.switches.count, 10)
        XCTAssertEqual(restored.checks.count, 10)
        XCTAssertEqual(restored.records.first?.id, records.suffix(9).first?.id)
        XCTAssertEqual(restored.switches.first?.id, switches.suffix(9).first?.id)
    }

    private struct HistoryReadback: Decodable {
        let records: [AppHealthRecord]
        let switches: [HealthSwitchRecord]
        let checks: [ApplicationCheckRecord]?
    }

    @MainActor
    func testHistoryLimitSeparatesNodesAndApplicationsAcrossConfigurationChanges() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date()
        let firstID = UUID()
        let secondID = UUID()
        let store = NetworkHealthStore(fileURL: file)
        for index in 0..<15 {
            let date = now.addingTimeInterval(Double(index - 15) * 3)
            for id in [firstID, secondID] {
                store.record(event: .init(date: date, kind: .responseProgress),
                             nodeKey: index < 8 ? "old-config" : "new-config", context: "network-\(index)", now: now, nodeID: id)
                for application: HealthApplication in [.claude, .cursor] {
                    store.recordCheck(.init(date: date, application: application, nodeKey: "config-\(index)", nodeID: id,
                                            available: true, title: "检查正常", detail: "测试"))
                }
            }
        }
        for id in [firstID, secondID] {
            XCTAssertEqual(store.records.filter { $0.nodeID == id }.count, 10)
            XCTAssertEqual(store.records.filter { $0.nodeID == id }.first?.date, now.addingTimeInterval(-30))
            for application: HealthApplication in [.claude, .cursor] {
                XCTAssertEqual(store.checks.filter { $0.nodeID == id && $0.application == application }.count, 10)
            }
        }
        await store.flush()
        let restored = NetworkHealthStore(fileURL: file)
        XCTAssertEqual(restored.records.count, 20)
        XCTAssertEqual(restored.checks.count, 40)
        XCTAssertEqual(restored.records.map(\.id), store.records.map(\.id))
        XCTAssertEqual(restored.checks.map(\.id), store.checks.map(\.id))
    }

    @MainActor
    func testLegacyAndIdentifiedRecordsShareEachNodesQuotaWithoutMergingDistinctIDs() async throws {
        struct Fixture: Encodable {
            let records: [AppHealthRecord]
            let switches: [HealthSwitchRecord] = []
            let checks: [ApplicationCheckRecord]
        }
        for nodeIDs in [[UUID()], [UUID(), UUID()]] {
            let file = temporaryURL()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let now = Date()
            var records: [AppHealthRecord] = []
            var checks: [ApplicationCheckRecord] = []
            func append(date: Date, nodeID: UUID?) {
                records.append(.init(nodeKey: "same-key", context: "network", date: date,
                                     event: .init(date: date, kind: .responseProgress), nodeID: nodeID))
                for application: HealthApplication in [.codex, .claude] {
                    checks.append(.init(date: date, application: application, nodeKey: "same-key", nodeID: nodeID,
                                        available: true, title: "检查正常", detail: "测试"))
                }
            }
            for index in 0..<10 { append(date: now.addingTimeInterval(Double(index - 100)), nodeID: nil) }
            for (group, nodeID) in nodeIDs.enumerated() {
                for index in 0..<10 { append(date: now.addingTimeInterval(Double(group * 20 + index - 50)), nodeID: nodeID) }
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Fixture(records: records, checks: checks)).write(to: file)
            let store = NetworkHealthStore(fileURL: file)
            XCTAssertEqual(store.records.count, nodeIDs.count * 10)
            XCTAssertEqual(store.checks.count, nodeIDs.count * 20)
            for nodeID in nodeIDs {
                XCTAssertEqual(store.records.filter { $0.belongsToNode(nodeKey: "same-key", nodeID: nodeID) }.count, 10)
                for application: HealthApplication in [.codex, .claude] {
                    XCTAssertEqual(store.checks.filter { $0.application == application && $0.belongsToNode(nodeKey: "same-key", nodeID: nodeID) }.count, 10)
                }
            }
            store.record(event: .init(date: now, kind: .responseProgress), nodeKey: "same-key", context: "network", now: now)
            store.recordCheck(.init(date: now, application: .codex, nodeKey: "same-key", available: true, title: "检查正常", detail: "测试"))
            for nodeID in nodeIDs {
                XCTAssertEqual(store.records.filter { $0.belongsToNode(nodeKey: "same-key", nodeID: nodeID) }.count, 10)
                XCTAssertEqual(store.checks.filter { $0.application == .codex && $0.belongsToNode(nodeKey: "same-key", nodeID: nodeID) }.count, 10)
            }
            await store.flush()
            let restored = NetworkHealthStore(fileURL: file)
            XCTAssertEqual(restored.records.map(\.id), store.records.map(\.id))
            XCTAssertEqual(restored.checks.map(\.id), store.checks.map(\.id))
        }
    }

    @MainActor
    func testNewestRecordAtEqualTimestampReplacesOldestWithoutInventingScore() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date()
        let store = NetworkHealthStore(fileURL: file)
        for index in 0..<11 {
            store.record(event: .init(date: now, kind: .responseProgress, scope: "public", observationID: "fragment-\(index)"),
                         nodeKey: "A", context: "network", now: now)
        }
        XCTAssertEqual(store.records.count, 10)
        XCTAssertEqual(store.records.first?.event.observationID, "fragment-1")
        XCTAssertEqual(store.records.last?.event.observationID, "fragment-10")
        let snapshot = store.snapshot(nodeKey: "A", context: "network", now: now)
        XCTAssertNil(snapshot.score)
        XCTAssertEqual(snapshot.verifiedRequestCount, 0)
        await store.flush()
        XCTAssertEqual(NetworkHealthStore(fileURL: file).records.map(\.id), store.records.map(\.id))
    }

    func testHistoryQueryDefaultsToAllRetainedTimeAndEnvironments() {
        let now = Date()
        let dates = [now.addingTimeInterval(-4 * 24 * 60 * 60), now.addingTimeInterval(-60)]
        let records = dates.enumerated().map { index, date in
            AppHealthRecord(nodeKey: "A", context: index == 0 ? "old" : "current", date: date,
                            event: .init(date: date, kind: .connectionReady))
        }
        let query = AppHealthRecordQuery()
        XCTAssertEqual(query.period, .all)
        XCTAssertFalse(query.currentEnvironmentOnly)
        XCTAssertEqual(query.apply(to: records, nodeKey: "A", context: "current", now: now).map(\.id), records.reversed().map(\.id))
        XCTAssertEqual(AppHealthRecordQuery(period: .day).apply(to: records, nodeKey: "A", context: "current", now: now).count, 1)
        XCTAssertEqual(AppHealthRecordQuery(currentEnvironmentOnly: true).apply(to: records, nodeKey: "A", context: "current", now: now).count, 1)
    }
}

extension NetworkHealthTests {
    @MainActor
    func testRetainedResponseRemainsVisibleAsHistoryWithoutCreditingCurrentHealth() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        let old = now.addingTimeInterval(-3 * 86400)
        store.record(event: .init(date: old, kind: .responseProgress), nodeKey: "A", context: "wifi", now: now)
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.diagnostic.state, .idle)
        XCTAssertEqual(snapshot.diagnostic.lastResponseAt, old)
        XCTAssertNil(snapshot.lastSuccessAt)
        XCTAssertNil(snapshot.score)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertEqual(snapshot.diagnosticEventCount, 0)
        XCTAssertEqual(store.records.count, 1)
    }
}

extension NetworkHealthTests {
    @MainActor
    func testNodeHistorySurvivesConfigurationChangesWithoutMergingHealthEvidence() async throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let nodeID = UUID()
        let now = Date()
        let store = NetworkHealthStore(fileURL: file)
        store.record(event: .init(date: now.addingTimeInterval(-10), kind: .responseProgress),
                     nodeKey: "old-config", context: "old-environment", now: now, nodeID: nodeID)
        store.record(event: .init(date: now, kind: .connectionReady),
                     nodeKey: "new-config", context: "new-environment", now: now, nodeID: nodeID)
        store.record(event: .init(date: now.addingTimeInterval(-2), kind: .connectionReady),
                     nodeKey: "new-config", context: "new-environment", now: now, nodeID: UUID())
        await store.flush()
        let restored = NetworkHealthStore(fileURL: file)
        let query = AppHealthRecordQuery()
        let history = query.apply(to: restored.records, nodeKey: "new-config", context: "new-environment", now: now, nodeID: nodeID)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(Set(history.compactMap(\.nodeID)), [nodeID])
        XCTAssertEqual(AppHealthRecordQuery(currentEnvironmentOnly: true)
            .apply(to: restored.records, nodeKey: "new-config", context: "new-environment", now: now, nodeID: nodeID).count, 1)
        XCTAssertNil(restored.snapshot(nodeKey: "new-config", context: "new-environment", now: now).diagnostic.lastResponseAt)
        let report = try AppHealthRecordQuery.export(history, currentContext: "new-environment", generatedAt: now)
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains(nodeID.uuidString))
    }
}

extension NetworkHealthTests {
    @MainActor
    func testNoConversationDoesNotBecomeAFailureWhileIdle() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        for elapsed: TimeInterval in [0, 30, 600, 3600] {
            let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now.addingTimeInterval(elapsed))
            XCTAssertEqual(snapshot.status, .unknown)
            XCTAssertEqual(snapshot.diagnostic.state, .idle)
            XCTAssertNil(snapshot.failureSince)
            XCTAssertNil(snapshot.lastFailureAt)
            XCTAssertFalse(snapshot.quarantined)
            XCTAssertFalse(ApplicationHealthFailoverPolicy.currentNeedsRecovery(snapshot, now: now.addingTimeInterval(elapsed)))
        }
        store.record(event: .init(date: now, kind: .connectionReady, scope: "durable", recoveryOrigin: .appServerBridge),
                     nodeKey: "A", context: "wifi", now: now)
        let idle = store.snapshot(nodeKey: "A", context: "wifi", now: now.addingTimeInterval(600))
        XCTAssertEqual(idle.diagnostic.state, .idle)
        XCTAssertNil(idle.diagnostic.lastResponseAt)
        XCTAssertNil(idle.failureSince)
        XCTAssertFalse(idle.quarantined)
    }

    func testExplicitWaitingStatePersistsWithoutTreatingIdleOrBackgroundErrorsAsFailure() {
        let now = Date()
        let background = CodexHealthEvent(date: now, kind: .requestFailure, recoveryOrigin: .request)
        var observation = CodexApplicationObservation()
        observation.observe(background)
        XCTAssertNil(observation.pendingRequestFailure)
        XCTAssertNil(observation.pendingRecoveryFailure)
        XCTAssertFalse(observation.hasPendingNetworkFailure)
        XCTAssertFalse(background.drivesRecovery)
        var tracker = CodexRecoveryTracker()
        tracker.setScope("current-connection", since: now)
        tracker.observe(background, now: now)
        for elapsed: TimeInterval in [30, 600, 3600] {
            XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(elapsed)))
        }
        XCTAssertFalse(background.title.contains("请求网络失败"))
        XCTAssertEqual(AppDiagnosticSnapshot(events: [background], now: now).state, .networkFailure,
                       "Keep the diagnostic without promoting it to automatic recovery")

        let waiting = CodexHealthEvent(date: now.addingTimeInterval(1), kind: .waitingForNetwork,
                                      recoveryOrigin: .responseStream)
        observation.observe(waiting)
        XCTAssertEqual(observation.pendingRequestFailure, waiting)
        XCTAssertEqual(observation.pendingRecoveryFailure, waiting)
        for elapsed: TimeInterval in [20.1, 600, 3600] {
            let pending = AppDiagnosticSnapshot(events: [waiting], now: now.addingTimeInterval(elapsed))
            XCTAssertEqual(pending.state, .waitingForNetwork)
            XCTAssertNil(pending.lastResponseAt, "Silence must not fabricate either failure or recovery")
        }
        let ready = CodexHealthEvent(date: now.addingTimeInterval(3600), kind: .connectionReady,
                                    scope: "durable", recoveryOrigin: .appServerBridge)
        observation.observe(ready)
        XCTAssertEqual(observation.pendingRecoveryFailure, waiting,
                       "A bridge connection cannot clear the conversation's waiting state")
        let response = CodexHealthEvent(date: now.addingTimeInterval(3601), kind: .responseCompleted,
                                       recoveryOrigin: .businessResponse)
        observation.observe(response)
        XCTAssertNil(observation.pendingRecoveryFailure)
        XCTAssertFalse(observation.hasPendingNetworkFailure)
        XCTAssertEqual(AppDiagnosticSnapshot(events: [waiting, response], now: response.date).state, .responding)
    }

    func testSettingsFailuresRequireTheActualWorkspaceRouteAndCanonicalSource() throws {
        let prefix = "2026-10-29T01:00:00.000Z error [electron-message-handler] sa_server_request_failed "
        for address in ["/accounts/workspace-fixture/settings", "/accounts/workspace-fixture/workspace_policy",
                        "/backend-api/accounts/check/v4",
                        "https://chatgpt.com/backend-api/accounts/workspace-fixture/settings"] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "url=\(address) errorCode=ERR_TIMED_OUT status=500"))
            XCTAssertEqual(event.kind, .workspaceFailure)
            XCTAssertEqual(event.workspaceFeature, .settings)
            XCTAssertEqual(event.recoveryOrigin, .request)
            XCTAssertTrue(event.drivesRecovery)
            XCTAssertFalse(event.isNetworkFailure, "Settings failures cannot invent a complete conversation request result")
        }
        for status in [401, 403, 429, 503] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix
                + "url=/accounts/workspace-fixture/settings status=\(status)"))
            XCTAssertEqual(event.workspaceFeature, .settings)
            XCTAssertFalse(event.drivesRecovery, "Login and service errors do not establish a node failure")
        }
        for address in ["/settings/user", "/automations", "/referrals/invite/eligibility",
                        "https://untrusted.example/accounts/workspace-fixture/settings"] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix + "url=\(address) errorCode=ERR_TIMED_OUT"))
            XCTAssertNotEqual(event.workspaceFeature, .settings)
            XCTAssertFalse(event.drivesRecovery)
        }
        let impostor = try XCTUnwrap(CodexHealthLogParser.parse(
            "2026-10-29T01:00:00.000Z error [OtherComponent] workspace_settings_load_failed"))
        XCTAssertNil(impostor.recoveryOrigin)
        XCTAssertFalse(impostor.drivesRecovery)
    }

    func testSettingsStateClearsOnNewResponseAndRejectsBufferedOldFailure() {
        let now = Date()
        let failed = CodexHealthEvent(date: now, kind: .workspaceFailure,
                                     recoveryOrigin: .request, workspaceFeature: .settings)
        var observation = CodexApplicationObservation()
        observation.observe(failed)
        observation.observe(CodexInviteCheckResult.available(eligible: true).healthEvent(at: now.addingTimeInterval(-1)))
        observation.observe(CodexInviteCheckResult.available(eligible: true).healthEvent(at: now.addingTimeInterval(1)))
        observation.observe(.init(date: now.addingTimeInterval(2), kind: .responseProgress,
                                  recoveryOrigin: .businessResponse))
        XCTAssertNil(observation.pendingSettingsFailure)
        XCTAssertNil(observation.pendingRecoveryFailure)
        let response = CodexHealthEvent(date: now.addingTimeInterval(2), kind: .responseProgress, recoveryOrigin: .businessResponse)
        XCTAssertEqual(AppDiagnosticSnapshot(events: [failed, response], now: response.date).state, .responding)
        observation.observe(failed)
        XCTAssertNil(observation.pendingSettingsFailure)
        let newFailure = CodexHealthEvent(date: now.addingTimeInterval(2.5), kind: .workspaceFailure,
                                          recoveryOrigin: .request, workspaceFeature: .settings)
        observation.observe(newFailure)
        XCTAssertEqual(observation.pendingSettingsFailure, newFailure)
        observation.observe(.init(date: now.addingTimeInterval(2.8), kind: .reconnecting,
                                  recoveryOrigin: .appServerBridge))
        observation.observe(.init(date: now.addingTimeInterval(2.7), kind: .responseProgress,
                                  recoveryOrigin: .businessResponse))
        XCTAssertNil(observation.pendingSettingsFailure, "A buffered reply clears older workspace failure without clearing newer reconnect")
        XCTAssertEqual(observation.pendingBridgeFailure?.kind, .reconnecting)
        observation.observe(.init(date: now.addingTimeInterval(3), kind: .workspaceRecovered,
                                  recoveryOrigin: .request, workspaceFeature: .settings))
        XCTAssertNil(observation.pendingSettingsFailure)
        observation.observe(failed)
        XCTAssertNil(observation.pendingSettingsFailure, "A buffered older failure cannot undo the newer settings recovery")
    }

    @MainActor
    func testInviteFailuresStayInFeatureHistoryWithoutAffectingConnectionOrScores() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var observation = CodexApplicationObservation()
        for (index, age) in [30.0, 15, 0].enumerated() {
            let date = now.addingTimeInterval(-age)
            let address = index == 0 ? "/referrals/invite/eligibility" : "https://chatgpt.com/backend-api/referrals/invite/eligibility"
            let event = try XCTUnwrap(CodexHealthLogParser.parse(formatter.string(from: date)
                + " error [electron-message-handler] sa_server_request_failed url=\(address) errorCode=ERR_TIMED_OUT requestId=fixture-\(index)"))
            XCTAssertFalse(event.isNetworkFailure)
            observation.observe(event)
            store.record(event: event, nodeKey: "A", context: "wifi", now: now)
        }
        XCTAssertNotNil(observation.inviteEligibilityFailure)
        XCTAssertNil(observation.pendingRequestFailure)
        XCTAssertFalse(observation.hasPendingNetworkFailure)
        let snapshot = store.snapshot(nodeKey: "A", context: "wifi", now: now)
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertEqual(snapshot.diagnostic.state, .idle)
        XCTAssertTrue(snapshot.diagnostic.workspaceSummary.contains("状态 1 异常"))
        XCTAssertNil(snapshot.lastFailureAt)
        XCTAssertNil(snapshot.diagnostic.lastNetworkFailureAt)
        XCTAssertNil(snapshot.failureSince)
        XCTAssertFalse(snapshot.quarantined)
        XCTAssertEqual(snapshot.diagnosticFailureCount, 0)
        XCTAssertEqual(snapshot.verifiedRequestCount, 0)
        XCTAssertNil(snapshot.score)
        XCTAssertEqual(store.records.count, 3)
        XCTAssertTrue(AppHealthRecordQuery(category: .verifiedRequests)
            .apply(to: store.records, nodeKey: "A", context: "wifi", now: now).isEmpty)
    }

    func testInviteEligibilityNetworkFailureAppearsInWorkspaceWithoutInventingMenuState() throws {
        let prefix = "2026-10-28T01:00:00.000Z error [electron-message-handler] "
        for code in ["ERR_CONNECTION_CLOSED", "ERR_TIMED_OUT", "ERR_CERT_COMMON_NAME_INVALID"] {
            let event = try XCTUnwrap(CodexHealthLogParser.parse(prefix
                + "sa_server_request_failed url=/referrals/invite/eligibility errorCode=\(code) status=500"))
            XCTAssertEqual(event.kind, .requestFailure)
            XCTAssertEqual(event.workspaceFeature, .inviteEligibility)
            XCTAssertEqual(event.recoveryOrigin, .request)
            XCTAssertEqual(event.category, "工作区")
            XCTAssertFalse(event.isNetworkFailure, "A relative app route is not public-node provenance")
            XCTAssertEqual(event.title, "状态 1 异常")
            XCTAssertTrue(event.detail.hasPrefix("状态 1 异常"))
            XCTAssertTrue(event.detail.contains("状态 1"),
                          event.detail)
            let diagnostic = AppDiagnosticSnapshot(events: [event], now: event.date)
            XCTAssertTrue(diagnostic.workspaceSummary.contains("状态 1 异常"))
            XCTAssertEqual(diagnostic.state, .idle)
            XCTAssertNil(diagnostic.lastNetworkFailureAt)
        }
        let challenged = try XCTUnwrap(CodexHealthLogParser.parse(prefix
            + "sa_server_request_failed url=/referrals/invite/eligibility errorCode=cloudflare_challenge status=403"))
        XCTAssertEqual(challenged.kind, .authenticationFailure)
        XCTAssertEqual(challenged.workspaceFeature, .inviteEligibility)
        XCTAssertNil(CodexHealthLogParser.parse(prefix
            + "sa_server_request_failed url=https://untrusted.example/referrals/invite/eligibility errorCode=ERR_TIMED_OUT")?.workspaceFeature)
    }

    func testUnresolvedDiagnosticDoesNotTurnIdleJustBecauseLogsFallSilent() {
        let now = Date()
        let failed = CodexHealthEvent(date: now.addingTimeInterval(-600), kind: .reconnecting,
                                     scope: "durable", recoveryOrigin: .appServerBridge)
        let pending = AppDiagnosticSnapshot(events: [failed], now: now)
        XCTAssertEqual(pending.state, .reconnecting)
        XCTAssertTrue(pending.connectionSummary.contains("故障尚未观测恢复"))
        let ready = CodexHealthEvent(date: now.addingTimeInterval(-300), kind: .connectionReady,
                                    scope: "durable", recoveryOrigin: .appServerBridge)
        let recovered = AppDiagnosticSnapshot(events: [failed, ready], now: now)
        XCTAssertEqual(recovered.state, .idle)
    }

    func testProcessObservationCarriesPendingFailuresUntilExplicitRecovery() {
        let now = Date()
        var observation = CodexApplicationObservation()
        observation.observe(.init(date: now, kind: .reconnecting, scope: "durable", recoveryOrigin: .appServerBridge))
        observation.observe(.init(date: now.addingTimeInterval(1), kind: .requestFailure, recoveryOrigin: .request,
                                  workspaceFeature: .inviteEligibility))
        XCTAssertNotNil(observation.pendingBridgeFailure)
        XCTAssertNotNil(observation.inviteEligibilityFailure)
        observation.observe(.init(date: now.addingTimeInterval(2), kind: .connectionReady, scope: "durable", recoveryOrigin: .appServerBridge))
        XCTAssertNil(observation.pendingBridgeFailure)
        XCTAssertNil(observation.pendingRequestFailure)
        XCTAssertNotNil(observation.inviteEligibilityFailure, "The feature error remains visible without declaring the connection unavailable")
        XCTAssertFalse(observation.hasPendingNetworkFailure)
        observation.observe(.init(date: now.addingTimeInterval(3), kind: .responseProgress, recoveryOrigin: .businessResponse))
        XCTAssertFalse(observation.hasPendingNetworkFailure)
        XCTAssertNotNil(observation.inviteEligibilityFailure, "A conversation response does not prove the invitation feature recovered")
        XCTAssertEqual(observation.lastResponseAt, now.addingTimeInterval(3))
        observation.observe(.init(date: now.addingTimeInterval(4), kind: .requestFailure, recoveryOrigin: .request))
        observation.observe(.init(date: now.addingTimeInterval(5), kind: .authenticationFailure, recoveryOrigin: .request))
        XCTAssertFalse(observation.hasPendingNetworkFailure)
    }

    func testMonitorRestoresPendingProcessStateWithoutReplayingOldNodeEvents() async throws {
        let file = temporaryURL().deletingLastPathComponent().appendingPathComponent("codex.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let oldDate = now.addingTimeInterval(-600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = formatter.string(from: oldDate) + " warning [AppServerConnection] app_server_connection.reconnect_started hostId=durable\n"
        try Data(line.utf8).write(to: file)
        let reader = CodexHealthMonitor(directory: file.deletingLastPathComponent(), startedAt: now,
                                       bootstrapSince: now.addingTimeInterval(-1200))
        let events = await reader.poll(now: now)
        XCTAssertTrue(events.isEmpty)
        let observation = await reader.applicationObservation
        XCTAssertEqual(observation.pendingBridgeFailure?.date, oldDate)
        XCTAssertEqual(observation.pendingBridgeFailure?.recoveryOrigin, .appServerBridge)
        await reader.resetApplicationObservation(since: now)
        _ = await reader.poll(now: now)
        let newProcess = await reader.applicationObservation
        XCTAssertFalse(newProcess.hasPendingNetworkFailure)
    }

    func testMonitorReadsMoreThanEightActiveLogFilesAndRetainsNearFutureEvents() async throws {
        let directory = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let files = (0..<10).map { directory.appendingPathComponent("renderer-\($0).log") }
        for file in files { try Data().write(to: file) }
        let reader = CodexHealthMonitor(directory: directory, startedAt: now.addingTimeInterval(-1))
        _ = await reader.poll(now: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for file in files {
            let text = formatter.string(from: now) + " warning [AppServerConnection] app_server_connection.reconnect_started hostId=durable\n"
            try Data(text.utf8).write(to: file)
        }
        let all = await reader.poll(now: now)
        XCTAssertEqual(all.count, 10, "Every active renderer must be eligible for polling")
        let future = now.addingTimeInterval(2)
        let text = formatter.string(from: future) + " info [AppServerConnection] connection_ready hostId=durable\n"
        let handle = try FileHandle(forWritingTo: files[0])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        let tooEarly = await reader.poll(now: now)
        XCTAssertTrue(tooEarly.isEmpty)
        let due = await reader.poll(now: future)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.kind, .connectionReady)
        let observation = await reader.applicationObservation
        XCTAssertFalse(observation.hasPendingNetworkFailure)
    }

    private func desktopSessionHeader(source: Any = "vscode", originator: String = "Codex Desktop") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": ["source": source, "originator": originator]
        ])
        data.append(10)
        return data
    }

    private func sessionMessage(at date: Date, role: String = "assistant", phase: String = "commentary",
                                type: String = "message") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601DateFormatter().string(from: date), "type": "response_item",
            "payload": ["type": type, "role": role, "phase": phase,
                        "content": [["type": "output_text", "text": "private-fixture-text"]]]
        ])
        data.append(10)
        return data
    }

    func testSessionMetadataRecognizesOnlyActualAssistantMessagesWithoutRetainingText() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (phase, kind): (String, CodexHealthEvent.Kind) in [("commentary", .responseProgress), ("final", .responseCompleted), ("final_answer", .responseCompleted)] {
            let event = try XCTUnwrap(CodexSessionHealthParser.parse(sessionMessage(at: now, phase: phase)))
            XCTAssertEqual(event.kind, kind)
            XCTAssertEqual(event.date, now)
            XCTAssertEqual(event.recoveryOrigin, .businessResponse)
            XCTAssertEqual(event.scope, "unknown")
            XCTAssertFalse(event.isBusinessSuccess, "Local response metadata cannot establish the node's public route")
            XCTAssertNil(event.observationID)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("private-fixture-text"))
        }
        for role in ["user", "developer", "system", "tool"] {
            XCTAssertNil(CodexSessionHealthParser.parse(try sessionMessage(at: now, role: role)))
        }
        for type in ["function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "reasoning", "agent_message"] {
            XCTAssertNil(CodexSessionHealthParser.parse(try sessionMessage(at: now, type: type)))
        }
        XCTAssertNil(CodexSessionHealthParser.parse(try sessionMessage(at: now, phase: "analysis")))
        for type in ["agent_message", "user_message", "task_started", "task_complete", "token_count", "item_completed"] {
            let ignored = try JSONSerialization.data(withJSONObject: [
                "timestamp": ISO8601DateFormatter().string(from: now), "type": "event_msg", "payload": ["type": type]
            ])
            XCTAssertNil(CodexSessionHealthParser.parse(ignored))
        }
        XCTAssertTrue(CodexSessionHealthParser.isDesktopSession(try desktopSessionHeader()))
        XCTAssertFalse(CodexSessionHealthParser.isDesktopSession(try desktopSessionHeader(source: ["subagent": ["thread_spawn": [:]]])))
        XCTAssertFalse(CodexSessionHealthParser.isDesktopSession(try desktopSessionHeader(source: "cli")))
        XCTAssertFalse(CodexSessionHealthParser.isDesktopSession(try desktopSessionHeader(originator: "codex_cli_rs")))
    }

    func testSessionTurnAbortedStopsOnlyTheConversationWait() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601DateFormatter().string(from: now), "type": "event_msg",
            "payload": ["type": "turn_aborted", "reason": "private-fixture-reason"]
        ])
        let event = try XCTUnwrap(CodexSessionHealthParser.parse(record))
        XCTAssertEqual(event.kind, .requestStopped)
        XCTAssertEqual(event.recoveryOrigin, .responseStream)
        XCTAssertFalse(event.drivesRecovery)
        XCTAssertFalse(event.isBusinessSuccess)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("private-fixture-reason"))
        var observation = CodexApplicationObservation()
        observation.observe(.init(date: now.addingTimeInterval(-2), kind: .workspaceFailure,
                                  recoveryOrigin: .request, workspaceFeature: .settings))
        observation.observe(.init(date: now.addingTimeInterval(-1), kind: .waitingForNetwork,
                                  recoveryOrigin: .responseStream))
        observation.observe(event)
        XCTAssertNil(observation.pendingRequestFailure)
        XCTAssertNotNil(observation.pendingSettingsFailure)
        XCTAssertEqual(observation.pendingRecoveryFailure?.workspaceFeature, .settings)
        XCTAssertNil(observation.lastResponseAt, "Stopping a conversation is not a successful reply")
    }

    func testDesktopSessionReaderBaselinesHistoryThenCapturesSplitMessagesAndFutureCompletion() async throws {
        let directory = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try (desktopSessionHeader() + sessionMessage(at: now)).write(to: file)
        let reader = CodexHealthMonitor(directory: directory.appendingPathComponent("missing-logs"),
                                       startedAt: now.addingTimeInterval(-1), sessionDirectory: directory)
        let initial = await reader.poll(now: now)
        XCTAssertTrue(initial.isEmpty, "Existing session history must not be replayed as fresh node evidence")
        await reader.observeInviteCheck(CodexInviteCheckResult.networkFailure.healthEvent(at: now))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let message = try sessionMessage(at: now.addingTimeInterval(1))
        try handle.write(contentsOf: message.prefix(message.count / 2))
        let partial = await reader.poll(now: now.addingTimeInterval(1))
        XCTAssertTrue(partial.isEmpty)
        try handle.write(contentsOf: message.suffix(message.count - message.count / 2))
        let complete = await reader.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(complete.map(\.kind), [.responseProgress])
        let observation = await reader.applicationObservation
        XCTAssertEqual(observation.lastResponseAt, now.addingTimeInterval(1))
        XCTAssertNotNil(observation.inviteEligibilityFailure, "A conversation response does not establish invitation feature recovery")
        try handle.write(contentsOf: sessionMessage(at: now.addingTimeInterval(3), phase: "final_answer"))
        try handle.close()
        let early = await reader.poll(now: now.addingTimeInterval(1))
        XCTAssertTrue(early.isEmpty)
        let due = await reader.poll(now: now.addingTimeInterval(3))
        XCTAssertEqual(due.map(\.kind), [.responseCompleted])
        let unchanged = await reader.poll(now: now.addingTimeInterval(4))
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testNewDesktopSessionsCaptureFirstResponseButIgnoreStaleHistoryAndOtherSources() async throws {
        let directory = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let reader = CodexHealthMonitor(directory: directory.appendingPathComponent("logs"), startedAt: now,
                                       sessionDirectory: directory)
        _ = await reader.poll(now: now)
        try (desktopSessionHeader() + sessionMessage(at: now.addingTimeInterval(-60))
             + sessionMessage(at: now.addingTimeInterval(1), role: "user")
             + sessionMessage(at: now.addingTimeInterval(1), type: "custom_tool_call_output")
             + sessionMessage(at: now.addingTimeInterval(1), phase: "final_answer"))
            .write(to: directory.appendingPathComponent("desktop.jsonl"))
        try (desktopSessionHeader(source: ["subagent": ["thread_spawn": [:]]]) + sessionMessage(at: now.addingTimeInterval(1)))
            .write(to: directory.appendingPathComponent("subagent.jsonl"))
        try (desktopSessionHeader(source: "cli", originator: "codex_cli_rs") + sessionMessage(at: now.addingTimeInterval(1)))
            .write(to: directory.appendingPathComponent("cli.jsonl"))
        let events = await reader.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(events.map(\.kind), [.responseCompleted])
        XCTAssertEqual(events.first?.date, now.addingTimeInterval(1))
        XCTAssertEqual(events.first?.scope, "unknown")
    }

    func testSessionSourceRetriesPartialHeaderAndRevalidatesAfterTruncation() async throws {
        let directory = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let reader = CodexHealthMonitor(directory: directory.appendingPathComponent("logs"), startedAt: now,
                                       sessionDirectory: directory)
        _ = await reader.poll(now: now)
        let header = try desktopSessionHeader()
        try header.prefix(header.count / 2).write(to: file)
        let incomplete = await reader.poll(now: now)
        XCTAssertTrue(incomplete.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: header.suffix(header.count - header.count / 2))
        for _ in 0..<3 { try handle.write(contentsOf: sessionMessage(at: now.addingTimeInterval(1))) }
        try handle.close()
        let recovered = await reader.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(recovered.count, 1, "Identical response metadata at the same timestamp is reported once")
        let replacement = try desktopSessionHeader(source: "cli") + sessionMessage(at: now.addingTimeInterval(2))
        let truncated = try FileHandle(forWritingTo: file)
        try truncated.truncate(atOffset: 0)
        try truncated.write(contentsOf: replacement)
        try truncated.close()
        let ignored = await reader.poll(now: now.addingTimeInterval(2))
        XCTAssertTrue(ignored.isEmpty)
    }

    func testSessionHeaderBudgetAdvancesPastPartialSourcesWithoutStarvingNewResponses() async throws {
        let directory = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let reader = CodexHealthMonitor(directory: directory.appendingPathComponent("logs"), startedAt: now,
                                       sessionDirectory: directory)
        _ = await reader.poll(now: now)
        let header = try desktopSessionHeader()
        for index in 0..<32 {
            try header.prefix(10).write(to: directory.appendingPathComponent(String(format: "a-%02d.jsonl", index)))
        }
        for index in 0..<8 {
            try (header + sessionMessage(at: now.addingTimeInterval(1)))
                .write(to: directory.appendingPathComponent(String(format: "z-%02d.jsonl", index)))
        }
        let budgeted = await reader.poll(now: now.addingTimeInterval(1))
        XCTAssertTrue(budgeted.isEmpty)
        for index in 0..<32 {
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(String(format: "a-%02d.jsonl", index)))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([32]))
            try handle.close()
        }
        let advanced = await reader.poll(now: now.addingTimeInterval(2))
        XCTAssertEqual(advanced.count, 8, "Rotating header validation must reach later sessions even while partial headers grow")
        XCTAssertTrue(advanced.allSatisfy { $0.kind == .responseProgress && $0.scope == "unknown" })
    }

    @MainActor
    func testCurrentSessionDiagnosticBoundaryDoesNotEraseScoreHistory() {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        let now = Date()
        let response = now.addingTimeInterval(-30)
        store.record(event: .init(date: response, kind: .responseProgress, scope: "public"), nodeKey: "A", context: "wifi", now: now)
        store.record(event: .init(date: now, kind: .workspaceFailure), nodeKey: "A", context: "wifi", now: now)
        let current = store.snapshot(nodeKey: "A", context: "wifi", now: now, diagnosticSince: now.addingTimeInterval(-10))
        XCTAssertNil(current.diagnostic.lastResponseAt)
        XCTAssertEqual(current.diagnosticEventCount, 1)
        XCTAssertEqual(current.responseFragmentCount, 0)
        XCTAssertEqual(current.lastSuccessAt, response, "Node evidence uses its own existing score window")
        XCTAssertEqual(store.records.count, 2)
    }
}
