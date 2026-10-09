import XCTest

final class CaptureStatusPresentationTests: XCTestCase {
    func testDisconnectedDoesNotClaimSavedApplicationModeIsEffective() {
        XCTAssertEqual(CaptureStatusPresentation.text(status: .disconnected, activeMode: .applications, cleanupPending: false),
                       "未连接（跃界未接管）")
    }

    func testOnlySuccessfulRuntimeSessionDisplaysEffectiveMode() {
        for mode in ConnectionCaptureMode.allCases {
            XCTAssertEqual(CaptureStatusPresentation.text(status: .connected, activeMode: mode, cleanupPending: false),
                           "\(mode.displayName)（已生效）")
        }
    }

    func testConnectingAndAuthorizationFailureNeverClaimSuccess() {
        XCTAssertEqual(CaptureStatusPresentation.text(status: .connecting, activeMode: .systemProxy, cleanupPending: false),
                       "连接中，新模式尚未确认生效")
        XCTAssertEqual(CaptureStatusPresentation.text(status: .error, activeMode: .applications, cleanupPending: false),
                       "连接异常，未确认接管生效")
    }

    func testRestoredConnectedFlagWithoutRuntimeSessionIsNotProof() {
        XCTAssertEqual(CaptureStatusPresentation.text(status: .connected, activeMode: nil, cleanupPending: false),
                       "接管状态未确认，请重新连接")
    }

    func testCleanupFailureOverridesEvenDisconnectedOrConnectedFlags() {
        for status in [ConnectionStatus.disconnected, .connecting, .connected, .disconnecting, .error] {
            XCTAssertEqual(CaptureStatusPresentation.text(status: status, activeMode: .applications, cleanupPending: true),
                           "停止尚未确认，请重试断开")
        }
        XCTAssertEqual(CaptureStatusPresentation.text(status: .disconnecting, activeMode: .applications, cleanupPending: false),
                       "正在停止接管…")
    }
}
