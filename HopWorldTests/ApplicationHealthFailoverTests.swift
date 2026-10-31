import CFNetwork
import XCTest

final class ApplicationHealthFailoverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func failed() -> AppHealthSnapshot {
        var result = AppHealthSnapshot()
        result.status = .unavailable
        result.failureSince = now.addingTimeInterval(-65)
        result.lastSuccessAt = now.addingTimeInterval(-300)
        result.lastFailureAt = now.addingTimeInterval(-3)
        result.lastObservedAt = result.lastFailureAt
        result.lastFailureKind = .requestFailure
        result.quarantined = true
        result.recentFailureCount = 4
        return result
    }

    private func verified() -> AppHealthSnapshot {
        var result = AppHealthSnapshot()
        result.status = .healthy
        result.lastSuccessAt = now.addingTimeInterval(-30)
        result.lastFailureAt = now.addingTimeInterval(-500)
        result.lastObservedAt = result.lastSuccessAt
        result.score = 85
        result.scoreCoverage = 95
        return result
    }

    func testSustainedNetworkFailureCanUseVerifiedCandidate() {
        XCTAssertTrue(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: verified(), now: now))
    }

    func testPublicRecoveryStartsAtThirtySecondsWithoutRequiringCandidateEvidence() {
        var current = failed()
        current.failureSince = now.addingTimeInterval(-30)
        XCTAssertTrue(ApplicationHealthFailoverPolicy.currentNeedsRecovery(current, now: now))
        XCTAssertTrue(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
        current.failureSince = now.addingTimeInterval(-29.9)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.currentNeedsRecovery(current, now: now))
    }

    func testUnknownCandidateMayBeProbedWithoutPretendingItHasPassedRecovery() {
        var candidate = AppHealthSnapshot()
        XCTAssertTrue(ApplicationHealthFailoverPolicy.candidateCanBeProbed(candidate, now: now))
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
        candidate.quarantined = true
        XCTAssertFalse(ApplicationHealthFailoverPolicy.candidateCanBeProbed(candidate, now: now))
        candidate = AppHealthSnapshot()
        candidate.lastServiceFailureAt = now.addingTimeInterval(-10)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.candidateCanBeProbed(candidate, now: now))
        candidate = AppHealthSnapshot()
        candidate.lastFailureAt = now.addingTimeInterval(-10)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.candidateCanBeProbed(candidate, now: now))
        candidate.lastSuccessAt = now.addingTimeInterval(-5)
        XCTAssertTrue(ApplicationHealthFailoverPolicy.candidateCanBeProbed(candidate, now: now))
    }

    private func recoveryTracker() -> CodexRecoveryTracker {
        var tracker = CodexRecoveryTracker()
        tracker.setScope("node-network-connection", since: now.addingTimeInterval(-120))
        return tracker
    }

    private func recoveryEvent(_ kind: CodexHealthEvent.Kind, age: TimeInterval,
                               origin: CodexHealthEvent.RecoveryOrigin = .appServerBridge,
                               scope: String = "durable") -> CodexHealthEvent {
        CodexHealthEvent(date: now.addingTimeInterval(-age), kind: kind, scope: scope, recoveryOrigin: origin)
    }

    func testExplicitReconnectsCanRequestRecoveryWithoutPublicNodeAttribution() {
        var tracker = recoveryTracker()
        for age in [30.0, 20, 10] {
            let event = recoveryEvent(.reconnecting, age: age, scope: "unknown")
            XCTAssertFalse(event.isNetworkFailure)
            tracker.observe(event, now: now)
        }
        XCTAssertTrue(tracker.shouldRecover(now: now))
        XCTAssertEqual(tracker.failureCount, 3)
        XCTAssertEqual(tracker.failureSince, now.addingTimeInterval(-30))
        let cooldown = ApplicationHealthFailoverPolicy.cooldown
        XCTAssertFalse(tracker.shouldRecover(now: now, lastAttemptAt: now.addingTimeInterval(-cooldown + 0.1)))
        XCTAssertTrue(tracker.shouldRecover(now: now, lastAttemptAt: now.addingTimeInterval(-cooldown)))
    }

    func testWaitingForNetworkKeepsThirtySecondDeadlineThroughSilence() {
        var tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 0, origin: .responseStream), now: now)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(29.9)))
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)))
        tracker.observe(recoveryEvent(.waitingForNetwork, age: -40, origin: .responseStream), now: now.addingTimeInterval(40))
        XCTAssertEqual(tracker.failureSince, now, "Retry backoff cannot restart an unresolved request's clock")
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(60)))
        tracker.observe(recoveryEvent(.responseProgress, age: -61, origin: .businessResponse), now: now.addingTimeInterval(61))
        XCTAssertNil(tracker.failureSince)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(90)))
    }

    func testInvitationSuccessCannotHideWaitingForNetwork() {
        var tracker = recoveryTracker()
        var observation = CodexApplicationObservation()
        let first = recoveryEvent(.waitingForNetwork, age: 0, origin: .responseStream)
        tracker.observe(first, now: now)
        observation.observe(first)
        for offset in [4.0, 9, 19, 29] {
            let checkedAt = now.addingTimeInterval(offset)
            let invite = CodexInviteCheckResult.available(eligible: false).healthEvent(at: checkedAt)
            tracker.observe(invite, now: checkedAt)
            observation.observe(invite)
            XCTAssertEqual(observation.pendingNetworkFailure, first)
            XCTAssertEqual(tracker.failureSince, now)
        }
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(29.9)))
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)))
        let ready = recoveryEvent(.connectionReady, age: -30, origin: .appServerBridge)
        tracker.observe(ready, now: now.addingTimeInterval(30))
        observation.observe(ready)
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)))
        XCTAssertEqual(observation.pendingNetworkFailure, first, "Transport readiness cannot clear a failed application request")
        let response = recoveryEvent(.responseCompleted, age: -31, origin: .businessResponse)
        tracker.observe(response, now: now.addingTimeInterval(31))
        observation.observe(response)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(60)))
        XCTAssertNil(observation.pendingNetworkFailure)
    }

    func testReachableInvitationGrantsOneObservationThenOneCountdown() {
        var timing = CodexRecoveryTiming()
        timing.synchronize(scope: "node-one", failureSince: now, inviteReachableAt: nil)
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(30))
        for offset in [10.0, 20, 30, 50, 69] {
            timing.synchronize(scope: "node-one", failureSince: now,
                               inviteReachableAt: now.addingTimeInterval(offset))
            XCTAssertEqual(timing.observationUntil, now.addingTimeInterval(40))
            XCTAssertEqual(timing.switchAt, now.addingTimeInterval(70), "Repeated reachable checks cannot postpone switching")
        }
        timing.synchronize(scope: "node-one", failureSince: now.addingTimeInterval(20),
                           inviteReachableAt: now.addingTimeInterval(70))
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(70), "Partial bridge recovery cannot renew the allowance while a request still fails")
    }

    func testInvitationObservationRequiresCurrentEpisodeAndResetsAfterRecoveryOrNodeChange() {
        var timing = CodexRecoveryTiming()
        timing.synchronize(scope: "node-one", failureSince: nil, inviteReachableAt: now)
        XCTAssertNil(timing.switchAt, "An idle app does not start a failure countdown")
        timing.synchronize(scope: "node-one", failureSince: now, inviteReachableAt: now.addingTimeInterval(-1))
        XCTAssertNil(timing.observationUntil, "An old successful check cannot extend a new failure")
        timing.synchronize(scope: "node-one", failureSince: now, inviteReachableAt: now.addingTimeInterval(10))
        timing.synchronize(scope: "node-one", failureSince: nil, inviteReachableAt: now.addingTimeInterval(20))
        XCTAssertNil(timing.switchAt)
        timing.synchronize(scope: "node-one", failureSince: now.addingTimeInterval(25), inviteReachableAt: now.addingTimeInterval(30))
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(90))
        timing.synchronize(scope: "node-two", failureSince: now.addingTimeInterval(40), inviteReachableAt: nil)
        XCTAssertNil(timing.observationUntil)
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(70))
    }

    func testResponseAndNewFailureInOnePollStartANewObservationEpisode() {
        var timing = CodexRecoveryTiming()
        timing.synchronize(scope: "node-one", failureSince: now, inviteReachableAt: now.addingTimeInterval(10))
        timing.synchronize(scope: "node-one", failureSince: now.addingTimeInterval(25),
                           inviteReachableAt: now.addingTimeInterval(30), recoveredAt: now.addingTimeInterval(20))
        XCTAssertEqual(timing.failureSince, now.addingTimeInterval(25))
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(90))
        timing.synchronize(scope: "node-one", failureSince: now.addingTimeInterval(25),
                           inviteReachableAt: now.addingTimeInterval(40), recoveredAt: now.addingTimeInterval(20))
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(90))
    }

    func testSlowOrTimeoutProneFaultGetsSixtySecondsAndCannotLoseThatGrace() throws {
        var timing = CodexRecoveryTiming()
        timing.synchronize(scope: "slow-node", failureSince: now, inviteReachableAt: nil,
                           minimumFailureDuration: 60)
        let deadline = try XCTUnwrap(timing.switchAt)
        XCTAssertGreaterThan(deadline, now.addingTimeInterval(59.9), "A slow usable node must not switch at the old 30-second deadline")
        XCTAssertEqual(deadline, now.addingTimeInterval(60))
        timing.synchronize(scope: "slow-node", failureSince: now, inviteReachableAt: nil,
                           minimumFailureDuration: 30)
        XCTAssertEqual(timing.switchAt, deadline, "A fluctuating sample cannot shorten grace during the same fault")
        timing.synchronize(scope: "slow-node", failureSince: now, inviteReachableAt: nil,
                           minimumFailureDuration: 45)
        XCTAssertEqual(timing.switchAt, deadline)
    }

    func testConfiguredNinetyNineSecondsSurvivesOldOrNewInviteChecks() {
        var timing = CodexRecoveryTiming()
        timing.synchronize(scope: "long-wait-node", failureSince: now,
                           inviteReachableAt: now.addingTimeInterval(-1), minimumFailureDuration: 99)
        XCTAssertNil(timing.observationUntil, "A success before this fault is not new recovery evidence")
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(99))
        timing.synchronize(scope: "long-wait-node", failureSince: now,
                           inviteReachableAt: now.addingTimeInterval(5), minimumFailureDuration: 30)
        XCTAssertEqual(timing.observationUntil, now.addingTimeInterval(35))
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(99), "An invitation allowance cannot shorten the configured connection wait")
        timing.synchronize(scope: "long-wait-node", failureSince: now,
                           inviteReachableAt: now.addingTimeInterval(80), minimumFailureDuration: 60)
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(99), "Repeated invitation success does not restart the fault")
    }

    func testExtendedGraceResetsOnlyForRecoveredEpisodeOrDifferentScope() {
        var timing = CodexRecoveryTiming()
        timing.synchronize(scope: "node-one", failureSince: now, inviteReachableAt: nil,
                           minimumFailureDuration: 99)
        let newFailure = now.addingTimeInterval(10)
        timing.synchronize(scope: "node-one", failureSince: newFailure, inviteReachableAt: nil,
                           recoveredAt: now.addingTimeInterval(5))
        XCTAssertEqual(timing.switchAt, newFailure.addingTimeInterval(30), "A new fault after actual recovery starts with its own wait")
        timing.synchronize(scope: "node-one", failureSince: newFailure, inviteReachableAt: nil,
                           minimumFailureDuration: 99)
        timing.synchronize(scope: "node-two", failureSince: now.addingTimeInterval(20), inviteReachableAt: nil)
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(50), "The previous node's long wait must not leak into a new connection")
        timing.synchronize(scope: "node-two", failureSince: nil, inviteReachableAt: nil)
        XCTAssertNil(timing.switchAt)
        timing.synchronize(scope: "node-two", failureSince: now.addingTimeInterval(100), inviteReachableAt: nil)
        XCTAssertEqual(timing.switchAt, now.addingTimeInterval(130))
    }

    func testActualResponseEndsOldInvitationFailureRecoveryWithoutInventingFeatureSuccess() {
        var invite = CodexInviteCheckObservation()
        invite.record(result: .networkFailure, at: now)
        invite.observeApplicationResponse(at: now.addingTimeInterval(10))
        XCTAssertEqual(invite.result, .networkFailure, "The invitation diagnostic remains separate from conversation recovery")
        XCTAssertNil(invite.network.failureSince)
        for offset in [20.0, 30, 40] { invite.record(result: .networkFailure, at: now.addingTimeInterval(offset)) }
        invite.observeApplicationResponse(at: now.addingTimeInterval(10))
        XCTAssertEqual(invite.network.failureSince, now.addingTimeInterval(20))
        XCTAssertFalse(invite.needsRecovery(now: now.addingTimeInterval(40)))
        XCTAssertFalse(invite.needsRecovery(now: now.addingTimeInterval(50)), "Invitation failure alone must not switch nodes")
        invite.observeApplicationResponse(at: now.addingTimeInterval(35))
        XCTAssertEqual(invite.network.failureSince, now.addingTimeInterval(40), "A late response preserves only newer failed checks")
        XCTAssertEqual(invite.network.consecutiveFailures, 1)
        XCTAssertFalse(invite.needsRecovery(now: now.addingTimeInterval(70)))
    }

    func testIdleWithoutAConversationNeverStartsRecovery() {
        var tracker = recoveryTracker()
        for elapsed: TimeInterval in [30, 600, 3600] {
            XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(elapsed)))
            XCTAssertNil(tracker.failureSince)
        }
        tracker.observe(recoveryEvent(.connectionReady, age: 0), now: now)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(3600)))
        XCTAssertNil(tracker.latestProgressAt, "No conversation does not imply a response or a failure")
    }

    func testInviteAndGenericRequestFailuresNeverDriveRecovery() {
        var tracker = recoveryTracker()
        for age in [30.0, 15, 0] {
            var event = recoveryEvent(.requestFailure, age: age, origin: .request, scope: "public")
            event.workspaceFeature = .inviteEligibility
            tracker.observe(event, now: now)
        }
        XCTAssertEqual(tracker.failureCount, 0)
        XCTAssertNil(tracker.failureSince)
        XCTAssertFalse(tracker.shouldRecover(now: now))
        for age in [30.0, 15, 0] {
            tracker.observe(recoveryEvent(.requestFailure, age: age, origin: .request), now: now)
        }
        XCTAssertFalse(tracker.shouldRecover(now: now))
        XCTAssertNil(tracker.failureSince)
    }

    func testWorkspaceFailureKeepsItsOwnTimerUntilSettingsRecover() {
        var tracker = recoveryTracker()
        var workspace = recoveryEvent(.workspaceFailure, age: 0, origin: .request)
        workspace.workspaceFeature = .settings
        tracker.observe(workspace, now: now)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(29.9)))
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)))
        let activity: [(TimeInterval, CodexHealthEvent.Kind, CodexHealthEvent.RecoveryOrigin)] = [
            (10, .connectionReady, .appServerBridge), (20, .responseProgress, .businessResponse)
        ]
        for (offset, kind, origin) in activity {
            tracker.observe(recoveryEvent(kind, age: -offset, origin: origin), now: now.addingTimeInterval(offset))
            XCTAssertEqual(tracker.failureSince, now, "Connection activity cannot prove settings loaded")
            XCTAssertFalse(tracker.hasRecovered(since: now, allowTransportReady: true, now: now.addingTimeInterval(30)))
        }
        var recovered = recoveryEvent(.workspaceRecovered, age: -31, origin: .request)
        recovered.workspaceFeature = .settings
        tracker.observe(recovered, now: now.addingTimeInterval(31))
        XCTAssertNil(tracker.failureSince)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(60)))
    }

    func testSettingsRecoveryDoesNotClearASeparateWaitingForNetworkState() {
        var tracker = recoveryTracker()
        var workspace = recoveryEvent(.workspaceFailure, age: 30, origin: .request)
        workspace.workspaceFeature = .settings
        tracker.observe(workspace, now: now)
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 20, origin: .responseStream), now: now)
        var recovered = recoveryEvent(.workspaceRecovered, age: 0, origin: .request)
        recovered.workspaceFeature = .settings
        tracker.observe(recovered, now: now)
        XCTAssertEqual(tracker.failureSince, now.addingTimeInterval(-20))
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(10)))
    }

    func testSettingsAuthenticationAndServiceFailuresStopOnlySettingsCountdown() {
        for kind: CodexHealthEvent.Kind in [.authenticationFailure, .rateLimited, .serviceFailure] {
            var tracker = recoveryTracker()
            var workspace = recoveryEvent(.workspaceFailure, age: 30, origin: .request)
            workspace.workspaceFeature = .settings
            tracker.observe(workspace, now: now)
            var service = recoveryEvent(kind, age: 0, origin: .request)
            service.workspaceFeature = .settings
            tracker.observe(service, now: now)
            XCTAssertNil(tracker.failureSince)
            XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(60)))
        }
    }

    func testGenericConnectionAndBackgroundErrorsCannotStartOrRestartRecovery() {
        var tracker = recoveryTracker()
        for age in [30.0, 15, 0] {
            tracker.observe(recoveryEvent(.connectionFailure, age: age), now: now)
            tracker.observe(recoveryEvent(.requestFailure, age: age, origin: .request), now: now)
        }
        XCTAssertNil(tracker.failureSince)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(3600)))
        tracker.observe(recoveryEvent(.reconnecting, age: 0), now: now)
        tracker.observe(recoveryEvent(.requestFailure, age: -10, origin: .request), now: now.addingTimeInterval(10))
        XCTAssertEqual(tracker.failureSince, now)
        XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)))
    }

    func testStoppedConversationClearsOnlyItsStreamCountdown() {
        var tracker = recoveryTracker()
        var workspace = recoveryEvent(.workspaceFailure, age: 40, origin: .request)
        workspace.workspaceFeature = .settings
        tracker.observe(workspace, now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 35), now: now)
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 30, origin: .responseStream), now: now)
        tracker.observe(recoveryEvent(.requestStopped, age: 0, origin: .responseStream), now: now)
        XCTAssertEqual(tracker.failureSince, now.addingTimeInterval(-40))
        var recovered = recoveryEvent(.workspaceRecovered, age: 0, origin: .request)
        recovered.workspaceFeature = .settings
        tracker.observe(recovered, now: now)
        XCTAssertEqual(tracker.failureSince, now.addingTimeInterval(-35), "Stopping one request cannot hide bridge reconnecting")
        tracker.observe(recoveryEvent(.connectionReady, age: 0), now: now)
        XCTAssertNil(tracker.failureSince)
        XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(60)))
    }

    func testBackgroundServiceErrorsCannotHidePrimaryInterruptionOrBlockBufferedEvents() {
        var tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.reconnecting, age: 30), now: now)
        for kind: CodexHealthEvent.Kind in [.authenticationFailure, .rateLimited, .serviceFailure] {
            tracker.observe(recoveryEvent(kind, age: 0, origin: .request), now: now)
            XCTAssertTrue(tracker.shouldRecover(now: now))
        }
        tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.serviceFailure, age: 0, origin: .request), now: now)
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 30, origin: .responseStream), now: now)
        XCTAssertTrue(tracker.shouldRecover(now: now), "A generic API event must not advance the primary event watermark")
    }

    func testPrimaryConnectionStatesUseThirtySecondDeadlineWithoutMoreLogLines() {
        for kind: CodexHealthEvent.Kind in [.reconnecting, .waitingForNetwork] {
            var tracker = recoveryTracker()
            tracker.observe(recoveryEvent(kind, age: 0), now: now)
            XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(29.9)))
            XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)), "A canonical unresolved bridge state persists during retry backoff")
            XCTAssertEqual(tracker.failureSince, now)
            let checkAt = now.addingTimeInterval(30)
            let cooldown = ApplicationHealthFailoverPolicy.cooldown
            XCTAssertFalse(tracker.shouldRecover(now: checkAt, lastAttemptAt: checkAt.addingTimeInterval(-cooldown + 0.1)))
            XCTAssertTrue(tracker.shouldRecover(now: checkAt, lastAttemptAt: checkAt.addingTimeInterval(-cooldown)))
        }
    }

    func testRealBridgeRetryTimingDoesNotRestartTheDeadlineAfterTwentySecondBackoff() {
        var tracker = recoveryTracker()
        let timeline: [(TimeInterval, CodexHealthEvent.Kind)] = [
            (0, .reconnecting), (13.645, .connectionFailure), (33.649, .reconnecting),
            (48.656, .connectionFailure), (68.659, .reconnecting)
        ]
        for (offset, kind) in timeline {
            let date = now.addingTimeInterval(offset)
            tracker.observe(.init(date: date, kind: kind, scope: "durable", recoveryOrigin: .appServerBridge), now: date)
            XCTAssertEqual(tracker.failureSince, now, "Retry scheduling must not start a new failure episode")
            if offset == 13.645 {
                XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(29.9)))
                XCTAssertTrue(tracker.shouldRecover(now: now.addingTimeInterval(30)))
            }
            if offset >= 30 { XCTAssertTrue(tracker.shouldRecover(now: date)) }
        }
    }

    func testThirtyAndSixtySecondBridgeBackoffDoesNotEraseAnUnresolvedReconnect() {
        for interval: TimeInterval in [30, 60] {
            var tracker = recoveryTracker()
            tracker.observe(recoveryEvent(.reconnecting, age: 0), now: now)
            let next = now.addingTimeInterval(interval)
            tracker.observe(.init(date: next, kind: .connectionFailure, scope: "durable", recoveryOrigin: .appServerBridge), now: next)
            XCTAssertEqual(tracker.failureSince, now)
            XCTAssertTrue(tracker.shouldRecover(now: next))
        }
    }

    func testExplicitBridgeRecoveryServiceErrorsAndScopeChangesClearTheDeadline() {
        for kind: CodexHealthEvent.Kind in [.connectionReady, .responseProgress, .responseCompleted, .authenticationFailure, .rateLimited, .serviceFailure] {
            var tracker = recoveryTracker()
            tracker.observe(recoveryEvent(.reconnecting, age: 0), now: now)
            let origin: CodexHealthEvent.RecoveryOrigin = kind == .connectionReady ? .appServerBridge
                : (kind == .responseProgress || kind == .responseCompleted ? .businessResponse : .appServerBridge)
            let date = now.addingTimeInterval(20)
            tracker.observe(.init(date: date, kind: kind, scope: "durable", recoveryOrigin: origin), now: date)
            XCTAssertNil(tracker.failureSince)
            XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(30)))
        }
        for scope: String? in ["another-node-network-connection", nil] {
            var tracker = recoveryTracker()
            tracker.observe(recoveryEvent(.reconnecting, age: 0), now: now)
            tracker.setScope(scope, since: now.addingTimeInterval(20))
            XCTAssertNil(tracker.failureSince)
            XCTAssertFalse(tracker.shouldRecover(now: now.addingTimeInterval(30)))
        }
    }

    func testShortDiagnosticFailuresDoNotSwitch() {
        var tracker = recoveryTracker()
        for age in [29.9, 15, 0] { tracker.observe(recoveryEvent(.reconnecting, age: age), now: now) }
        XCTAssertFalse(tracker.shouldRecover(now: now))
    }

    func testOldUnclassifiedLocalFutureAndDuplicateEventsDoNotBuildAnEpisode() {
        var tracker = recoveryTracker()
        tracker.observe(.init(date: now.addingTimeInterval(-30), kind: .reconnecting), now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 25, scope: "local"), now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 20, scope: "unconfirmed-route"), now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: -1), now: now)
        XCTAssertEqual(tracker.failureCount, 0)
        tracker.observe(recoveryEvent(.reconnecting, age: 10), now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 10), now: now)
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 10, origin: .responseStream), now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 9), now: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 15), now: now)
        XCTAssertEqual(tracker.failureCount, 1, "One log burst cannot supply three independent observations")
        XCTAssertFalse(tracker.shouldRecover(now: now))
        tracker.setScope("another-node-network-connection", since: now)
        XCTAssertEqual(tracker.failureCount, 0)
        tracker.observe(recoveryEvent(.reconnecting, age: 1), now: now)
        XCTAssertEqual(tracker.failureCount, 0)
        tracker.setScope(nil, since: now)
        tracker.observe(recoveryEvent(.reconnecting, age: 0), now: now)
        XCTAssertEqual(tracker.failureCount, 0)
    }

    func testProgressAndServiceErrorsEndTheEpisodeWithoutInventingPublicSuccess() {
        for kind: CodexHealthEvent.Kind in [.responseProgress, .responseCompleted, .authenticationFailure, .rateLimited, .serviceFailure] {
            var tracker = recoveryTracker()
            for age in [30.0, 15, 1] { tracker.observe(recoveryEvent(.reconnecting, age: age), now: now) }
            let origin: CodexHealthEvent.RecoveryOrigin = kind == .responseProgress || kind == .responseCompleted ? .businessResponse : .appServerBridge
            let event = recoveryEvent(kind, age: 0, origin: origin, scope: "unknown")
            XCTAssertFalse(event.isBusinessSuccess)
            tracker.observe(event, now: now)
            XCTAssertFalse(tracker.shouldRecover(now: now))
            XCTAssertEqual(tracker.failureCount, 0)
        }
        var tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.authenticationFailure, age: 40, origin: .request), now: now)
        for age in [30.0, 15, 0] { tracker.observe(recoveryEvent(.waitingForNetwork, age: age, origin: .responseStream), now: now) }
        XCTAssertTrue(tracker.shouldRecover(now: now), "A new thirty-second network episode is independent of an older authentication error")
    }

    func testTransportReadyOnlyClearsBridgeFailuresAndNotWaitingForNetwork() {
        var bridge = recoveryTracker()
        var request = recoveryTracker()
        for age in [30.0, 15, 1] {
            bridge.observe(recoveryEvent(.reconnecting, age: age), now: now)
            request.observe(recoveryEvent(.waitingForNetwork, age: age, origin: .responseStream), now: now)
        }
        bridge.observe(recoveryEvent(.connectionReady, age: 0), now: now)
        request.observe(recoveryEvent(.connectionReady, age: 0), now: now)
        XCTAssertFalse(bridge.shouldRecover(now: now))
        XCTAssertNil(bridge.latestProgressAt)
        XCTAssertTrue(request.shouldRecover(now: now))
        XCTAssertTrue(request.hasRequestFailureInEpisode)
        request.observe(recoveryEvent(.workspaceRecovered, age: 0, origin: .request), now: now)
        XCTAssertTrue(request.shouldRecover(now: now))
    }

    func testRecoveryVerificationRequiresNewUninterruptedAppEvidence() {
        let since = now.addingTimeInterval(-10)
        var tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.responseProgress, age: 20, origin: .businessResponse), now: now)
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: false, now: now))
        tracker.observe(recoveryEvent(.responseProgress, age: 5, origin: .businessResponse), now: now)
        XCTAssertTrue(tracker.hasRecovered(since: since, allowTransportReady: false, now: now))
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 0, origin: .responseStream), now: now)
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: true, now: now))
        tracker.observe(recoveryEvent(.responseProgress, age: -1, origin: .businessResponse), now: now.addingTimeInterval(1))
        XCTAssertTrue(tracker.hasRecovered(since: since, allowTransportReady: false, now: now.addingTimeInterval(1)))
        tracker.observe(recoveryEvent(.serviceFailure, age: -2, origin: .responseStream), now: now.addingTimeInterval(2))
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: true, now: now.addingTimeInterval(2)))
    }

    func testBridgeReadyMustRemainStableTenSecondsAndCannotVerifyRequestRecovery() {
        let since = now.addingTimeInterval(-30)
        var tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.connectionReady, age: 10), now: now)
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: false, now: now))
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: true, now: now.addingTimeInterval(-0.1)))
        XCTAssertTrue(tracker.hasRecovered(since: since, allowTransportReady: true, now: now))
        XCTAssertNil(tracker.latestProgressAt)
        tracker.observe(recoveryEvent(.reconnecting, age: 0), now: now)
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: true, now: now))
        tracker = recoveryTracker()
        tracker.observe(recoveryEvent(.waitingForNetwork, age: 20, origin: .responseStream), now: now)
        tracker.observe(recoveryEvent(.connectionReady, age: 10), now: now)
        XCTAssertFalse(tracker.hasRecovered(since: since, allowTransportReady: true, now: now))
    }

    func testBriefStaleAndSparseFailuresDoNotTriggerSwitch() {
        var current = failed()
        current.failureSince = now.addingTimeInterval(-29)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
        current = failed()
        current.lastFailureAt = now.addingTimeInterval(-21)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
        current = failed()
        current.recentFailureCount = 2
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
    }

    func testBusinessProgressSuppressesReconnectSwitch() {
        var current = failed()
        current.lastSuccessAt = now.addingTimeInterval(-10)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
        current.status = .mild
        current.recentFailureCount = 10
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
    }

    func testUnknownUnscoredAndExpiredCandidatesCannotQualify() {
        var candidate = verified()
        candidate.status = .unknown
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
        candidate = verified()
        candidate.score = nil
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
        candidate = verified()
        candidate.lastSuccessAt = now.addingTimeInterval(-901)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
        candidate = verified()
        candidate.score = 40
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
    }

    func testCandidateMustHaveRecoveredAfterItsOwnFailure() {
        var candidate = verified()
        candidate.lastFailureAt = now.addingTimeInterval(-5)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
        candidate = verified()
        candidate.failureSince = now.addingTimeInterval(-100)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
        candidate = verified()
        candidate.quarantined = true
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
    }

    func testAuthenticationRateLimitOrServerFailurePausesSwitch() {
        var current = failed()
        current.lastServiceFailureAt = now.addingTimeInterval(-20)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: current, candidate: verified(), now: now))
        var candidate = verified()
        candidate.lastServiceFailureAt = now.addingTimeInterval(-20)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: candidate, now: now))
    }

    func testRecoveryOnlyDebouncesOverlappingAttemptsWithoutBlockingANewNodeFailure() {
        let cooldown = ApplicationHealthFailoverPolicy.cooldown
        XCTAssertLessThan(cooldown, ApplicationHealthFailoverPolicy.failureDuration)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: verified(), now: now,
            lastAttemptAt: now.addingTimeInterval(-cooldown + 0.1)))
        XCTAssertFalse(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: verified(), now: now,
            lastAttemptAt: now.addingTimeInterval(5)))
        XCTAssertTrue(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: verified(), now: now,
            lastAttemptAt: now.addingTimeInterval(-cooldown)))
        XCTAssertTrue(ApplicationHealthFailoverPolicy.shouldSwitch(current: failed(), candidate: verified(), now: now,
            lastAttemptAt: now.addingTimeInterval(-ApplicationHealthFailoverPolicy.failureDuration)))
    }

    func testOrderedRecoveryContinuesAfterCurrentNodeBeforeWrappingToTheFirst() {
        let ordered = [1, 2, 3, 4]
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: 2), [3, 4, 1])
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: 3), [4, 1, 2])
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: 4), [1, 2, 3])
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: nil), ordered)
    }

    func testOrderedRecoveryDoesNotRevisitFailedNodesOrSilentlyCapTheRemainingQueue() {
        let ordered = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: 2, excluding: [1, 2]), [3, 4, 5, 6])
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: 3, excluding: [1, 2, 3]), [4, 5, 6])
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: ordered, after: 6, excluding: Set(ordered)), [])
    }

    func testOrderedRecoveryDeduplicatesAndAllowsEligibilityFilteringAfterRotation() {
        let completeOrder = [1, 2, 2, 3, 4]
        let eligible: Set<Int> = [1, 3, 4]
        let rotated = ApplicationHealthFailoverPolicy.orderedCandidates(in: completeOrder, after: 2)
        XCTAssertEqual(rotated.filter { eligible.contains($0) }, [3, 4, 1], "Rotate before filtering the failed current node out")
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: completeOrder, after: 99), [1, 2, 3, 4])
        XCTAssertEqual(ApplicationHealthFailoverPolicy.orderedCandidates(in: [Int](), after: nil), [])
    }

    func testSameRecentFailureAcrossDistinctNodesPausesRotation() {
        XCTAssertTrue(ApplicationHealthFailoverPolicy.hasCommonFailure(snapshots: [failed(), failed()], now: now))
        var other = failed()
        other.lastFailureKind = .connectionFailure
        XCTAssertFalse(ApplicationHealthFailoverPolicy.hasCommonFailure(snapshots: [failed(), other], now: now))
        other = failed()
        other.lastFailureAt = now.addingTimeInterval(-301)
        XCTAssertFalse(ApplicationHealthFailoverPolicy.hasCommonFailure(snapshots: [failed(), other], now: now))
        XCTAssertFalse(ApplicationHealthFailoverPolicy.hasCommonFailure(snapshots: [failed(), verified()], now: now))
    }

    func testReferencePathRequiresCompletedFailuresForThirtySeconds() {
        var observation = CodexPathObservation()
        XCTAssertNil(observation.reachable)
        XCTAssertNil(observation.failureSince)
        XCTAssertNil(observation.lastCheckedAt)
        XCTAssertFalse(observation.needsRecovery(now: now))
        for offset: TimeInterval in [0, 10, 20] {
            observation.record(reachable: false, at: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(observation.consecutiveFailures, 3)
        XCTAssertEqual(observation.failureSince, now)
        XCTAssertEqual(observation.lastCheckedAt, now.addingTimeInterval(20))
        XCTAssertEqual(observation.reachable, false)
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(29.9)))
        XCTAssertTrue(observation.needsRecovery(now: now.addingTimeInterval(30)))
    }

    func testReferencePathSilenceCannotInventExtraFailuresOrKeepAnOldFailureActive() {
        var observation = CodexPathObservation()
        observation.record(reachable: false, at: now)
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(30)))
        XCTAssertEqual(observation.consecutiveFailures, 1)
        observation.record(reachable: false, at: now.addingTimeInterval(10))
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(30)))
        observation.record(reachable: false, at: now.addingTimeInterval(20))
        XCTAssertTrue(observation.needsRecovery(now: now.addingTimeInterval(40)))
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(40.001)))
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(300)))
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(19)), "A future measurement is not current evidence")
    }

    func testReferencePathSuccessEndsTheFailureEpisodeAndOlderResultsCannotUndoIt() {
        var observation = CodexPathObservation()
        for offset: TimeInterval in [0, 10, 20] {
            observation.record(reachable: false, at: now.addingTimeInterval(offset))
        }
        observation.record(reachable: true, at: now.addingTimeInterval(30))
        XCTAssertNil(observation.failureSince)
        XCTAssertEqual(observation.consecutiveFailures, 0)
        XCTAssertEqual(observation.reachable, true)
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(30)))
        observation.record(reachable: false, at: now.addingTimeInterval(25))
        XCTAssertEqual(observation.reachable, true)
        XCTAssertEqual(observation.lastCheckedAt, now.addingTimeInterval(30))
        observation.record(reachable: false, at: now.addingTimeInterval(40))
        XCTAssertEqual(observation.consecutiveFailures, 1)
        XCTAssertEqual(observation.failureSince, now.addingTimeInterval(40))
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(70)))
    }

    func testReferencePathRetryTimingDoesNotResetUninterruptedFailedChecks() {
        var observation = CodexPathObservation()
        for offset: TimeInterval in [0, 20.004, 40.008] {
            observation.record(reachable: false, at: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(observation.failureSince, now)
        XCTAssertTrue(observation.needsRecovery(now: now.addingTimeInterval(40.008)))
    }
}

final class CodexInviteEligibilityProbeTests: XCTestCase {
    func testActiveChecksCannotHideBufferedBridgeFailuresOrBeUndoneByOlderInviteLogs() {
        let now = Date()
        var observation = CodexApplicationObservation()
        observation.observe(CodexInviteCheckResult.available(eligible: false).healthEvent(at: now.addingTimeInterval(10)))
        XCTAssertNil(observation.lastUpdatedAt)
        XCTAssertEqual(observation.lastInviteEligibilityUpdatedAt, now.addingTimeInterval(10))
        let bridge = CodexHealthEvent(date: now.addingTimeInterval(9.9), kind: .connectionFailure,
                                     scope: "durable", recoveryOrigin: .appServerBridge)
        observation.observe(bridge)
        XCTAssertEqual(observation.pendingBridgeFailure, bridge, "A completed active check must not advance the application-log watermark")
        observation.observe(CodexInviteCheckResult.networkFailure.healthEvent(at: now.addingTimeInterval(9)))
        XCTAssertNil(observation.inviteEligibilityFailure, "An older buffered invite failure cannot undo a newer active success")
        let inviteFailure = CodexInviteCheckResult.networkFailure.healthEvent(at: now.addingTimeInterval(12))
        observation.observe(inviteFailure)
        observation.observe(.init(date: now.addingTimeInterval(11), kind: .responseProgress, recoveryOrigin: .businessResponse))
        XCTAssertEqual(observation.inviteEligibilityFailure, inviteFailure, "An older conversation response cannot clear a newer feature failure")
        observation.observe(.init(date: now.addingTimeInterval(13), kind: .responseCompleted, recoveryOrigin: .businessResponse))
        XCTAssertEqual(observation.inviteEligibilityFailure, inviteFailure, "A conversation response does not prove the invitation feature recovered")
        observation.observe(CodexInviteCheckResult.accessDenied.healthEvent(at: now.addingTimeInterval(14)))
        XCTAssertNil(observation.inviteEligibilityFailure, "An explicit feature-level HTTP result ends its previous network failure")
    }

    @MainActor
    func testActiveInviteResultsClearOnlyInviteErrorsAndNeverFabricateConversationEvidence() throws {
        let now = Date()
        var observation = CodexApplicationObservation()
        let bridge = CodexHealthEvent(date: now, kind: .reconnecting, scope: "durable", recoveryOrigin: .appServerBridge)
        observation.observe(bridge)
        observation.observe(CodexInviteCheckResult.networkFailure.healthEvent(at: now.addingTimeInterval(1)))
        XCTAssertNotNil(observation.inviteEligibilityFailure)
        observation.observe(CodexInviteCheckResult.available(eligible: false).healthEvent(at: now.addingTimeInterval(2)))
        XCTAssertNil(observation.inviteEligibilityFailure)
        XCTAssertEqual(observation.pendingBridgeFailure, bridge)
        XCTAssertNil(observation.lastResponseAt)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-invite-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkHealthStore(fileURL: directory.appendingPathComponent("history.json"))
        let results: [CodexInviteCheckResult] = [.available(eligible: true), .available(eligible: false), .networkFailure,
            .authenticationRequired, .accessDenied, .rateLimited, .serviceFailure, .invalidResponse, .unavailable]
        for (index, result) in results.enumerated() {
            let event = result.healthEvent(at: now.addingTimeInterval(Double(index)))
            XCTAssertEqual(event.workspaceFeature, .inviteEligibility)
            XCTAssertEqual(event.recoveryOrigin, .request)
            XCTAssertFalse(event.isBusinessSuccess)
            XCTAssertFalse(event.isNetworkFailure)
            store.record(event: event, nodeKey: "fixture-node", context: "fixture-network", now: now.addingTimeInterval(10))
        }
        let snapshot = store.snapshot(nodeKey: "fixture-node", context: "fixture-network", now: now.addingTimeInterval(10))
        XCTAssertNil(snapshot.lastSuccessAt)
        XCTAssertEqual(snapshot.verifiedRequestCount, 0)
        XCTAssertEqual(snapshot.responseFragmentCount, 0)
        XCTAssertNil(snapshot.score)
    }

    func testEligibilityFalseIsASuccessfulCheckAndOnlyNetworkErrorsRequestRecovery() {
        for eligible in [true, false] {
            let result = CodexInviteEligibilityProbe.classify(statusCode: 200, data: Data("{\"should_show\":\(eligible)}".utf8))
            XCTAssertEqual(result, .available(eligible: eligible))
            XCTAssertTrue(result.isAvailable)
            XCTAssertEqual(result.recoveryFailure, false)
        }
        XCTAssertEqual(CodexInviteCheckResult.networkFailure.recoveryFailure, true)
        for result: CodexInviteCheckResult in [.authenticationRequired, .accessDenied, .rateLimited, .serviceFailure, .invalidResponse, .unavailable] {
            XCTAssertFalse(result.isAvailable)
            XCTAssertNil(result.recoveryFailure)
        }
        XCTAssertFalse(CodexInviteCheckResult.networkFailure.userFacingSummary.contains("CFNetwork"))
        XCTAssertFalse(CodexInviteCheckResult.networkFailure.userFacingSummary.contains("Error Domain"))
        XCTAssertTrue(CodexInviteCheckResult.networkFailure.userFacingSummary.contains("超时")
            || CodexInviteCheckResult.networkFailure.userFacingSummary.contains("节点"))
    }

    func testTransportErrorsMapToFriendlyNetworkFailureWithoutRawCFNetworkText() {
        let proxyFailure = NSError(domain: kCFErrorDomainCFNetwork as String, code: 310, userInfo: [
            NSLocalizedDescriptionKey: "Task finished with error [310] Error Domain=kCFErrorDomainCFNetwork"
        ])
        XCTAssertEqual(CodexInviteEligibilityProbe.classifyTransportError(proxyFailure), .networkFailure)
        XCTAssertEqual(
            CodexInviteEligibilityProbe.classifyTransportError(URLError(.secureConnectionFailed)),
            .networkFailure
        )
        XCTAssertEqual(
            CodexInviteEligibilityProbe.classifyTransportError(URLError(.timedOut)),
            .networkFailure
        )
        XCTAssertEqual(
            CodexInviteEligibilityProbe.classifyTransportError(URLError(.userAuthenticationRequired)),
            .authenticationRequired
        )
        XCTAssertEqual(CodexInviteEligibilityProbe.classifyCurlFailure(status: 28, timedOut: false), .networkFailure)
        XCTAssertEqual(CodexInviteEligibilityProbe.classifyCurlFailure(status: 0, timedOut: true), .networkFailure)
        XCTAssertEqual(
            CodexInviteEligibilityProbe.parseEligibilityCurlOutput(Data("{\"should_show\":true}\nHOPWORLD_RESULT 200".utf8)),
            .available(eligible: true)
        )
        XCTAssertEqual(
            CodexInviteEligibilityProbe.parseEligibilityCurlOutput(Data("\nHOPWORLD_RESULT 401".utf8)),
            .authenticationRequired
        )
        XCTAssertEqual(
            CodexInviteEligibilityProbe.parseEligibilityCurlOutput(Data("not-json\nHOPWORLD_RESULT 200".utf8)),
            .invalidResponse
        )
    }

    func testHTTPFailuresRedirectsAndMalformedBodiesCannotPassAsEligibilitySuccess() {
        for (status, expected): (Int, CodexInviteCheckResult) in [(401, .authenticationRequired), (403, .accessDenied),
            (429, .rateLimited), (500, .serviceFailure), (503, .serviceFailure), (400, .invalidResponse),
            (302, .invalidResponse), (204, .invalidResponse)] {
            XCTAssertEqual(CodexInviteEligibilityProbe.classify(statusCode: status, data: Data("{\"should_show\":true}".utf8)), expected)
        }
        for body in ["{}", "{\"should_show\":\"true\"}", "{\"should_show\":1}", "<html>Sign in</html>"] {
            XCTAssertEqual(CodexInviteEligibilityProbe.classify(statusCode: 200, data: Data(body.utf8)), .invalidResponse)
        }
        let oversized = Data(("{\"should_show\":true}" + String(repeating: " ", count: 64 * 1024)).utf8)
        XCTAssertEqual(CodexInviteEligibilityProbe.classify(statusCode: 200, data: oversized), .invalidResponse)
    }

    func testRequestUsesFixedOfficialEndpointAndAnEphemeralExplicitProxy() {
        let credential = CodexInviteEligibilityProbe.Credential(token: "fixture-token", accountID: "fixture-account", programID: "codex_referral_consumer")
        let request = CodexInviteEligibilityProbe.request(credential: credential, timeout: 3)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.url?.path, "/backend-api/referrals/invite/eligibility")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "program_id" }?.value, "codex_referral_consumer")
        XCTAssertEqual(query?.first { $0.name == "entrypoint" }?.value, "persistent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture-account")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
        let configuration = CodexInviteEligibilityProbe.configuration(httpProxyPort: 19023, timeout: 3)
        let proxy = configuration.connectionProxyDictionary
        XCTAssertEqual(proxy?["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy?["HTTPSPort"] as? Int, 19023)
        XCTAssertEqual(proxy?["HTTPSEnable"] as? Int, 1)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testStatusOneFollowsMenuEligibilityLoadPathNotMenuAX() {
        let now = Date()
        XCTAssertEqual(CodexStatusOne.verdict(probe: nil, menuLoadFailure: nil), .unchecked,
                       "Unconfirmed must show 未检测, not 正常")
        XCTAssertFalse(CodexStatusOne.isAbnormal(probe: nil, menuLoadFailure: nil))
        XCTAssertEqual(CodexStatusOne.verdict(probe: .available(eligible: true), menuLoadFailure: nil), .normal,
                       "Eligibility probe success is 正常; menu AX is not consulted")
        XCTAssertEqual(CodexStatusOne.verdict(probe: nil, menuLoadFailure: nil, isChecking: true), .checking)
        XCTAssertEqual(CodexStatusOne.verdict(probe: .available(eligible: true), menuLoadFailure: nil, isChecking: true), .normal,
                       "A later probe must not demote confirmed 正常 back to 检测中")
        XCTAssertEqual(CodexVisibleStatus.inviteCheck.title(verdict: .checking), "状态 1 检测中")
        XCTAssertEqual(CodexStatusOne.verdict(probe: .available(eligible: false), menuLoadFailure: nil), .abnormal)
        XCTAssertEqual(CodexStatusOne.verdict(probe: .networkFailure, menuLoadFailure: nil), .abnormal)
        let menuLoadFailure = CodexHealthEvent(
            date: now.addingTimeInterval(-30), kind: .requestFailure, scope: "public",
            recoveryOrigin: .request, workspaceFeature: .inviteEligibility)
        XCTAssertEqual(
            CodexStatusOne.verdict(probe: .available(eligible: true), menuLoadFailure: menuLoadFailure),
            .abnormal,
            "Codex’s own eligibility load failure keeps 状态 1 异常 even after probe success")
        let unrelated = CodexHealthEvent(
            date: now.addingTimeInterval(1), kind: .requestFailure, scope: "public",
            recoveryOrigin: .request, workspaceFeature: .settings)
        XCTAssertEqual(
            CodexStatusOne.verdict(probe: .available(eligible: true), menuLoadFailure: unrelated),
            .normal,
            "Workspace settings failures are status 2, not status 1")
        XCTAssertEqual(CodexVisibleStatus.inviteCheck.title(verdict: .unchecked), "状态 1 未检测")
    }

    func testBufferedCodexFailureOlderThanProbeSuccessStillMarksStatusOneAbnormal() {
        let now = Date()
        var observation = CodexApplicationObservation()
        observation.observe(CodexInviteCheckResult.available(eligible: true).healthEvent(at: now.addingTimeInterval(10)))
        let buffered = CodexHealthEvent(
            date: now.addingTimeInterval(8), kind: .requestFailure, scope: "public", observationID: "codex-req-1",
            recoveryOrigin: .request, workspaceFeature: .inviteEligibility)
        observation.observe(buffered)
        XCTAssertEqual(observation.inviteEligibilityFailure, buffered,
                       "Codex logs arrive late; a newer probe success must not drop Codex's own load failure")
        XCTAssertEqual(CodexStatusOne.verdict(probe: .available(eligible: true), menuLoadFailure: observation.inviteEligibilityFailure),
                       .abnormal)
    }

    func testCodexCachedEligibilitySuccessClearsOnlyOlderCodexFailure() throws {
        let headers = "HTTP/1.1 200\u{0}date:Fri, 30 Oct 2026 16:21:01 GMT\u{0}"
        let success = try XCTUnwrap(CodexInviteCache.successDate(in: Data(headers.utf8)))
        XCTAssertNil(CodexInviteCache.successDate(in: Data(headers.replacingOccurrences(of: " 200", with: " 500").utf8)))
        var observation = CodexApplicationObservation()
        let failure = CodexHealthEvent(date: success.addingTimeInterval(-60), kind: .requestFailure, scope: "unknown",
                                       recoveryOrigin: .request, workspaceFeature: .inviteEligibility)
        observation.observe(failure)
        let cached = CodexHealthEvent(date: success, kind: .workspaceRecovered, observationID: CodexInviteCache.observationID,
                                      recoveryOrigin: .request, workspaceFeature: .inviteEligibility)
        observation.observe(cached)
        XCTAssertNil(observation.inviteEligibilityFailure, "Codex reloading eligibility with HTTP 200 ends its grey-menu failure")
        let later = CodexHealthEvent(date: success.addingTimeInterval(30), kind: .requestFailure, scope: "unknown",
                                     recoveryOrigin: .request, workspaceFeature: .inviteEligibility)
        observation.observe(later)
        XCTAssertEqual(observation.inviteEligibilityFailure, later)
    }

    func testProbeSuccessCannotClearCodexMenuLoadFailure() {
        let now = Date()
        var observation = CodexApplicationObservation()
        let codexFailure = CodexHealthEvent(
            date: now, kind: .requestFailure, scope: "public", observationID: "codex-req-1",
            recoveryOrigin: .request, workspaceFeature: .inviteEligibility)
        observation.observe(codexFailure)
        XCTAssertEqual(observation.inviteEligibilityFailure, codexFailure)
        observation.observe(CodexInviteCheckResult.available(eligible: true).healthEvent(at: now.addingTimeInterval(10)))
        XCTAssertEqual(observation.inviteEligibilityFailure, codexFailure,
                       "Directional probe success must not claim the grey invite menu recovered")
        observation.observe(CodexInviteCheckResult.networkFailure.healthEvent(at: now.addingTimeInterval(20)))
        XCTAssertEqual(observation.inviteEligibilityFailure, codexFailure,
                       "A probe transport blip must not replace Codex's unresolved menu-load failure")
        observation.observe(.init(date: now.addingTimeInterval(30), kind: .workspaceRecovered,
                                  workspaceFeature: .inviteMenu))
        XCTAssertNil(observation.inviteEligibilityFailure,
                     "Invite menu becoming enabled clears Codex's menu-load failure")

        observation.observe(CodexInviteCheckResult.networkFailure.healthEvent(at: now.addingTimeInterval(40)))
        XCTAssertEqual(observation.inviteEligibilityFailure?.observationID, CodexInviteCheckResult.probeObservationID)
        observation.observe(CodexInviteCheckResult.available(eligible: true).healthEvent(at: now.addingTimeInterval(50)))
        XCTAssertNil(observation.inviteEligibilityFailure,
                     "A later probe success may clear the probe's own network failure")
    }

    func testRedirectNeverForwardsAuthenticationToAnotherHost() {
        let delegate = CodexInviteEligibilityProbe.RedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://chatgpt.com/backend-api/referrals/invite/eligibility")!
        let redirected = URLRequest(url: URL(string: "https://untrusted.example/")!)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirected.url!.absoluteString])!
        var called = false
        delegate.urlSession(session, task: session.dataTask(with: original), willPerformHTTPRedirection: response,
                            newRequest: redirected) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }

    func testCredentialRPCUsesLocalAppServerWithoutPuttingTokenInArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-invite-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let arguments = directory.appendingPathComponent("arguments.txt")
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "fixture-account", "chatgpt_plan_type": "plus"]])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "fixture." + encoded + ".signature"
        let result = String(decoding: try JSONSerialization.data(withJSONObject: ["id": 2, "result": ["authMethod": "chatgpt", "authToken": token]]), as: UTF8.self)
        let quotedArguments = "'" + arguments.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(quotedArguments)
        IFS= read -r line || exit 1
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line || exit 1
        IFS= read -r line || exit 1
        case "$line" in
          *getAuthStatus*includeToken*|*includeToken*getAuthStatus*) ;;
          *) exit 2 ;;
        esac
        printf '%s\\n' '\(result)'
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        guard case .credential(let credential) = CodexInviteEligibilityProbe.readCredential(executablePath: executable.path, timeout: 2) else {
            return XCTFail("The fake local app-server handshake failed")
        }
        XCTAssertEqual(credential.token, token)
        XCTAssertEqual(credential.accountID, "fixture-account")
        XCTAssertEqual(credential.programID, "codex_referral_consumer")
        let recordedArguments = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertEqual(recordedArguments, "app-server\n--listen\nstdio://\n")
        XCTAssertFalse(recordedArguments.contains(token))
    }

    func testUnsupportedOrMissingLoginCannotSupplyAProbeCredential() {
        for result: [String: Any] in [[:], ["authMethod": "apikey", "authToken": "fixture-api-key"], ["authMethod": "chatgpt", "authToken": ""]] {
            guard case .failed(.authenticationRequired) = CodexInviteEligibilityProbe.credential(from: result) else {
                XCTFail("A ChatGPT login is required"); continue
            }
        }
        guard case .failed(.unavailable) = CodexInviteEligibilityProbe.credential(from: ["authMethod": "chatgpt", "authToken": "unsafe\nvalue"]) else {
            return XCTFail("Credential header injection was not rejected")
        }
    }

    func testFreshRepeatedInviteFailuresRemainDiagnosticAndOtherResultsResetTheEpisode() {
        let now = Date()
        var observation = CodexInviteCheckObservation()
        XCTAssertNil(observation.result)
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(3600)))
        for offset: TimeInterval in [0, 10, 20, 30] {
            observation.record(result: .networkFailure, at: now.addingTimeInterval(offset))
        }
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(30)))
        observation.record(result: .accessDenied, at: now.addingTimeInterval(31))
        XCTAssertNil(observation.network.reachable)
        XCTAssertFalse(observation.needsRecovery(now: now.addingTimeInterval(31)))
        observation.record(result: .available(eligible: false), at: now.addingTimeInterval(32))
        XCTAssertEqual(observation.network.reachable, true)
        XCTAssertTrue(observation.result!.isAvailable)
        observation.record(result: .networkFailure, at: now.addingTimeInterval(30))
        XCTAssertEqual(observation.result, .available(eligible: false), "A previous connection's late result must not overwrite the current check")
    }
}
