import XCTest

final class CodexInterfaceHealthReaderTests: XCTestCase {
    private typealias Node = CodexInterfaceHealthReader.Node

    func testInvitationUsesCurrentNativeEnabledValue() {
        let snapshot = CodexInterfaceHealthReader.classify([
            Node(role: "AXMenuItem", label: "邀请好友", enabled: false),
            Node(role: "AXStaticText", label: "Invite a friend", enabled: true)
        ])
        XCTAssertEqual(snapshot.inviteEnabled, false)
        XCTAssertTrue(snapshot.readable)
        XCTAssertNil(CodexInterfaceHealthReader.classify([Node(role: "AXGroup")]).inviteEnabled)
        let conflicting = CodexInterfaceHealthReader.classify([
            Node(role: "AXMenuItem", label: "Invite a friend", enabled: true),
            Node(role: "AXMenuItem", label: "Invite a friend", enabled: false)
        ])
        XCTAssertNil(conflicting.inviteEnabled)
    }

    func testWorkspaceWarningRequiresNativeRetryInSameSmallGroup() {
        let warning = Node(role: "AXGroup", children: [
            Node(role: "AXStaticText", label: "无法加载工作空间设置"),
            Node(role: "AXStaticText", label: "请重试以继续聊天"),
            Node(role: "AXButton", label: "重试")
        ])
        XCTAssertEqual(CodexInterfaceHealthReader.classify([warning]).workspaceUnavailable, true)
        let english = Node(role: "AXGroup", children: [
            Node(role: "AXGroup", children: [Node(role: "AXStaticText", label: "Couldn’t load workspace settings")]),
            Node(role: "AXButton", label: "Retry")
        ])
        XCTAssertEqual(CodexInterfaceHealthReader.classify([english]).workspaceUnavailable, true)
        XCTAssertEqual(CodexInterfaceHealthReader.classify([
            Node(role: "AXGroup", children: [Node(role: "AXStaticText", label: "无法加载工作空间设置")]),
            Node(role: "AXGroup", children: [Node(role: "AXButton", label: "重试")])
        ]).workspaceUnavailable, false)
    }

    func testRetryStatusMatchesOnlyExactNativeControls() {
        for label in ["正在重新连接 3/5", "Reconnecting 1/5", "Reconnecting... 5/5", "正在重新连接"] {
            XCTAssertEqual(CodexInterfaceHealthReader.classify([Node(role: "AXButton", label: label)]).reconnecting, true, label)
        }
        for label in ["Reconnecting... waiting for network", "等待网络", "正在重新连接… 等待网络", "Waiting for network"] {
            XCTAssertEqual(CodexInterfaceHealthReader.classify([Node(role: "AXButton", label: label)]).waitingForNetwork, true, label)
        }
        let quote = CodexInterfaceHealthReader.classify([
            Node(role: "AXStaticText", label: "Reconnecting 3/5"),
            Node(role: "AXTextArea", label: "等待网络"),
            Node(role: "AXButton", label: "Explain Reconnecting 3/5"),
            Node(role: "AXGroup", children: [
                Node(role: "AXStaticText", label: "用户引用：无法加载工作空间设置"),
                Node(role: "AXButton", label: "重试")
            ])
        ])
        XCTAssertEqual(quote.reconnecting, false)
        XCTAssertEqual(quote.waitingForNetwork, false)
        XCTAssertEqual(quote.workspaceUnavailable, false)
    }

    func testPartialHiddenAndUnavailableObservationsNeverClearStates() {
        let partial = CodexInterfaceHealthReader.classify([Node(role: "AXGroup")], complete: false)
        XCTAssertNil(partial.workspaceUnavailable)
        XCTAssertNil(partial.reconnecting)
        XCTAssertNil(partial.waitingForNetwork)
        let visibleSignal = CodexInterfaceHealthReader.classify([Node(role: "AXButton", label: "Waiting for network")], complete: false)
        XCTAssertEqual(visibleSignal.waitingForNetwork, true)
        XCTAssertNil(visibleSignal.reconnecting)
        let hidden = CodexInterfaceHealthReader.classify([
            Node(role: "AXGroup", hidden: true, children: [Node(role: "AXButton", label: "Reconnecting 1/5")])
        ], complete: false)
        XCTAssertNil(hidden.reconnecting)
        XCTAssertFalse(CodexInterfaceHealthReader.classify([Node(role: "AXGroup", hidden: true)]).readable)
        XCTAssertFalse(CodexInterfaceHealthReader.classify([]).readable)
        XCTAssertFalse(CodexInterfaceHealthSnapshot(status: .permissionRequired).readable)
    }
}


extension CodexInterfaceHealthReaderTests {
    func testVisibleFaultNeedsFreshConfirmationAndUnknownNeverMeansRecovery() {
        let now = Date()
        var observation = CodexInterfaceObservation()
        let failed = CodexInterfaceHealthSnapshot(workspaceUnavailable: true, status: .observing)
        XCTAssertEqual(observation.observe(failed, at: now).first?.kind, .workspaceFailure)
        XCTAssertEqual(observation.failureSince, now)
        XCTAssertNotNil(observation.pendingFailure(now: now.addingTimeInterval(6)))
        XCTAssertNil(observation.pendingFailure(now: now.addingTimeInterval(6.1)))
        XCTAssertTrue(observation.observe(.init(status: .unavailable), at: now.addingTimeInterval(7)).isEmpty)
        XCTAssertEqual(observation.failureSince, now, "An unreadable window does not prove recovery")
        _ = observation.observe(failed, at: now.addingTimeInterval(8))
        XCTAssertEqual(observation.failureSince, now)
        XCTAssertNotNil(observation.pendingFailure(now: now.addingTimeInterval(8)))
        let clear = CodexInterfaceHealthSnapshot(workspaceUnavailable: false, reconnecting: false, waitingForNetwork: false, status: .observing)
        XCTAssertEqual(observation.observe(clear, at: now.addingTimeInterval(9)).first?.kind, .workspaceRecovered)
        XCTAssertNil(observation.failureSince)
        XCTAssertNil(observation.pendingFailure(now: now.addingTimeInterval(9)))
    }

