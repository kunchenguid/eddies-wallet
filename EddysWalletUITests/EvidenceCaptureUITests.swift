import XCTest

/// Walks the key kid and parent surfaces end to end with assertions, and -
/// when `TEST_RUNNER_EW_EVIDENCE_DIR` points at a writable directory - saves
/// a labeled screenshot of every stop. This keeps review evidence
/// reproducible from clean simulators with synthetic fixture data instead of
/// hand-assembled captures.
///
/// `TEST_RUNNER_`-prefixed variables only reach this process when exported
/// in the calling shell before `xcodebuild test` runs, e.g.
/// `export TEST_RUNNER_EW_EVIDENCE_DIR=/path && xcodebuild test ...`.
/// Passing `TEST_RUNNER_EW_EVIDENCE_DIR=/path` as a trailing xcodebuild
/// argument is silently treated as a build-setting override instead and
/// never reaches `ProcessInfo.processInfo.environment` here.
final class EvidenceCaptureUITests: XCTestCase {
    private let doorLabel = "Parent area. Asks for the parent PIN."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var evidenceDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["EW_EVIDENCE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func launch(_ scenario: String, environment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EW_UITEST_SCENARIO"] = scenario
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        guard let evidenceDirectory else { return }
        let screenshot = XCUIScreen.main.screenshot()
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let url = evidenceDirectory.appendingPathComponent("\(name)-\(idiom).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    private func captureBrandPlacement(_ name: String) throws {
        guard let evidenceDirectory else { return }
        let screenshot = XCUIScreen.main.screenshot()
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let url = evidenceDirectory.appendingPathComponent("\(idiom)-\(name).png")
        try screenshot.pngRepresentation.write(to: url, options: .atomic)
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            app.buttons["PIN digit \(digit)"].tap()
        }
    }

    private func unlockParentArea(_ app: XCUIApplication) {
        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
    }

    func testFirstRunSetupTour() throws {
        let app = launch("first-run")

        let signIn = app.buttons["Set up your child's wallet"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()

        let nicknameField = app.textFields["Child's nickname"]
        XCTAssertTrue(nicknameField.waitForExistence(timeout: 10))
        capture("setup-family")
        nicknameField.tap()
        nicknameField.typeText("Eddie")

        let pinField = app.secureTextFields["Four digits"]
        pinField.tap()
        pinField.typeText("1234")
        let confirmField = app.secureTextFields["Confirm PIN"]
        confirmField.tap()
        confirmField.typeText("1234")

        app.buttons["Keep it on this device for free"].tap()
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 5))
        capture("setup-parent-handoff")

        app.buttons["Show Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your wallet is ready!"].exists)
        capture("setup-kid-home")
    }

    func testFreemiumEntryAndCloudGuardTour() throws {
        var app = launch("first-run")
        XCTAssertTrue(app.staticTexts["Set up a complete practice wallet on this iPhone or iPad for free. Cloud is optional."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Virtual practice only"].exists)
        XCTAssertTrue(app.staticTexts["Parent sign-in only. Your child does not need an account."].exists)
        capture("freemium-welcome")

        app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        let cloudCard = app.descendants(matching: .any)["cloud-backup-sync-card"]
        for _ in 0..<4 where !cloudCard.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(cloudCard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud plans are unavailable right now. Your wallet still works on this device."].exists)
        XCTAssertTrue(app.staticTexts["Cloud is optional. Your wallet keeps working on this device without it."].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "subscribe")).firstMatch.exists)
        capture("cloud-guarded-unavailable")

        app = launch("cloud-expired")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        let expiredCloudCard = app.descendants(matching: .any)["cloud-backup-sync-card"]
        for _ in 0..<4 where !expiredCloudCard.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(expiredCloudCard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud ended. This wallet now works on this device only. Nothing was deleted."].exists)
        capture("cloud-expired-local-fallback")
    }

    func testKidSurfacesTour() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        capture("kid-home")

        app.staticTexts["Comic book"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Activity detail"].waitForExistence(timeout: 5))
        capture("kid-activity-detail")
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        app.staticTexts["A little at a time is okay"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loan details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Record repayment"].exists, "The kid loan detail is read-only")
        capture("kid-loan-detail")
        app.buttons["Done"].tap()
    }

    func testKidStateVariantsTour() throws {
        var app = launch("configured-empty")
        XCTAssertTrue(app.staticTexts["Your wallet is ready!"].waitForExistence(timeout: 10))
        capture("kid-empty")

        app = launch("offline")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        let offlineBanner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You're offline")).firstMatch
        XCTAssertTrue(offlineBanner.waitForExistence(timeout: 5))
        capture("kid-offline")

        app = launch("expired")
        XCTAssertTrue(app.staticTexts["A parent needs to sign in again."].waitForExistence(timeout: 10))
        capture("kid-session-expired")

        app = launch("configured", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        capture("kid-home-ax-large")
    }

    func testGateTour() throws {
        let app = launch("configured", environment: ["EW_UITEST_FAST_COOLDOWN": "1"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
        capture("gate")

        enterPIN("1111", in: app)
        XCTAssertTrue(app.staticTexts["Incorrect PIN. Try again."].waitForExistence(timeout: 3))
        capture("gate-error")

        for _ in 0..<4 {
            enterPIN("1111", in: app)
        }
        let cooldown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Too many tries.")).firstMatch
        XCTAssertTrue(cooldown.waitForExistence(timeout: 3))
        capture("gate-cooldown")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    // The keypad's hit targets and digit labels must stay on screen and
    // tappable at the largest supported accessibility text size, not just
    // the default Dynamic Type size.
    func testGateAccessibilityLargeTextTour() throws {
        let app = launch("configured", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
        capture("gate-ax-xxxl")

        for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
            let button = app.buttons["PIN digit \(digit)"]
            XCTAssertTrue(button.exists, "PIN digit \(digit) must stay reachable at the largest accessibility text size")
            XCTAssertTrue(button.isHittable, "PIN digit \(digit) must stay tappable at the largest accessibility text size")
        }
        XCTAssertTrue(app.buttons["Delete last PIN digit"].isHittable)

        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
    }

    func testRecoveryTour() throws {
        let app = launch("no-pin")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Reset the parent PIN"].waitForExistence(timeout: 5))
        capture("gate-recovery")

        app.buttons["Sign in with Apple"].tap()
        XCTAssertTrue(app.secureTextFields["New parent PIN"].waitForExistence(timeout: 5))
        capture("gate-set-pin")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    func testParentAreaTour() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        capture("parent-area")

        app.swipeUp()
        XCTAssertTrue(app.buttons["Change PIN"].waitForExistence(timeout: 5))
        capture("parent-area-scrolled")

        // Deposit flow: amount -> review -> Recorded, exact minor units.
        app.buttons["Add deposit"].tap()
        let amountField = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("5.25")
        capture("parent-deposit-amount")
        app.buttons["Review"].tap()
        if !app.staticTexts["Review before recording"].waitForExistence(timeout: 3) {
            // The first tap can land during the keyboard animation on iPad.
            app.buttons["Review"].tap()
        }
        XCTAssertTrue(app.staticTexts["Review before recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["US$29.25"].exists, "Review must show the exact resulting accepted balance")
        capture("parent-deposit-review")
        app.buttons["Confirm add deposit"].tap()
        XCTAssertTrue(app.staticTexts["Recorded"].waitForExistence(timeout: 5))
        capture("parent-deposit-result")
        app.buttons["Done"].tap()

        // Overdraft honesty: a too-large withdrawal is blocked with the
        // fixed vocabulary before it can be submitted.
        app.buttons["Record withdrawal"].tap()
        let withdrawalField = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(withdrawalField.waitForExistence(timeout: 5))
        withdrawalField.tap()
        withdrawalField.typeText("500")
        XCTAssertTrue(app.staticTexts["The amount is greater than the accepted balance."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Review"].isEnabled)
        capture("parent-withdrawal-blocked")
        app.buttons["Cancel"].tap()

        // Allowance sheet with review sentence.
        XCTAssertTrue(app.staticTexts["Next allowance"].waitForExistence(timeout: 5))
        app.staticTexts["Next allowance"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Review allowance"].waitForExistence(timeout: 5))
        capture("parent-allowance")
        app.buttons["Close"].tap()

        // Change PIN sheet.
        app.swipeUp()
        XCTAssertTrue(app.buttons["Change PIN"].waitForExistence(timeout: 5))
        app.buttons["Change PIN"].tap()
        XCTAssertTrue(app.secureTextFields["Current PIN"].waitForExistence(timeout: 5))
        capture("parent-change-pin")
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
        app.buttons["Done. Back to Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    func testChildNicknameEditorTour() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)

        let settingsRow = app.descendants(matching: .any)["edit-child-profile-settings"]
        for _ in 0..<4 where !settingsRow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()

        let field = app.descendants(matching: .any)["child-nickname-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        capture("parent-child-profile-editor")

        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        let save = app.buttons["Save child profile"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled, "A blank nickname must not be saved")
        capture("parent-child-profile-blank-validation")

        field.typeText("Maya")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Child profile saved."].waitForExistence(timeout: 5))
        capture("parent-child-profile-saved")
        app.navigationBars.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Maya's virtual balance"].waitForExistence(timeout: 5))
        capture("parent-area-renamed-child")

        app.buttons["Done. Back to Maya's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Maya"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Maya's Wallet"].exists)
        capture("kid-home-renamed")
    }

    func testBrandPlacementTour() throws {
        let maya = launch("configured", environment: ["EW_UITEST_NICKNAME": "Maya"])
        XCTAssertTrue(maya.staticTexts["Maya's Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(maya.staticTexts["Hi, Maya"].exists)
        XCTAssertTrue(maya.staticTexts["Your allowance balance"].exists)
        XCTAssertFalse(maya.staticTexts["Pretend dollars for practice - not real money."].exists)
        XCTAssertFalse(maya.staticTexts["Eddie's Wallet"].exists)
        try captureBrandPlacement("maya-kid")

        unlockParentArea(maya)
        XCTAssertTrue(maya.staticTexts["Maya's virtual balance"].waitForExistence(timeout: 5))
        XCTAssertTrue(maya.buttons["Done. Back to Maya's wallet"].exists)
        XCTAssertFalse(maya.staticTexts["Eddie's Wallet"].exists)
        try captureBrandPlacement("maya-parent")

        let mayaEmpty = launch("configured-empty", environment: ["EW_UITEST_NICKNAME": "Maya"])
        XCTAssertTrue(mayaEmpty.staticTexts["Maya's Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(mayaEmpty.staticTexts["Your wallet is ready!"].exists)
        try captureBrandPlacement("maya-empty")

        let neutral = launch("configured", environment: ["EW_UITEST_NICKNAME": ""])
        XCTAssertTrue(neutral.staticTexts["Your wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(neutral.staticTexts["Your allowance balance"].exists)
        XCTAssertFalse(neutral.staticTexts["Pretend dollars for practice - not real money."].exists)
        XCTAssertFalse(neutral.staticTexts["Eddie's Wallet"].exists)
        try captureBrandPlacement("neutral-kid")

        let eddie = launch("configured")
        XCTAssertTrue(eddie.staticTexts["Eddie's Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(eddie.staticTexts["Hi, Eddie"].exists)
        XCTAssertTrue(eddie.staticTexts["Your allowance balance"].exists)
        try captureBrandPlacement("eddie-personal-kid")

        // Deterministic pre-setup state; never inherited simulator history.
        let welcome = launch("first-run")
        XCTAssertTrue(welcome.descendants(matching: .any)["product-brand-wordmark"].waitForExistence(timeout: 10))
        XCTAssertTrue(welcome.staticTexts["Eddie's Wallet"].exists)
        XCTAssertTrue(welcome.staticTexts["Virtual practice only"].exists)
        try captureBrandPlacement("welcome")
    }

    func testParentEmptyHandoffTour() throws {
        let app = launch("configured-empty")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 5), "An empty wallet shows the first-actions spotlight")
        capture("parent-area-empty-handoff")
        app.buttons["Show Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }
}
