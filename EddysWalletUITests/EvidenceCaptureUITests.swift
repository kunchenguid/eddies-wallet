import XCTest

/// Walks the key kid and parent surfaces end to end with assertions, and -
/// when `TEST_RUNNER_EW_EVIDENCE_DIR` points at a writable directory - saves
/// a labeled screenshot of every stop. This keeps review evidence
/// reproducible from clean simulators with synthetic fixture data instead of
/// hand-assembled captures.
///
/// `TEST_RUNNER_`-prefixed variables only reach this process when exported
/// in the calling shell before `xcodebuild test` runs. Run it through the
/// simulator lifecycle wrapper so the capture device is always torn down:
/// `export TEST_RUNNER_EW_EVIDENCE_DIR=/path`, then
/// `./test/sim.sh -- xcodebuild test -project EddysWallet.xcodeproj`
/// `-scheme EddysWallet -destination 'platform=iOS Simulator,id={{UDID}}'`.
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
        // Evidence captures need settled end states, not transition frames.
        // Disabling app animations also prevents XCTest from spending its
        // one-minute quiescence fallback on a stuck sheet transition.
        app.launchEnvironment["EW_UITEST_DISABLE_ANIMATIONS"] = "1"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func capture(_ name: String) {
        guard let evidenceDirectory else { return }
        let screenshot = XCUIScreen.main.screenshot()
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let idiom = isPad ? "ipad" : "iphone"
        let url = evidenceDirectory.appendingPathComponent("\(name)-\(idiom).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    private func capture(_ name: String, element: XCUIElement) {
        guard let evidenceDirectory else { return }
        let screenshot = element.screenshot()
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let idiom = isPad ? "ipad" : "iphone"
        let url = evidenceDirectory.appendingPathComponent("\(name)-\(idiom).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    /// On iPad, `isHittable` can be true while the control is still clipped at
    /// the viewport edge, so a full-screen capture misses the content the tour
    /// meant to show. Scroll until the whole frame sits inside the window.
    /// iPhone keeps the existing hittable contract so its captures do not shift.
    @discardableResult
    private func scrollIntoCaptureFrame(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "expected \(element) to exist before scrolling it on screen")
        let window = app.windows.firstMatch
        let edge: CGFloat = isPad ? 32 : 0
        for _ in 0..<12 {
            let visible = window.frame.insetBy(dx: 0, dy: edge)
            let frame = element.frame
            if element.isHittable && (edge == 0 || visible.contains(frame)) {
                return element
            }
            if frame.maxY > visible.maxY {
                app.swipeUp()
            } else if frame.minY < visible.minY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        if isPad {
            XCTAssertTrue(
                window.frame.insetBy(dx: 0, dy: edge).contains(element.frame),
                "iPad capture requires \(element) fully on screen, not merely hittable"
            )
        } else {
            XCTAssertTrue(element.isHittable, "expected \(element) to be hittable")
        }
        return element
    }

    /// iPad's software keyboard covers the form sheet and is captured into
    /// App Store screenshots. Dismiss it only at call sites that have finished
    /// typing - the autofocus evidence capture must keep the keyboard up.
    private func dismissKeyboardForCapture(in app: XCUIApplication) {
        guard isPad, app.keyboards.element.exists else { return }
        XCTAssertTrue(
            resignKeyboard(in: app),
            "iPad money-flow captures must not include the software keyboard"
        )
    }

    @discardableResult
    private func resignKeyboard(in app: XCUIApplication) -> Bool {
        // Tapping non-editable copy in the sheet resigns the amount field
        // without focusing another field or dragging the sheet closed.
        let introPrefixes = [
            "Add pretend dollars",
            "Record virtual dollars",
            "Give ",
            "Pay virtual dollars",
            "Pay out this virtual allowance"
        ]
        for prefix in introPrefixes {
            let intro = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", prefix)
            ).firstMatch
            if intro.exists {
                intro.tap()
                if app.keyboards.element.waitForNonExistence(timeout: 2) { return true }
            }
        }
        let amountLabel = app.staticTexts["Amount"]
        if amountLabel.exists {
            amountLabel.tap()
            if app.keyboards.element.waitForNonExistence(timeout: 2) { return true }
        }
        let hide = app.descendants(matching: .any)["Hide keyboard"]
        if hide.isHittable {
            hide.tap()
            return app.keyboards.element.waitForNonExistence(timeout: 2)
        }
        return false
    }

    private func captureBrandPlacement(_ name: String) throws {
        guard let evidenceDirectory else { return }
        let screenshot = XCUIScreen.main.screenshot()
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let idiom = isPad ? "ipad" : "iphone"
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

    func testConnectionFailurePrivacyAndParentReadout() throws {
        let app = launch("cannot-reach")

        let cannotReach = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Your wallet is hard to reach")
        ).firstMatch
        XCTAssertTrue(cannotReach.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "offline")).count,
            0
        )
        XCTAssertFalse(app.descendants(matching: .any)["connection-details-settings"].exists)
        capture("connection-failure-kid-home")

        unlockParentArea(app)
        let details = app.buttons["connection-details-settings"]
        for _ in 0..<8 where !details.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()

        XCTAssertTrue(app.staticTexts["Connection details"].waitForExistence(timeout: 5))
        let category = app.descendants(matching: .any)["connection-detail-category"]
        XCTAssertTrue(category.label.contains("timedOut"))
        XCTAssertTrue(app.descendants(matching: .any)["connection-detail-code"].label.contains("-1001"))
        XCTAssertTrue(app.descendants(matching: .any)["connection-detail-route"].label.contains("/v1/child-view"))
        XCTAssertTrue(app.buttons["copy-connection-details"].exists)
        capture("connection-failure-parent-details")
    }

    func testCloudPlansLegalLinks() throws {
        let app = launch("cloud-plans-available")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)

        let monthly = app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.monthly"]
        let annual = app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.annual"]
        scrollIntoCaptureFrame(monthly, in: app)
        scrollIntoCaptureFrame(annual, in: app)
        XCTAssertTrue(app.buttons["cloud-restore-button"].exists)
        let offersVisible = app.windows.firstMatch.frame.insetBy(dx: 0, dy: isPad ? 32 : 0)
        XCTAssertTrue(offersVisible.contains(monthly.frame), "monthly plan must be fully on screen for capture")
        XCTAssertTrue(offersVisible.contains(annual.frame), "annual plan must be fully on screen for capture")
        capture("cloud-plans-offers")

        let disclosure = app.staticTexts["cloud-auto-renew-disclosure"]
        scrollIntoCaptureFrame(disclosure, in: app)
        XCTAssertTrue(disclosure.label.localizedCaseInsensitiveContains("renew"))
        XCTAssertTrue(disclosure.label.localizedCaseInsensitiveContains("cancel"))

        let terms = app.descendants(matching: .any)["cloud-terms-link"]
        let privacy = app.descendants(matching: .any)["cloud-privacy-link"]
        scrollIntoCaptureFrame(terms, in: app)
        XCTAssertTrue(terms.isHittable)
        XCTAssertTrue(privacy.isHittable)
        capture("cloud-plans-legal-links")
    }

    /// iPad capture bug 1: `isHittable` can be true while a plan row is still
    /// clipped, so the screenshot misses the offer. After the capture scroll,
    /// both plan rows must sit fully inside the window. This is also the
    /// no-price Cloud plans capture: the same surface, without StoreKit prices.
    func testIPadCaptureKeepsCloudPlansFullyOnScreenWithoutPrices() throws {
        let app = launch("cloud-plans-no-price")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)

        let monthly = app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.monthly"]
        let annual = app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.annual"]
        scrollIntoCaptureFrame(monthly, in: app)
        scrollIntoCaptureFrame(annual, in: app)

        let visible = app.windows.firstMatch.frame.insetBy(dx: 0, dy: isPad ? 32 : 0)
        XCTAssertTrue(visible.contains(monthly.frame), "monthly plan must be fully on screen for capture")
        XCTAssertTrue(visible.contains(annual.frame), "annual plan must be fully on screen for capture")
        XCTAssertTrue(monthly.label.localizedCaseInsensitiveContains("every month"))
        XCTAssertTrue(annual.label.localizedCaseInsensitiveContains("every year"))
        XCTAssertFalse(monthly.label.contains("$"), "no-price plans must not show a StoreKit price")
        XCTAssertFalse(annual.label.contains("$"), "no-price plans must not show a StoreKit price")
        XCTAssertFalse(monthly.label.contains("2.99"))
        XCTAssertFalse(annual.label.contains("24.99"))
        capture("cloud-plans-no-price")
    }

    /// iPad capture bug 2: the software keyboard covers the money-flow sheet.
    /// After the amount is typed, capture dismisses it so Review sits fully
    /// in the window. iPhone captures keep the keyboard, so that branch only
    /// asserts the control remains on screen.
    func testIPadMoneyFlowCaptureDropsTheSoftwareKeyboard() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)

        app.buttons["Add deposit"].tap()
        let amountField = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("5.25")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        dismissKeyboardForCapture(in: app)

        let review = app.buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.windows.firstMatch.frame.contains(review.frame),
            "Review must be fully on screen once capture has settled the keyboard"
        )
        if isPad {
            XCTAssertFalse(app.keyboards.element.exists)
        }
    }

    func testFirstRunSetupTour() throws {
        let app = launch("first-run")

        let signIn = app.buttons["Sign in with Apple"]
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
        XCTAssertTrue(app.staticTexts["Cloud isn't available yet. Everything in the wallet keeps working on this iPhone."].exists)
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
        XCTAssertTrue(app.staticTexts["Cloud ended. You can keep using the wallet on this device. Nothing was deleted."].exists)
        capture("cloud-expired-local-fallback")
    }

    func testPurchaseFailureAttributionTour() throws {
        var app = launch("cloud-purchase-store-error")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        let storeError = app.staticTexts["cloud-purchase-store-error"]
        for _ in 0..<4 where !storeError.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(storeError.waitForExistence(timeout: 5))
        XCTAssertEqual(storeError.label, "The App Store could not finish confirming that purchase. Cloud is still off, and your wallet is unchanged.")
        XCTAssertFalse(app.staticTexts["cloud-purchase-rejected"].exists)
        capture("cloud-purchase-app-store-error", element: app.descendants(matching: .any)["cloud-backup-sync-card"])

        app = launch("cloud-purchase-server-rejected")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        let serverRejected = app.staticTexts["cloud-purchase-rejected"]
        for _ in 0..<4 where !serverRejected.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(serverRejected.waitForExistence(timeout: 5))
        XCTAssertEqual(serverRejected.label, "That plan could not be confirmed, so Cloud is still off. Your wallet is unchanged.")
        XCTAssertFalse(app.staticTexts["cloud-purchase-store-error"].exists)
        capture("cloud-purchase-server-rejected", element: app.descendants(matching: .any)["cloud-backup-sync-card"])
    }

    // Internal-only surface: it has no public entry point, so this tour must
    // open the Debug diagnostics seam explicitly to reach it at all.
    func testCloudRecoveryDetailsTour() throws {
        let app = launch("configured", environment: ["EW_UITEST_DIAGNOSTICS": "1"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)

        let link = app.descendants(matching: .any)["cloud-recovery-details-link"]
        for _ in 0..<10 where !link.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "the local recovery readout is reachable behind the Debug diagnostics seam")
        link.tap()

        XCTAssertTrue(app.staticTexts["Cloud recovery details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Local diagnostics only.")).firstMatch.exists)
        // Scripted states compose no Cloud stack, so the readout says so truthfully.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cloud recovery has not run")).firstMatch.exists)
        // The safe readout never renders anything shaped like a payload or identifier.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "signedTransaction")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "jws")).firstMatch.exists)
        capture("cloud-recovery-details")
    }

    func testStoreKitDiagnosticsTour() throws {
        let app = launch("configured", environment: ["EW_UITEST_DIAGNOSTICS": "1"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)

        let link = app.descendants(matching: .any)["cloud-storekit-diagnostics-link"]
        for _ in 0..<10 where !link.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()

        // Same cold-start exposure as the proof test, and worse: this tour used
        // to read the label with no wait at all, and only ever passed because it
        // runs later and inherits the device's warmed product cache.
        XCTAssertEqual(terminalStoreKitDiagnosticsStatus(in: app), "loaded 2 products")
        XCTAssertEqual(app.staticTexts["storekit-product-com.kunchenguid.eddieswallet.cloud.monthly"].label, "com.kunchenguid.eddieswallet.cloud.monthly")
        XCTAssertEqual(app.staticTexts["storekit-product-com.kunchenguid.eddieswallet.cloud.annual"].label, "com.kunchenguid.eddieswallet.cloud.annual")
        XCTAssertEqual(app.staticTexts["storekit-price-com.kunchenguid.eddieswallet.cloud.monthly"].label, "$2.99")
        XCTAssertEqual(app.staticTexts["storekit-price-com.kunchenguid.eddieswallet.cloud.annual"].label, "$24.99")
        capture("cloud-storekit-diagnostics")
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
        XCTAssertFalse(app.buttons["Pay toward loan"].exists, "The kid loan detail is read-only")
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

        let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        let digitButtons = digits.map { app.buttons["PIN digit \($0)"] }
        let deleteButton = app.buttons["Delete last PIN digit"]
        let keypadButtons = digitButtons + [deleteButton]
        let window = app.windows.firstMatch.frame
        let pinDots = app.descendants(matching: .any)["pin-entry-dots"]
        let forgotPIN = app.buttons["Forgot PIN?"]
        let cancel = app.buttons["Cancel"]

        XCTAssertTrue(pinDots.exists)
        XCTAssertTrue(forgotPIN.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(window.contains(pinDots.frame))
        XCTAssertTrue(window.contains(forgotPIN.frame))
        XCTAssertTrue(window.contains(cancel.frame))

        for (digit, button) in zip(digits, digitButtons) {
            XCTAssertTrue(button.exists, "PIN digit \(digit) must stay reachable at the largest accessibility text size")
            XCTAssertTrue(button.isHittable, "PIN digit \(digit) must stay tappable at the largest accessibility text size")
        }
        XCTAssertTrue(deleteButton.isHittable)

        for button in keypadButtons {
            XCTAssertTrue(window.contains(button.frame), "Every PIN key must remain fully inside the window")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertFalse(button.frame.intersects(pinDots.frame), "PIN keys must not overlap the PIN dots")
            XCTAssertFalse(button.frame.intersects(forgotPIN.frame), "PIN keys must not overlap Forgot PIN")
            XCTAssertFalse(button.frame.intersects(cancel.frame), "PIN keys must not overlap Cancel")
        }

        for firstIndex in keypadButtons.indices {
            for secondIndex in keypadButtons.indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    keypadButtons[firstIndex].frame.intersects(keypadButtons[secondIndex].frame),
                    "PIN keys must not overlap each other"
                )
            }
        }
        XCTAssertFalse(forgotPIN.frame.intersects(cancel.frame))

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

    func testMissedAllowanceParentArea() throws {
        let app = launch("allowance-missed")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        capture("parent-missed-allowance-initial")
        let recordAll = app.buttons["Pay out missed allowance"]
        for _ in 0..<3 where !recordAll.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(recordAll.waitForExistence(timeout: 5))
        XCTAssertTrue(recordAll.isHittable)
        capture("parent-missed-allowance")

        recordAll.tap()
        XCTAssertTrue(app.staticTexts["Pay out 3 missed allowance weeks?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This will add 3 separate allowance entries totaling US$15.00. Today's allowance will not be paid out."].exists)
        let payOutAll = app.buttons["Pay out all"]
        XCTAssertTrue(payOutAll.exists)
        capture("parent-missed-allowance-confirm")

        payOutAll.tap()
        XCTAssertTrue(app.staticTexts["Missed allowances paid out"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paid out 3 separate allowance entries totaling US$15.00."].exists)
        capture("parent-missed-allowance-recorded")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["US$39.00"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["missed-allowance-card"].exists)
        capture("parent-missed-allowance-settled")
    }

    func testMissedLoanPaymentsParentArea() throws {
        let app = launch("loan-installments-missed")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(app)
        capture("parent-loan-payments-initial")

        let payMissed = app.buttons["Pay missed payments"]
        for _ in 0..<3 where !payMissed.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(payMissed.waitForExistence(timeout: 5))
        XCTAssertTrue(payMissed.isHittable)
        // The reminder names the next payment; the list below it is only what
        // is already past due.
        XCTAssertTrue(app.staticTexts["Next payment"].exists)
        XCTAssertTrue(app.staticTexts["Missed payments"].exists)
        XCTAssertTrue(app.staticTexts["3 missed"].exists)
        XCTAssertTrue(app.staticTexts["Owed total"].exists)
        capture("parent-loan-payments")

        payMissed.tap()
        XCTAssertTrue(app.staticTexts["Pay 3 missed loan payments?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This pays 3 separate payments totaling US$12.00 toward the loan. The next payment is not included."].exists)
        let payAll = app.buttons["Pay all"]
        XCTAssertTrue(payAll.exists)
        // A dialog captured mid-presentation is a transition frame, not an end
        // state, so wait until its action is actually usable.
        waitUntilHittable(payAll)
        capture("parent-loan-payments-confirm")

        payAll.tap()
        XCTAssertTrue(app.staticTexts["Missed payments paid"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paid 3 separate payments totaling US$12.00 toward the loan."].exists)
        capture("parent-loan-payments-recorded")

        app.buttons["Done"].tap()
        // US$24.00 - US$12.00 paid. The three missed payments are gone and
        // the last payment is capped at the US$3.00 that is left to repay.
        XCTAssertTrue(app.staticTexts["US$12.00"].waitForExistence(timeout: 5))
        let payThis = app.buttons["Pay this payment"]
        for _ in 0..<3 where !payThis.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(payThis.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Missed payments"].exists)
        capture("parent-loan-payments-settled")

        payThis.tap()
        XCTAssertTrue(app.staticTexts["Pay this loan payment?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This pays US$3.00 toward the loan for the payment due \(todayLabel)."].exists)
        let payOne = app.buttons["Pay"]
        XCTAssertTrue(payOne.waitForExistence(timeout: 5))
        waitUntilHittable(payOne)
        capture("parent-loan-payment-single-confirm")
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable, Date() < deadline {
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.05)
        }
        XCTAssertTrue(element.isHittable, "expected \(element) to settle into a usable state")
    }

    /// The same short weekday/month/day the loan payment surfaces render.
    private var todayLabel: String {
        Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
        dismissKeyboardForCapture(in: app)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["Review"].frame))
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
        dismissKeyboardForCapture(in: app)
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

    /// Reviewer-visible proof that the two formerly collapsed Cloud-plan
    /// failures render as different parent-facing cards, each with its retry.
    func testCloudPlansUnavailableCards() throws {
        for (scenario, evidenceName, expectedCopy) in [
            ("cloud-plans-not-offered", "cloud-plans-not-offered", "Cloud isn't available for this account yet."),
            ("cloud-plans-check-failed", "cloud-plans-check-failed", "Cloud plans couldn't be checked right now."),
        ] {
            let app = launch(scenario)
            XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
            unlockParentArea(app)

            let card = app.descendants(matching: .any)["cloud-backup-sync-card"]
            for _ in 0..<8 where !card.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            let note = app.staticTexts["cloud-plans-unavailable-note"]
            XCTAssertTrue(note.exists)
            XCTAssertTrue(note.label.contains(expectedCopy))
            XCTAssertTrue(app.buttons["cloud-plans-retry-button"].exists)
            capture(evidenceName)
            app.terminate()
        }
    }

    /// Reviewer-visible proof for the four captain-reported UX fixes. The
    /// behavioral UI tests own the individual regressions; this tour keeps the
    /// affected TestFlight surfaces together as synthetic screenshot evidence.
    func testCaptainUXFixesTour() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
        let one = app.buttons["PIN digit 1"]
        let zero = app.buttons["PIN digit 0"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        let restingOne = one.frame
        let restingZero = zero.frame
        capture("captain-pin-gate-static")

        app.swipeUp()
        XCTAssertEqual(one.frame, restingOne)
        XCTAssertEqual(zero.frame, restingZero)
        app.swipeDown()
        XCTAssertEqual(one.frame, restingOne)
        XCTAssertEqual(zero.frame, restingZero)

        enterPIN("1111", in: app)
        XCTAssertTrue(app.staticTexts["Incorrect PIN. Try again."].waitForExistence(timeout: 5))
        XCTAssertEqual(one.frame, restingOne)
        XCTAssertEqual(zero.frame, restingZero)
        capture("captain-pin-gate-reserved-error")

        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))

        let cloudCard = app.descendants(matching: .any)["cloud-backup-sync-card"]
        for _ in 0..<6 where !cloudCard.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(cloudCard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["cloud-benefits"].exists)
        XCTAssertTrue(app.staticTexts["cloud-plans-unavailable-note"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cloud-storekit-diagnostics-link"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cloud-recovery-details-link"].exists)
        // Capture the viewport rather than the taller-than-SE card element.
        // XCUI element screenshots pad the offscreen portion with black, which
        // is misleading reviewer evidence even though the parent area scrolls.
        capture("captain-cloud-consumer-feature")

        let deposit = app.buttons["Add deposit"]
        for _ in 0..<6 where !deposit.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(deposit.waitForExistence(timeout: 5))
        deposit.tap()

        let amount = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        XCTAssertEqual(amount.value(forKey: "hasKeyboardFocus") as? Bool, true)
        XCTAssertFalse(app.staticTexts["Enter an amount greater than US$0.00."].exists)
        capture("captain-deposit-autofocused")

        app.typeText("5.00")
        app.buttons["Review"].tap()
        XCTAssertTrue(app.staticTexts["Review before recording"].waitForExistence(timeout: 5))

        let confirm = app.buttons["Confirm add deposit"]
        let back = app.buttons["Back"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(confirm.frame))
        XCTAssertLessThanOrEqual(confirm.frame.maxY, window.maxY - 8)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(window.contains(back.frame))
        XCTAssertLessThanOrEqual(back.frame.maxY, window.maxY - 8)
        XCTAssertTrue(back.isHittable)
        capture("captain-deposit-review-fully-visible")
    }

    /// Labeled evidence for the parent write block: what a genuinely blocked
    /// parent is told, that the Cloud card agrees with it instead of claiming
    /// the device is syncing, and that the block's own control recovers.
    /// Driven through the real `CloudWalletRepository` over a synthetic
    /// in-process transport.
    func testParentBlockAndRecoveryTour() throws {
        let app = launch(
            "cloud-live-parent",
            environment: [
                "EW_UITEST_CLOUD_READ_DELAY_SECONDS": "0",
                "EW_UITEST_CLOUD_FAILED_READS": "1"
            ]
        )
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 20))
        unlockParentArea(app)

        let notice = app.descendants(matching: .any)["cloud-mutation-controls-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        for _ in 0..<6 where !app.buttons["cloud-mutation-block-recovery"].isHittable { app.swipeUp() }
        capture("parent-block-names-its-reason-and-its-way-out")

        let notSyncing = app.descendants(matching: .any)["cloud-not-syncing-note"]
        for _ in 0..<8 where !notSyncing.exists { app.swipeUp() }
        XCTAssertTrue(notSyncing.exists, "the Cloud card states the same fact the block does")
        XCTAssertFalse(app.descendants(matching: .any)["cloud-syncing-note"].exists)
        capture("parent-cloud-card-agrees-with-the-block")

        let recovery = app.buttons["cloud-mutation-block-recovery"]
        for _ in 0..<8 where !recovery.isHittable { app.swipeDown() }
        XCTAssertTrue(recovery.isHittable)
        recovery.tap()

        XCTAssertTrue(app.staticTexts["Parent actions"].waitForExistence(timeout: 15))
        let deposit = app.buttons["Add deposit"]
        var recovered = false
        for _ in 0..<40 where !recovered {
            recovered = deposit.exists && deposit.isEnabled && !notice.exists
            if !recovered { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(recovered, "the block's own control must restore the parent's money actions")
        capture("parent-block-cleared-from-the-block-itself")
    }

    func testCloudWriteStateTour() throws {
        func openDepositResult(
            _ scenario: String,
            expectedMessage: String,
            captureName: String,
            acceptedAmountVisibleToKid: Bool
        ) {
            let app = launch(scenario)
            XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
            unlockParentArea(app)
            let deposit = app.buttons["Add deposit"]
            for _ in 0..<6 where !deposit.isHittable { app.swipeUp() }
            XCTAssertTrue(deposit.waitForExistence(timeout: 5))
            deposit.tap()
            let amount = app.textFields["Amount in virtual dollars"]
            XCTAssertTrue(amount.waitForExistence(timeout: 5))
            amount.tap()
            amount.typeText("1.25")
            dismissKeyboardForCapture(in: app)
            app.buttons["Review"].tap()
            if !app.staticTexts["Review before recording"].waitForExistence(timeout: 3) {
                app.buttons["Review"].tap()
            }
            XCTAssertTrue(app.staticTexts["Review before recording"].waitForExistence(timeout: 5))
            app.buttons["Confirm add deposit"].tap()
            XCTAssertTrue(app.staticTexts[expectedMessage].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["money-flow-result"].exists)
            Thread.sleep(forTimeInterval: 0.4)
            capture(captureName)
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
            app.buttons["Done. Back to Eddie's wallet"].tap()
            XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["US$1.25"].exists, acceptedAmountVisibleToKid)
            if acceptedAmountVisibleToKid {
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "offline")).firstMatch.exists)
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "reconnect")).firstMatch.exists)
            }
            capture("\(captureName)-kid")
        }

        openDepositResult(
            "cloud-write-recorded",
            expectedMessage: "This virtual money event was accepted and added to Eddie's wallet.",
            captureName: "cloud-write-recorded",
            acceptedAmountVisibleToKid: true
        )
        openDepositResult(
            "cloud-write-waiting",
            expectedMessage: "Cloud has not confirmed this change yet. This device will retry the same protected request. Do not record it again.",
            captureName: "cloud-write-waiting",
            acceptedAmountVisibleToKid: false
        )
        openDepositResult(
            "cloud-write-accepted-waiting",
            expectedMessage: "Cloud accepted this change. This device is waiting to see it in the wallet. Do not record it again.",
            captureName: "cloud-write-accepted-waiting",
            acceptedAmountVisibleToKid: false
        )
        openDepositResult(
            "cloud-write-rejected",
            expectedMessage: "This wallet changed on another device. Review the latest balance before recording it again.",
            captureName: "cloud-write-rejected",
            acceptedAmountVisibleToKid: false
        )

        let cleanup = launch("cloud-rejected-cleanup")
        XCTAssertTrue(cleanup.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(cleanup)
        let cleanupStatus = cleanup.descendants(matching: .any)["cloud-rejected-cleanup-status"]
        XCTAssertTrue(cleanupStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(cleanup.staticTexts["Not recorded"].exists)
        XCTAssertFalse(cleanup.staticTexts["Pending"].exists)
        XCTAssertFalse(cleanup.staticTexts["Waiting to sync"].exists)
        XCTAssertFalse(cleanup.staticTexts["Checking with Cloud"].exists)
        let allowance = cleanup.buttons["parent-allowance-card"]
        XCTAssertTrue(allowance.waitForExistence(timeout: 3))
        XCTAssertTrue(allowance.label.contains("Next allowance"))
        XCTAssertFalse(allowance.label.localizedCaseInsensitiveContains("reconnect"))
        XCTAssertFalse(allowance.label.localizedCaseInsensitiveContains("checking"))
        capture("cloud-rejected-local-cleanup")
        for _ in 0..<4 where cleanupStatus.exists {
            cleanup.buttons["Finish local cleanup"].tap()
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(cleanupStatus.exists)
        capture("cloud-rejected-local-cleanup-finished")

        let profile = launch("cloud-profile-accepted-waiting")
        XCTAssertTrue(profile.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        unlockParentArea(profile)
        let editProfile = profile.descendants(matching: .any)["edit-child-profile-settings"]
        for _ in 0..<6 where !editProfile.isHittable { profile.swipeUp() }
        XCTAssertTrue(editProfile.waitForExistence(timeout: 5))
        editProfile.tap()
        let field = profile.descendants(matching: .any)["child-nickname-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText("Maya")
        profile.buttons["Save child profile"].tap()
        XCTAssertTrue(profile.descendants(matching: .any)["child-profile-cloud-waiting"].waitForExistence(timeout: 5))
        XCTAssertTrue(profile.staticTexts["Cloud accepted this change. This device is waiting to see the updated wallet. Do not save it again."].exists)
        XCTAssertFalse(profile.staticTexts["Child profile saved."].exists)
        capture("cloud-profile-accepted-waiting")

        let reconnect = launch("cloud-reconnect")
        XCTAssertTrue(reconnect.staticTexts["Your wallet needs to reconnect"].waitForExistence(timeout: 10))
        XCTAssertFalse(reconnect.staticTexts["US$0.00"].exists)
        capture("cloud-write-reconnect-kid")
        unlockParentArea(reconnect)
        XCTAssertTrue(reconnect.descendants(matching: .any)["parent-cloud-replica-unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(reconnect.buttons["Add deposit"].exists)
        capture("cloud-write-reconnect")
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