    func testInviteStateAloneNeverStartsUIRecoveryAndWaitingKeepsEpisodeAcrossRetry() {
        let now = Date()
        var observation = CodexInterfaceObservation()
        let menu = observation.observe(.init(inviteEnabled: false, status: .observing), at: now)
        XCTAssertEqual(menu.first?.workspaceFeature, .inviteMenu)
        XCTAssertEqual(observation.inviteEnabled, false)
        XCTAssertNil(observation.pendingFailure(now: now))
        XCTAssertNil(observation.failureSince)
        // Closing the profile menu leaves inviteEnabled unread; the grey reading must stick.
        XCTAssertTrue(observation.observe(.init(status: .observing), at: now.addingTimeInterval(0.5)).isEmpty)
        XCTAssertEqual(observation.inviteEnabled, false)
        _ = observation.observe(.init(waitingForNetwork: true, status: .observing), at: now.addingTimeInterval(1))
        _ = observation.observe(.init(reconnecting: true, status: .observing), at: now.addingTimeInterval(10))
        XCTAssertEqual(observation.inviteEnabled, false)
        XCTAssertEqual(observation.failureSince, now.addingTimeInterval(1))
        XCTAssertEqual(observation.pendingFailure(now: now.addingTimeInterval(10))?.kind, .reconnecting)
        let cleared = observation.observe(.init(workspaceUnavailable: false, reconnecting: false, waitingForNetwork: false, status: .observing), at: now.addingTimeInterval(11))
        XCTAssertEqual(cleared.first?.kind, .reconnecting)
        XCTAssertEqual(cleared.first?.observationID, "interface-state")
        XCTAssertEqual(cleared.first?.title, "状态 3 正常")
        XCTAssertTrue(cleared.first?.detail.contains("状态 3 正常") == true)
        XCTAssertFalse(cleared.first?.isBusinessSuccess ?? true)
        XCTAssertNil(observation.pendingFailure(now: now.addingTimeInterval(11)))
        XCTAssertEqual(observation.inviteEnabled, false)
        _ = observation.observe(.init(inviteEnabled: true, status: .observing), at: now.addingTimeInterval(12))
        XCTAssertEqual(observation.inviteEnabled, true)
    }
}


extension CodexInterfaceHealthReaderTests {
    @MainActor
    func testConcurrentMenuAndPrimaryWarningsAreAllRetainedAsSeparateRecords() {
        let now = Date()
        var observation = CodexInterfaceObservation()
        let events = observation.observe(.init(inviteEnabled: false, workspaceUnavailable: true,
            reconnecting: true, waitingForNetwork: true, status: .observing), at: now)
        XCTAssertEqual(events.count, 4)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = NetworkHealthStore(fileURL: file)
        for event in events { store.record(event: event, nodeKey: "A", context: "wifi", now: now) }
        XCTAssertEqual(store.records.count, 4, "Distinct features must not be deduplicated at the same time")
        XCTAssertEqual(events.first { $0.workspaceFeature == .inviteMenu }?.title, "界面菜单不可用")
        XCTAssertEqual(events.first { $0.kind == .workspaceFailure && $0.workspaceFeature == .settings }?.title, "状态 2 异常")
        XCTAssertEqual(events.first { $0.kind == .reconnecting }?.title, "状态 3 异常")
        XCTAssertEqual(events.first { $0.kind == .waitingForNetwork }?.title, "状态 4 异常")
        let stillWaiting = observation.observe(.init(workspaceUnavailable: false, reconnecting: false,
            waitingForNetwork: true, status: .observing), at: now.addingTimeInterval(1))
        XCTAssertTrue(stillWaiting.contains { $0.kind == .workspaceRecovered && $0.workspaceFeature == .settings })
        XCTAssertEqual(stillWaiting.first { $0.workspaceFeature == .settings }?.title, "状态 2 正常")
        XCTAssertEqual(observation.pendingFailure(now: now.addingTimeInterval(1))?.kind, .waitingForNetwork)
        XCTAssertEqual(observation.failureSince, now)
    }
}


extension CodexInterfaceHealthReaderTests {
    func testReplyClearsWorkspaceUntilPromptDisappearsAndCanRecur() {
        let now = Date()
        var observation = CodexInterfaceObservation()
        let failed = CodexInterfaceHealthSnapshot(workspaceUnavailable: true, status: .observing)
        _ = observation.observe(failed, at: now)
        XCTAssertEqual(observation.clearWorkspaceAfterResponse(at: now.addingTimeInterval(1))?.kind, .workspaceRecovered)
        XCTAssertNil(observation.pendingFailure(now: now.addingTimeInterval(1)))
        XCTAssertTrue(observation.observe(failed, at: now.addingTimeInterval(2)).isEmpty)
        _ = observation.observe(.init(workspaceUnavailable: false, reconnecting: false, waitingForNetwork: false, status: .observing), at: now.addingTimeInterval(3))
        XCTAssertEqual(observation.observe(failed, at: now.addingTimeInterval(4)).first?.kind, .workspaceFailure)
    }
}
