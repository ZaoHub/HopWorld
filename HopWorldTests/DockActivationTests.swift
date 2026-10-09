import XCTest

final class DockActivationTests: XCTestCase {
    func testIgnoresStatusItemAndRaisesMainWindowLast() {
        let windows = [
            traits(title: "", isKey: true, isStatusBarWindow: true, area: 100),
            traits(title: "跃界", isVisible: true, isMain: true, area: 1100 * 720),
            traits(title: "设置", isPanel: true, isVisible: true, area: 520 * 480),
        ]

        let plan = DockActivationPolicy.plan(for: windows)

        XCTAssertEqual(plan.orderFront, [1])
        XCTAssertTrue(plan.deminiaturize.isEmpty)
    }

    func testKeyVisibleWindowIsStillRaised() {
        let windows = [
            traits(title: "跃界", isVisible: true, isKey: true, isMain: true, area: 800_000),
        ]

        XCTAssertEqual(DockActivationPolicy.plan(for: windows).orderFront, [0])
    }

    func testKeyWindowStaysKeyWhenSeveralWindowsAreVisible() {
        let windows = [
            traits(title: "跃界", isVisible: true, isMain: true, area: 800_000),
            traits(title: "设置", isVisible: true, isKey: true, area: 200_000),
        ]

        XCTAssertEqual(DockActivationPolicy.plan(for: windows).orderFront, [0, 1])
    }

    func testVisibleWindowDoesNotRestoreAMiniaturizedSibling() {
        let windows = [
            traits(title: "跃界", isVisible: true, area: 800_000),
            traits(title: "设置", isMiniaturized: true, area: 200_000),
        ]

        let plan = DockActivationPolicy.plan(for: windows)

        XCTAssertEqual(plan.orderFront, [0])
        XCTAssertTrue(plan.deminiaturize.isEmpty)
    }

    func testOnlyMiniaturizedWindowIsRestored() {
        let windows = [
            traits(title: "", isStatusBarWindow: true),
            traits(title: "跃界", isMiniaturized: true, area: 800_000),
        ]

        let plan = DockActivationPolicy.plan(for: windows)

        XCTAssertEqual(plan.orderFront, [1])
        XCTAssertEqual(plan.deminiaturize, [1])
    }

    func testNoForegroundWindowMeansTheMainWindowMustBeReopened() {
        let windows = [
            traits(title: "", isKey: true, isStatusBarWindow: true),
            traits(title: "", area: 0),
        ]

        let plan = DockActivationPolicy.plan(for: windows)

        XCTAssertTrue(plan.orderFront.isEmpty)
        XCTAssertTrue(plan.deminiaturize.isEmpty)
    }

    private func traits(
        title: String,
        isPanel: Bool = false,
        isVisible: Bool = false,
        isMiniaturized: Bool = false,
        isKey: Bool = false,
        isMain: Bool = false,
        isStatusBarWindow: Bool = false,
        area: Double = 0
    ) -> DockWindowTraits {
        DockWindowTraits(
            isPanel: isPanel,
            isNormalLevel: true,
            hasTitlebar: !isStatusBarWindow,
            isStatusBarWindow: isStatusBarWindow,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isKey: isKey,
            isMain: isMain,
            title: title,
            area: area
        )
    }
}
