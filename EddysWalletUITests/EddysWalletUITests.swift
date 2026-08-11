import CoreGraphics
import UIKit
import XCTest

/// End-to-end proof of the kid-first navigation model, driven through the
/// real app the way a person would tap it. Scenarios use the Debug-only
/// launch-environment seam with synthetic fixture data (nickname "Eddie",
/// PIN 1234) - no real accounts, families, or services.
final class EddysWalletUITests: XCTestCase {
    private let doorLabel = "Parent area. Asks for the parent PIN."
    private let parentActionTitles = ["Add deposit", "Record withdrawal", "Create loan", "Record repayment", "Record allowance"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(
        _ scenario: String,
        environment: [String: String] = [:],
        arguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EW_UITEST_SCENARIO"] = scenario
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            app.buttons["PIN digit \(digit)"].tap()
        }
    }

    private func assertActionButtonCornersAreFilled(_ button: XCUIElement) throws {
        let screenshot = button.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "ActionButton corner-fill rendering"
        add(attachment)

        let image = try XCTUnwrap(UIImage(data: screenshot.pngRepresentation)?.cgImage)
        let pixels = try XCTUnwrap(RenderedPixels(image: image))
        let size = button.frame.size
        let reference = pixels.averageColor(
            around: CGPoint(x: size.width - 28, y: size.height / 2),
            radius: 2,
            pointSize: size
        )
        let corners = [
            CGPoint(x: 4, y: 10),
            CGPoint(x: size.width - 4, y: 10),
            CGPoint(x: 4, y: size.height - 10),
            CGPoint(x: size.width - 4, y: size.height - 10),
        ]

        for corner in corners {
            let color = pixels.averageColor(around: corner, radius: 1, pointSize: size)
            XCTAssertLessThan(
                color.maximumChannelDistance(to: reference),
                18,
                "ActionButton corner must use the same tinted fill as its body"
            )
        }
    }

    @discardableResult
    private func openParentArea(in app: XCUIApplication) -> XCUIElement {
        let door = app.buttons[doorLabel]
        XCTAssertTrue(door.waitForExistence(timeout: 10))
        // The kid home may still be settling right after launch, so a tap that
        // lands mid-animation is retried once before failing the test.
        door.tap()
        if !app.staticTexts["Parent only"].waitForExistence(timeout: 5) {
            door.tap()
            XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 10), "Parent gate must open from the kid home door")
        }
        enterPIN("1234", in: app)
        let header = app.staticTexts["Parent area"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        return header
    }

    private func openDeposit(in app: XCUIApplication) {
        let deposit = app.buttons["Add deposit"]
        for _ in 0..<6 where !deposit.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(deposit.waitForExistence(timeout: 5))
        deposit.tap()
    }

    // Report criterion 1 (P1, P2): a configured signed-in launch rests on the
    // kid home with zero parent controls in the accessibility tree.
    func testColdLaunchRestsOnKidHomeWithoutParentControls() throws {
        let app = launch("configured")

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[doorLabel].exists)

        for title in parentActionTitles {
            XCTAssertFalse(app.buttons[title].exists, "\(title) must not be reachable on the kid home")
        }
        XCTAssertFalse(app.buttons["Sign out"].exists, "Sign out must not be reachable on the kid home")
        XCTAssertFalse(app.descendants(matching: .any)["delete-account-settings"].exists, "Account deletion must not be reachable on the kid home")
        XCTAssertFalse(app.buttons["Parent"].exists, "No peer role switch on the kid home")
        XCTAssertFalse(app.staticTexts["Parent area"].exists)
    }

    // Split-audience money copy: kid home uses plain allowance language and
    // does not show or announce the heavy virtual/pretend disclaimer.
    func testKidHomeUsesPlainAllowanceBalanceCopy() throws {
        let app = launch("configured")

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your allowance balance"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "Your allowance balance")).count,
            1,
            "Kid home must show exactly one allowance balance label"
        )

        XCTAssertFalse(app.staticTexts["Pretend dollars for practice - not real money."].exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "pretend")).count,
            0,
            "Kid home must not show pretend disclaimers"
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "nonredeemable")).count,
            0,
            "Kid home must not show nonredeemable legal framing"
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "not real money")).count,
            0,
            "Kid home must not announce not-real-money disclaimers"
        )

        app.staticTexts["Comic book"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Activity detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your parent"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.staticTexts["Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."].exists,
            "Kid activity detail must not carry the parent safety footer"
        )
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        app.staticTexts["A little at a time is okay"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loan details"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Your parent gave you dollars")).firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.staticTexts["Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."].exists,
            "Kid loan detail must not carry the parent safety footer"
        )
        app.buttons["Done"].tap()
    }

    func testParentAreaKeepsVirtualMoneyBoundary() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        openParentArea(in: app)
        XCTAssertTrue(app.staticTexts["Eddie's virtual balance"].waitForExistence(timeout: 5))
        let parentNotice = "Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."
        XCTAssertTrue(
            app.staticTexts[parentNotice].waitForExistence(timeout: 5),
            "Parent balance card must keep the nonredeemable / no-real-money notice"
        )

        // Parent review copy stays firm when recording money.
        let deposit = app.buttons["Add deposit"]
        for _ in 0..<4 where !deposit.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(deposit.waitForExistence(timeout: 5))
        deposit.tap()
        let amountField = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("1.00")
        app.buttons["Review"].tap()
        XCTAssertTrue(
            app.staticTexts[parentNotice].waitForExistence(timeout: 5),
            "Parent money flow review must keep the virtual-money notice"
        )
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
    }

    // Report criterion 3 (P4): wrong PIN stays gated; cancel returns to the
    // kid home with no parent data revealed.
    func testWrongPINStaysGatedAndCancelReturnsToKidHome() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
        enterPIN("1111", in: app)

        XCTAssertTrue(app.staticTexts["Incorrect PIN. Try again."].waitForExistence(timeout: 3))
        for title in parentActionTitles {
            XCTAssertFalse(app.buttons[title].exists, "A failed PIN must not reveal \(title)")
        }

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    // Report criterion 3 (P2): door -> correct PIN is the only route to money
    // actions; Done returns to the kid home.
    func testCorrectPINOpensParentAreaAndDoneReturns() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        openParentArea(in: app)
        for title in parentActionTitles {
            let button = app.buttons[title]
            XCTAssertTrue(button.exists, "\(title) must exist inside the Parent area")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(title) hit target must be at least 44pt tall")
            XCTAssertGreaterThan(button.frame.width, 44, "\(title) hit target must stay wide enough to tap")
        }
        let depositButton = app.buttons["Add deposit"]
        for _ in 0..<4 where !depositButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(depositButton.isHittable)
        try assertActionButtonCornersAreFilled(depositButton)
        XCTAssertTrue(app.buttons["Sign out"].exists)
        XCTAssertTrue(app.buttons["Change PIN"].exists)

        // Exercise one action path so the filled control is the real parent
        // chrome, not a disconnected preview.
        depositButton.tap()
        XCTAssertTrue(app.textFields["Amount in virtual dollars"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))

        app.buttons["Done. Back to Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add deposit"].exists)
    }

    // A PIN pad is a fixed target. It must never scroll, bounce, or shift under
    // a thumb that is already on its way down, and every control on the gate has
    // to be reachable without moving the screen at all.
    func testParentPINGateIsFixedAndCannotScroll() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 10))

        let one = app.buttons["PIN digit 1"]
        let zero = app.buttons["PIN digit 0"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        let restingOne = one.frame
        let restingZero = zero.frame

        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(restingOne), "the keypad must fit the screen without scrolling")
        XCTAssertTrue(window.contains(restingZero))
        XCTAssertGreaterThanOrEqual(restingOne.height, 44, "PIN keys must keep a 44pt hit target on every phone size")
        XCTAssertTrue(app.buttons["Forgot PIN?"].isHittable)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)

        app.swipeUp()
        XCTAssertEqual(one.frame, restingOne, "the PIN pad must not scroll or bounce upward")
        XCTAssertEqual(zero.frame, restingZero)

        app.swipeDown()
        XCTAssertEqual(one.frame, restingOne, "the PIN pad must not scroll or bounce downward")
        XCTAssertEqual(zero.frame, restingZero)

        // The error message appears in space the gate already reserved, so the
        // keys stay exactly where the last tap left them.
        enterPIN("1111", in: app)
        XCTAssertTrue(app.staticTexts["Incorrect PIN. Try again."].waitForExistence(timeout: 5))
        XCTAssertEqual(one.frame, restingOne, "showing the incorrect-PIN message must not move the keypad")
        XCTAssertEqual(zero.frame, restingZero)
    }

    // Cloud/client sync diagnosis is finished: a shipped build offers no route
    // into the internal diagnostics surfaces. This launch omits the Debug
    // diagnostics seam, so it sees exactly what a person on TestFlight sees.
    func testParentCloudSectionOffersNoPathIntoDiagnostics() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let card = app.otherElements["cloud-backup-sync-card"]
        for _ in 0..<10 where !card.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        XCTAssertFalse(app.descendants(matching: .any)["cloud-storekit-diagnostics-link"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["cloud-recovery-details-link"].exists)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "diagnostic")).count,
            0,
            "no parent-facing control may lead into a diagnostics screen"
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "storekit")).count,
            0
        )

        // What replaces it reads as a product feature a parent can decide about.
        XCTAssertTrue(app.descendants(matching: .any)["cloud-benefits"].exists, "the Cloud section explains what Cloud does for the family")
        XCTAssertTrue(app.staticTexts["cloud-plans-unavailable-note"].exists, "and still says plainly that it is not available yet")
    }

    func testCloudAuthorityHeaderShowsPlanStateInsteadOfPitch() throws {
        let app = launch("cloud-pending")
        XCTAssertTrue(app.descendants(matching: .any)["kid-cloud-replica-unavailable"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let card = app.otherElements["cloud-backup-sync-card"]
        for _ in 0..<10 where !card.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Confirming this family's Cloud plan"))
                .firstMatch.exists
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "An optional extra"))
                .firstMatch.exists
        )
    }

    // Tapping a money action must land on a field that is ready to type into:
    // focused, with the keyboard already up, and with no error shown for an
    // amount the parent has not entered yet.
    func testAddDepositOpensFocusedWithTheKeyboardUp() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        openDeposit(in: app)
        let amount = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "the amount keyboard must already be up")
        XCTAssertEqual(amount.value(forKey: "hasKeyboardFocus") as? Bool, true, "the amount field must already hold focus")
        XCTAssertFalse(
            app.staticTexts["Enter an amount greater than US$0.00."].exists,
            "an untouched amount is not an error"
        )

        // Typing with no extra tap proves the focus is real, not decorative.
        // Pace the synthetic key events by waiting for each one to reach the
        // field. A busy CI simulator can otherwise discard the tail of one
        // multi-character XCTest event even though the app handled every key
        // event it actually received.
        for (character, expectedValue) in [("7", "7"), (".", "7."), ("5", "7.5"), ("0", "7.50")] {
            app.typeText(character)
            let valueArrived = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expectedValue),
                object: amount
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [valueArrived], timeout: 2),
                .completed,
                "the amount field must receive \(character) before XCTest sends the next key"
            )
        }
        XCTAssertEqual(amount.value as? String, "7.50")
        XCTAssertFalse(app.staticTexts["Enter an amount greater than US$0.00."].exists)
    }

    /// The contract every sheet in the app owes a parent: the control that
    /// finishes the job is on screen and tappable as soon as the sheet is,
    /// whatever the sheet's height, the device size, or the keyboard state.
    /// `isHittable` is the honest check - it fails for a control clipped by its
    /// sheet, scrolled past the fold, or covered by the keyboard.
    private func assertActionIsReachable(
        _ element: XCUIElement,
        _ description: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(description) must exist", file: file, line: line)
        let window = app.windows.firstMatch.frame
        // Not flush against the screen edge either: a control rendered right on
        // the fold is what a clipped action looked like.
        let minimumClearance: CGFloat = 8
        XCTAssertTrue(window.contains(element.frame), "\(description) must be fully on screen, not below the fold", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, window.maxY - minimumClearance, "\(description) must not sit on the fold", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(description) must keep its full hit target, not a clipped one", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(description) must be tappable without hunting for it", file: file, line: line)
    }

    // The review step's decision controls stay fully on screen: a confirm
    // affordance clipped at the fold is how a parent records nothing, or the
    // wrong thing.
    func testAddDepositReviewKeepsConfirmAndBackFullyOnScreen() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        openDeposit(in: app)
        let amount = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        // Tapped explicitly: this test is about the review step's layout, so it
        // must not depend on the amount step already holding focus.
        amount.tap()
        amount.typeText("5.00")
        app.buttons["Review"].tap()

        let confirm = app.buttons["Confirm add deposit"]
        assertActionIsReachable(confirm, "the confirm control", in: app)
        assertActionIsReachable(app.buttons["Back"], "the way back", in: app)

        // The pinned controls are the real ones, so the flow still completes.
        confirm.tap()
        XCTAssertTrue(app.otherElements["money-flow-result"].waitForExistence(timeout: 10))
    }

    // The reported iPad failure, generalised: the amount step opens with the
    // keyboard already up, so the control that carries the step forward has to
    // survive both the shorter sheet and the keyboard. It also has to stay
    // reachable for the longest money form, which adds a due-date row the
    // shortest screens cannot show at once.
    func testMoneyAmountStepKeepsItsPrimaryActionAboveTheKeyboard() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        openDeposit(in: app)
        let amount = app.textFields["Amount in virtual dollars"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        assertActionIsReachable(app.buttons["Review"], "the deposit review control", in: app)
        amount.tap()
        amount.typeText("5.00")
        assertActionIsReachable(app.buttons["Review"], "the deposit review control with the keyboard up", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))

        let loan = app.buttons["Create loan"]
        for _ in 0..<6 where !loan.isHittable { app.swipeUp() }
        loan.tap()
        XCTAssertTrue(app.textFields["Amount in virtual dollars"].waitForExistence(timeout: 5))
        assertActionIsReachable(app.buttons["Review"], "the loan review control", in: app)
        // The due-date row is content, so it may need a scroll on a short
        // screen - but it must genuinely be scrollable to, never trapped.
        let duePicker = app.datePickers.firstMatch
        let sheetScroll = app.scrollViews.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sheet-form-scroll-fade-")
        ).firstMatch
        XCTAssertTrue(sheetScroll.waitForExistence(timeout: 5))
        for _ in 0..<4 where !duePicker.isHittable { sheetScroll.swipeUp() }
        XCTAssertTrue(duePicker.isHittable, "the loan due date must be reachable by scrolling the sheet")
        assertActionIsReachable(app.buttons["Review"], "the loan review control after scrolling", in: app)
    }

    func testLoanSheetFadeClearsAtContentEnd() throws {
        let phoneOverflowArguments = UIDevice.current.userInterfaceIdiom == .pad
            ? []
            : ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let app = launch("configured", arguments: phoneOverflowArguments)
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let loan = app.buttons["Create loan"]
        for _ in 0..<6 where !loan.isHittable { app.swipeUp() }
        loan.tap()

        let review = app.buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))

        // A full-height iPad sheet at the default text size has enough room
        // for this form, so it must not imply that content is hidden. The
        // phone run uses accessibility XXXL text to guarantee genuine
        // overflow independently of simulator keyboard settings.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(
                app.scrollViews["sheet-form-scroll-fade-hidden"].waitForExistence(timeout: 5),
                "a loan form that fits on iPad must not show a false scroll affordance"
            )
            XCTAssertFalse(app.scrollViews["sheet-form-scroll-fade-visible"].exists)
            assertActionIsReachable(review, "the iPad loan review control", in: app)
            return
        }

        let visibleScroll = app.scrollViews["sheet-form-scroll-fade-visible"]
        let hiddenScroll = app.scrollViews["sheet-form-scroll-fade-hidden"]
        XCTAssertTrue(
            visibleScroll.waitForExistence(timeout: 5),
            "the fade must be visible while the loan form continues below the viewport"
        )

        for _ in 0..<8 where !hiddenScroll.exists {
            visibleScroll.swipeUp()
        }

        XCTAssertTrue(
            hiddenScroll.waitForExistence(timeout: 5),
            "the fade must clear when the loan form reaches its content end"
        )
        XCTAssertFalse(app.scrollViews["sheet-form-scroll-fade-visible"].exists)
        assertActionIsReachable(review, "the loan review control at the content end", in: app)
    }

    // Every remaining parent sheet owes the same contract. Before this was one
    // shared layout, half-height sheets left `Save new PIN` and the allowance
    // controls under the fold with nothing on screen saying so.
    func testEveryParentSettingsSheetKeepsItsPrimaryActionReachable() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let allowanceCard = app.buttons["parent-allowance-card"]
        for _ in 0..<8 where !allowanceCard.isHittable { app.swipeDown() }
        allowanceCard.tap()
        XCTAssertTrue(app.staticTexts["Set allowance"].waitForExistence(timeout: 5))
        assertActionIsReachable(app.buttons["Review allowance"], "the allowance review control", in: app)
        // Addressed by identifier: its label names the device it is running on.
        assertActionIsReachable(app.buttons["allowance-save-draft"], "the allowance draft control", in: app)
        XCTAssertEqual(
            app.buttons["allowance-save-draft"].label,
            "Save as draft on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")",
            "the draft control must name the device it is actually running on"
        )
        app.buttons["Review allowance"].tap()
        assertActionIsReachable(app.buttons["Confirm allowance"], "the allowance confirm control", in: app)
        app.buttons["Back"].tap()
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))

        let changePIN = app.buttons["Change PIN"]
        for _ in 0..<8 where !changePIN.isHittable { app.swipeUp() }
        changePIN.tap()
        XCTAssertTrue(app.staticTexts["Change PIN"].waitForExistence(timeout: 5))
        assertActionIsReachable(app.buttons["Save new PIN"], "the change-PIN save control", in: app)
        let currentPIN = app.secureTextFields["Current PIN"]
        currentPIN.tap()
        currentPIN.typeText("1234")
        assertActionIsReachable(app.buttons["Save new PIN"], "the change-PIN save control with the keyboard up", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))

        let editProfile = app.buttons["edit-child-profile-settings"]
        for _ in 0..<8 where !editProfile.isHittable { app.swipeUp() }
        editProfile.tap()
        XCTAssertTrue(app.staticTexts["Child profile"].waitForExistence(timeout: 5))
        assertActionIsReachable(app.buttons["Save child profile"], "the child-profile save control", in: app)
        app.textFields["child-nickname-field"].tap()
        assertActionIsReachable(app.buttons["Save child profile"], "the child-profile save control with the keyboard up", in: app)
    }

    // The loan sheet's repayment control is an action, not detail copy, so it
    // belongs in the bottom bar even at the half-height detent this sheet opens
    // at. The kid's read-only loan sheet must not grow one.
    func testLoanSheetPinsTheParentRepaymentActionAndTheKidSheetHasNone() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.staticTexts["A little at a time is okay"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loan details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["loan-record-repayment"].exists, "the kid loan sheet offers no parent action")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))

        openParentArea(in: app)
        let loanCard = app.staticTexts["Secondary wallet card"].firstMatch
        for _ in 0..<6 where !loanCard.isHittable { app.swipeUp() }
        loanCard.tap()
        XCTAssertTrue(app.staticTexts["Loan details"].waitForExistence(timeout: 5))
        assertActionIsReachable(app.buttons["loan-record-repayment"], "the loan repayment control", in: app)
    }

    func testParentCanEditChildNicknameAndKidHomeShowsIt() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        openParentArea(in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["edit-child-profile-card"].exists,
            "The redundant top child-profile entry must be removed; Settings is the single edit path"
        )

        let settingsRow = app.descendants(matching: .any)["edit-child-profile-settings"]
        for _ in 0..<4 where !settingsRow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5), "Settings must expose Edit child profile")
        settingsRow.tap()

        let field = app.descendants(matching: .any)["child-nickname-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Child profile editor must present the nickname field")
        XCTAssertEqual(field.value as? String, "Eddie", "Editor must load the current nickname")
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            field.typeText(deleteString)
        }
        field.typeText("Maya")

        let save = app.buttons["Save child profile"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled, "A non-empty nickname must enable save, matching setup validation")
        save.tap()
        XCTAssertTrue(app.staticTexts["Child profile saved."].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Maya's virtual balance"].waitForExistence(timeout: 5), "Parent summary must show the saved nickname")

        // Settings still exposes the same editor.
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["edit-child-profile-settings"].waitForExistence(timeout: 5))

        app.buttons["Done. Back to Maya's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Maya"].waitForExistence(timeout: 5), "Kid home must use the saved nickname")
        XCTAssertTrue(app.staticTexts["Maya's Wallet"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["Eddie's Wallet"].exists,
            "Kid home must not show the external brand wordmark as recurring identity when the child is Maya"
        )
    }

    /// Brand placement: a non-Eddie synthetic child sees personal/neutral main
    /// chrome; welcome keeps the external product name; Eddie fixture nickname
    /// still personalizes rather than being stripped.
    func testMainScreensUseChildPersonalChromeNotStaticBrand() throws {
        let maya = launch("configured", environment: ["EW_UITEST_NICKNAME": "Maya"])
        XCTAssertTrue(maya.staticTexts["Hi, Maya"].waitForExistence(timeout: 10))
        XCTAssertTrue(maya.staticTexts["Your allowance balance"].exists)
        XCTAssertFalse(maya.staticTexts["Pretend dollars for practice - not real money."].exists)
        XCTAssertTrue(maya.staticTexts["Maya's Wallet"].exists)
        XCTAssertFalse(maya.staticTexts["Eddie's Wallet"].exists)
        XCTAssertFalse(maya.staticTexts["Eddie's wallet"].exists)

        openParentArea(in: maya)
        XCTAssertTrue(maya.staticTexts["Parent area"].waitForExistence(timeout: 5))
        XCTAssertTrue(maya.staticTexts["Maya's virtual balance"].waitForExistence(timeout: 5))
        // Done is the persistent exit; its accessibility label is child-personal.
        XCTAssertTrue(maya.buttons["Done. Back to Maya's wallet"].exists)
        XCTAssertFalse(maya.staticTexts["Eddie's Wallet"].exists)
        XCTAssertFalse(maya.buttons["Done. Back to Eddie's wallet"].exists)

        maya.buttons["Done. Back to Maya's wallet"].tap()
        XCTAssertTrue(maya.staticTexts["Hi, Maya"].waitForExistence(timeout: 5))

        // Empty wallet still personalizes the header and exposes the handoff CTA.
        let mayaEmpty = launch("configured-empty", environment: ["EW_UITEST_NICKNAME": "Maya"])
        XCTAssertTrue(mayaEmpty.staticTexts["Maya's Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(mayaEmpty.staticTexts["Your wallet is ready!"].exists)
        openParentArea(in: mayaEmpty)
        XCTAssertTrue(mayaEmpty.buttons["Show Maya's wallet"].waitForExistence(timeout: 5))
        XCTAssertFalse(mayaEmpty.buttons["Show Eddie's wallet"].exists)
        mayaEmpty.buttons["Done. Back to Maya's wallet"].tap()

        // Neutral fallback when nickname is blank.
        let neutral = launch("configured", environment: ["EW_UITEST_NICKNAME": ""])
        XCTAssertTrue(neutral.staticTexts["Your wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(neutral.staticTexts["Your allowance balance"].exists)
        XCTAssertFalse(neutral.staticTexts["Pretend dollars for practice - not real money."].exists)
        XCTAssertFalse(neutral.staticTexts["Eddie's Wallet"].exists)
        XCTAssertFalse(neutral.staticTexts["Hi, Eddie"].exists)
        openParentArea(in: neutral)
        XCTAssertTrue(neutral.staticTexts["Your child's virtual balance"].waitForExistence(timeout: 5))
        XCTAssertTrue(neutral.buttons["Done. Back to your child's wallet"].exists)
        XCTAssertFalse(neutral.staticTexts["Eddie's Wallet"].exists)

        // Fixture nickname Eddie remains valid personal data.
        let eddie = launch("configured")
        XCTAssertTrue(eddie.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        XCTAssertTrue(eddie.staticTexts["Eddie's Wallet"].exists, "Personal header when the child is named Eddie")
        openParentArea(in: eddie)
        XCTAssertTrue(eddie.staticTexts["Eddie's virtual balance"].waitForExistence(timeout: 5))
        XCTAssertTrue(eddie.buttons["Done. Back to Eddie's wallet"].exists)

        // Welcome / onboarding keeps the honest external brand wordmark. The
        // first-run scenario forces a deterministic pre-setup state instead of
        // inheriting whatever this simulator's app data happens to hold.
        let plain = launch("first-run")
        XCTAssertTrue(plain.staticTexts["Eddie's Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(plain.descendants(matching: .any)["product-brand-wordmark"].exists)
        XCTAssertTrue(plain.staticTexts["Virtual practice only"].exists)
    }

    // Promotion item 5: runtime StoreKit proof from the real Debug app, since an
    // XCTest-host query returned no products. The Debug-only diagnostics surface
    // renders exactly what StoreKit resolved. Under `xcodebuild` that resolution
    // comes from the live App Store sandbox catalog rather than the scheme's
    // configuration file - see `terminalStoreKitDiagnosticsStatus` - so this
    // proves the shipping products and prices, and `CloudStoreConfigurationTests`
    // separately pins the checked-in configuration to the same values.
    func testDebugStoreKitDiagnosticsProvesTheExactCloudProductsAndPrices() throws {
        let app = launch("configured", environment: ["EW_UITEST_DIAGNOSTICS": "1"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let link = app.descendants(matching: .any)["cloud-storekit-diagnostics-link"]
        for _ in 0..<10 where !link.isHittable {
            app.swipeUp()
        }
        if !link.waitForExistence(timeout: 5) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "parent-area-tree"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("SCRATCH TREE\n\(app.debugDescription)")
        }
        XCTAssertTrue(link.exists)
        link.tap()

        let status = terminalStoreKitDiagnosticsStatus(in: app)
        XCTAssertEqual(status, "loaded 2 products", "StoreKit must resolve both Cloud products, and this is what it said instead")
        XCTAssertEqual(app.staticTexts["storekit-product-com.kunchenguid.eddieswallet.cloud.monthly"].label, "com.kunchenguid.eddieswallet.cloud.monthly")
        XCTAssertEqual(app.staticTexts["storekit-product-com.kunchenguid.eddieswallet.cloud.annual"].label, "com.kunchenguid.eddieswallet.cloud.annual")
        XCTAssertEqual(app.staticTexts["storekit-price-com.kunchenguid.eddieswallet.cloud.monthly"].label, "$2.99")
        XCTAssertEqual(app.staticTexts["storekit-price-com.kunchenguid.eddieswallet.cloud.annual"].label, "$24.99")
        XCTAssertEqual(app.staticTexts["storekit-terms-com.kunchenguid.eddieswallet.cloud.monthly"].label, "1 month · family shareable: no")
        XCTAssertEqual(app.staticTexts["storekit-terms-com.kunchenguid.eddieswallet.cloud.annual"].label, "1 year · family shareable: no")
    }

    // A guarded build must never present a price or purchase control when the
    // backend capability is unavailable, which is the shipped default.
    func testParentAreaHidesCloudPurchaseControlsWhenCapabilityIsUnavailable() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let card = app.otherElements["cloud-backup-sync-card"]
        for _ in 0..<8 where !card.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["cloud-plans-unavailable-note"].exists, "an unavailable backend says so plainly")
        XCTAssertFalse(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.monthly"].exists)
        XCTAssertFalse(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.annual"].exists)
        XCTAssertFalse(app.buttons["cloud-restore-button"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "$2.99")).count, 0, "no price without a ready backend")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "$24.99")).count, 0)
    }

    // The unavailable card must say which kind of unavailable it is. A
    // deliberate service "no" reads as account availability - never as a
    // passing outage - and the parent can check again from the card itself.
    func testCloudPlansNotOfferedCardNamesAccountPolicyAndOffersCheckAgain() throws {
        let app = launch("cloud-plans-not-offered")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let card = app.otherElements["cloud-backup-sync-card"]
        for _ in 0..<8 where !card.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let note = app.staticTexts["cloud-plans-unavailable-note"]
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("isn't available for this account"), "a policy answer names the account, got: \(note.label)")
        XCTAssertTrue(app.buttons["cloud-plans-retry-button"].exists, "the unavailable card carries its own retry")
        XCTAssertFalse(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.monthly"].exists)
        XCTAssertFalse(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.annual"].exists)
    }

    // A failed availability check is the other branch: transient wording, a
    // retry, and still no purchase control or price.
    func testCloudPlansCheckFailedCardReadsAsTransientAndOffersCheckAgain() throws {
        let app = launch("cloud-plans-check-failed")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let card = app.otherElements["cloud-backup-sync-card"]
        for _ in 0..<8 where !card.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let note = app.staticTexts["cloud-plans-unavailable-note"]
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("couldn't be checked right now"), "a failed check reads as transient, got: \(note.label)")
        let retry = app.buttons["cloud-plans-retry-button"]
        XCTAssertTrue(retry.exists, "a failed check offers a way to run it again")
        XCTAssertFalse(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.monthly"].exists)
        XCTAssertFalse(app.buttons["cloud-restore-button"].exists)
    }

    // Guideline 3.1.2: the purchase surface itself must show the auto-renew
    // disclosure and functional links to both the terms of use and the
    // privacy policy, in close proximity to the purchase controls. Exact URL
    // correctness is pinned separately by
    // `testCloudPlansLegalLinksPointAtTheRequiredDestinations`; this proves
    // the links actually render, are tappable, and sit alongside the offer
    // in the real card - not merely that the right strings exist somewhere.
    func testCloudPlansCardShowsTappableTermsAndPrivacyLinksWithAutoRenewDisclosure() throws {
        let app = launch("cloud-plans-available")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let card = app.otherElements["cloud-backup-sync-card"]
        for _ in 0..<8 where !card.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.monthly"].exists)
        XCTAssertTrue(app.buttons["cloud-plan-com.kunchenguid.eddieswallet.cloud.annual"].exists)
        XCTAssertTrue(app.buttons["cloud-restore-button"].exists)

        let disclosure = app.staticTexts["cloud-auto-renew-disclosure"]
        for _ in 0..<8 where !disclosure.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.label.localizedCaseInsensitiveContains("renew"))
        XCTAssertTrue(disclosure.label.localizedCaseInsensitiveContains("cancel"))

        // `Link` does not report a stable XCUIElementType across OS
        // versions, so query loosely by identifier as the existing
        // diagnostics-link test already does.
        let terms = app.descendants(matching: .any)["cloud-terms-link"]
        let privacy = app.descendants(matching: .any)["cloud-privacy-link"]
        for _ in 0..<8 where !terms.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(terms.waitForExistence(timeout: 5))
        XCTAssertEqual(terms.label, "Terms of Use")
        XCTAssertTrue(terms.isHittable, "the terms link must be tappable, not just present")
        XCTAssertTrue(privacy.exists)
        XCTAssertEqual(privacy.label, "Privacy Policy")
        XCTAssertTrue(privacy.isHittable, "the privacy link must be tappable, not just present")
    }

    func testRejectedCloudCleanupIsTerminalAndLocallyRetryable() throws {
        let app = launch("cloud-rejected-cleanup")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let cleanup = app.descendants(matching: .any)["cloud-rejected-cleanup-status"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not recorded"].exists)
        XCTAssertTrue(app.staticTexts["This change was not recorded. Finish local cleanup on this iPhone before recording another action."].exists)
        XCTAssertFalse(app.staticTexts["Pending"].exists)
        XCTAssertFalse(app.staticTexts["Waiting to sync"].exists)
        XCTAssertFalse(app.staticTexts["Checking with Cloud"].exists)
        XCTAssertFalse(app.staticTexts["Accepted by Cloud"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "reconnect")).firstMatch.exists)
        let allowance = app.buttons["parent-allowance-card"]
        XCTAssertTrue(allowance.waitForExistence(timeout: 3))
        XCTAssertTrue(allowance.label.contains("Next allowance"))
        XCTAssertFalse(allowance.label.localizedCaseInsensitiveContains("reconnect"))
        XCTAssertFalse(allowance.label.localizedCaseInsensitiveContains("checking"))

        for _ in 0..<4 where cleanup.exists {
            let finish = app.buttons["Finish local cleanup"]
            XCTAssertTrue(finish.waitForExistence(timeout: 3))
            finish.tap()
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(cleanup.exists)
        XCTAssertFalse(app.descendants(matching: .any)["cloud-mutation-controls-notice"].exists)

        app.buttons["Done. Back to Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Not recorded"].exists)
        XCTAssertFalse(app.staticTexts["Checking with Cloud"].exists)
    }

    // Report criterion 2 (P3): backgrounding drops elevation; foregrounding
    // shows the kid home again.
    func testBackgroundingDropsParentElevation() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        XCUIDevice.shared.press(.home)
        // Wait for the app to actually leave the foreground instead of a fixed
        // sleep: under CPU load the transition can take longer than a second,
        // and reactivating before the app ever backgrounded makes the
        // elevation-drop assertion race instead of testing the contract.
        let leftForeground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(XCTWaiter().wait(for: [leftForeground], timeout: 10), .completed,
                       "The app must reach the background before reactivation")
        app.activate()

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Parent area"].exists)
        XCTAssertFalse(app.buttons["Add deposit"].exists)
    }

    // Report criterion 3 (P4): five misses start a visible cooldown and the
    // keypad stops accepting digits.
    func testFiveWrongPINsStartCooldown() throws {
        let app = launch("configured", environment: ["EW_UITEST_FAST_COOLDOWN": "1"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))

        for _ in 0..<5 {
            enterPIN("9999", in: app)
        }

        let cooldown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Too many tries.")).firstMatch
        XCTAssertTrue(cooldown.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["PIN digit 1"].isEnabled, "The keypad must pause during the cooldown")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    // Report criterion 4 (P5): sign-out lives only inside the Parent area and
    // asks for a truthful confirmation.
    func testSignOutRequiresConfirmationInsideParentArea() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        app.buttons["Sign out"].tap()
        let deviceNoun = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let confirm = app.buttons["Sign out from this \(deviceNoun)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Sign out must ask for confirmation")
        confirm.tap()

        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Hi, Eddie"].exists, "No usable family data after sign-out")
    }

    // Account deletion is an intentionally separate destructive route, behind
    // the PIN gate, with both deliberate confirmations required before it can
    // erase even synthetic local fixture data.
    func testAccountDeletionRequiresTypedAndBillingConfirmationsThenReturnsToWelcome() throws {
        let app = launch("delete-account-subscribed")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        let entry = app.descendants(matching: .any)["delete-account-settings"]
        for _ in 0..<10 where !entry.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Delete account must be inside the PIN-gated Parent area")
        entry.tap()

        XCTAssertTrue(app.staticTexts["Delete your account and Eddie's Wallet?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "kept for up to 30 days")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "another family device")).firstMatch.exists)
        XCTAssertTrue(app.buttons["delete-account-manage-subscription"].exists)

        let delete = app.buttons["delete-account-confirm-button"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "typing alone and billing acknowledgement alone must not arm deletion")

        let field = app.textFields["delete-account-confirmation-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("DELETE")
        XCTAssertFalse(delete.isEnabled, "billing acknowledgement remains required after typed confirmation")

        let acknowledgement = app.switches["delete-account-billing-acknowledgement"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 5))
        acknowledgement.tap()
        XCTAssertTrue(delete.isEnabled, "only both confirmations may arm the destructive action")

        delete.tap()
        XCTAssertTrue(app.descendants(matching: .any)["delete-account-success"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your account and wallet are deleted."].exists)

        app.buttons["delete-account-done"].tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Hi, Eddie"].exists, "terminal Done must leave no signed-in child wallet")
    }

    // Captain-selected recovery: fresh Sign in with Apple by the owning
    // parent permits a new PIN; family data stays intact.
    func testForgottenPINRecoveryWithOwningParent() throws {
        let app = launch("no-pin")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Reset the parent PIN"].waitForExistence(timeout: 5))
        app.buttons["Sign in with Apple"].tap()

        let newPINField = app.secureTextFields["New parent PIN"]
        XCTAssertTrue(newPINField.waitForExistence(timeout: 5))
        newPINField.tap()
        newPINField.typeText("2468")
        let confirmField = app.secureTextFields["Confirm new parent PIN"]
        confirmField.tap()
        confirmField.typeText("2468")
        app.buttons["Save parent PIN"].tap()

        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
        // Family data is intact: the wallet still shows fixture content.
        XCTAssertTrue(app.staticTexts["Next allowance"].waitForExistence(timeout: 5))

        app.buttons["Done. Back to Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    // Recovery must not accept an arbitrary Apple account.
    func testRecoveryRejectsOtherAppleAccount() throws {
        let app = launch("no-pin", environment: ["EW_UITEST_APPLE_USER": "someone-else"])
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Reset the parent PIN"].waitForExistence(timeout: 5))
        app.buttons["Sign in with Apple"].tap()

        let mismatch = app.staticTexts["That is not the Apple account that manages this wallet."]
        XCTAssertTrue(mismatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["New parent PIN"].exists, "A mismatched account must not reach PIN setup")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
    }

    // Report criterion 6: the empty-family kid home shows the friendly
    // ready-state card instead of a bare header.
    func testEmptyWalletShowsKidReadyCard() throws {
        let app = launch("configured-empty")

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your wallet is ready!"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your parent can add the first dollars."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Your allowance balance"].exists)
        XCTAssertFalse(app.staticTexts["What's been happening"].exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "pretend")).count,
            0,
            "Empty kid wallet must not use pretend wording"
        )
    }

    // Report criterion 5: the offline kid home keeps the cached balance and
    // uses kid words, never parent vocabulary.
    func testOfflineKidHomeUsesKidWords() throws {
        let app = launch("offline")

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You're offline")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        let technical = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "accepted balance"))
        XCTAssertEqual(technical.count, 0, "Technical vocabulary must not appear on the kid home")

        app.staticTexts["Comic book"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Activity detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your parent recorded that US$4.00 was used."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Legacy cached explanation with virtual dollars."].exists)
    }

    // The honest split, end to end. A device that is online but could not get
    // an answer must never tell a kid they are offline, and the exact failure
    // must be reachable behind the parent PIN - carrying nothing about the
    // family, the account, or the wallet.
    func testUnreachableServiceReadsHonestlyAndIsExplainedOnlyToAParent() throws {
        let app = launch("cannot-reach")

        let cannotReach = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Your wallet is hard to reach")
        ).firstMatch
        XCTAssertTrue(cannotReach.waitForExistence(timeout: 10), "an unreachable service is reported as exactly that")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "offline")).count,
            0,
            "a device with a working connection must never be told it is offline"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["connection-details-settings"].exists,
            "raw failure detail is never kid-facing"
        )

        _ = openParentArea(in: app)
        let details = app.buttons["connection-details-settings"]
        for _ in 0..<8 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()

        XCTAssertTrue(app.staticTexts["Connection details"].waitForExistence(timeout: 5))
        let category = app.descendants(matching: .any)["connection-detail-category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertTrue(category.label.contains("timedOut"), "the readout names the failure the transport reported: \(category.label)")
        XCTAssertTrue(app.descendants(matching: .any)["connection-detail-route"].label.contains("/v1/child-view"))
        XCTAssertTrue(app.buttons["copy-connection-details"].exists, "a parent can hand the failure on")

        // The readout is exactly these rows, and the copy action shares the
        // same rows, so nothing sensitive can be handed on from here.
        let rowIdentifiers = ["category", "code", "underlying", "route", "status", "elapsed", "timestamp"]
        for identifier in rowIdentifiers {
            let row = app.descendants(matching: .any)["connection-detail-\(identifier)"]
            XCTAssertTrue(row.exists, "the readout is missing its \(identifier) row")
            for forbidden in ["Eddie", "Bearer", "token", "US$", "https"] {
                XCTAssertFalse(
                    row.label.contains(forbidden),
                    "\(forbidden) must never appear on a shareable connection readout: \(row.label)"
                )
            }
        }
    }

    // The reported field defect, end to end: the read the app issues at launch
    // stalls and fails after a later read has already published the current
    // wallet. The kid home must end on what it actually fetched - an online,
    // authenticated session is never relabelled offline by a stale read.
    func testStalledLaunchReadNeverRelabelsTheKidHomeOffline() throws {
        let app = launch("reconnecting", environment: ["EW_UITEST_STALLED_FIRST_READ_SECONDS": "3"])

        let fetchedBalance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "US$36.75")
        ).firstMatch
        XCTAssertTrue(fetchedBalance.waitForExistence(timeout: 15), "the successful read must reach the kid home")

        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You're offline")).firstMatch
        XCTAssertFalse(
            banner.waitForExistence(timeout: 8),
            "the stalled launch read failing late must not relabel a freshly fetched wallet as offline"
        )
        XCTAssertTrue(fetchedBalance.exists, "the fetched wallet must stay on screen")
    }

    // Pull-to-refresh on the kid home performs the authoritative read, applies
    // what comes back, and clears the offline banner. Nothing before the pull
    // may invent freshness the app never fetched.
    func testKidHomePullToRefreshFetchesAndClearsTheOfflineBanner() throws {
        let app = launch("reconnecting", environment: ["EW_UITEST_OFFLINE_WINDOW_SECONDS": "4"])

        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You're offline")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "an unreachable authority is reported honestly")
        let cachedBalance = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "US$24.00")).firstMatch
        XCTAssertTrue(cachedBalance.exists, "the last accepted wallet stays on screen while offline")

        let fetchedBalance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "US$36.75")
        ).firstMatch
        XCTAssertFalse(
            fetchedBalance.waitForExistence(timeout: 6),
            "the kid home must not recover on its own; only a real read may change what it shows"
        )
        XCTAssertTrue(banner.exists)

        let scrollView = app.scrollViews.firstMatch
        scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                withVelocity: .slow,
                thenHoldForDuration: 0.6
            )

        XCTAssertTrue(fetchedBalance.waitForExistence(timeout: 15), "pull-to-refresh must fetch and apply the latest wallet")
        XCTAssertFalse(banner.exists, "a successful pull-to-refresh clears the offline banner")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last updated")).firstMatch.exists,
            "the freshness label must state when the wallet was last updated"
        )
    }

    // Report 8.5: an expired session keeps the cached kid view with a quiet
    // note; the door renews the session, then asks for the PIN as usual.
    func testExpiredSessionKeepsKidHomeAndDoorRenewsSession() throws {
        let app = launch("expired")

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A parent needs to sign in again."].waitForExistence(timeout: 5))

        app.staticTexts["Comic book"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Activity detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your parent recorded that US$4.00 was used."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Legacy cached explanation with virtual dollars."].exists)
        app.buttons["Done"].tap()

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Sign in again"].waitForExistence(timeout: 5))
        app.buttons["Sign in with Apple"].tap()

        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 5))
    }

    // Report criterion 9: first-run setup stays parent-led, lands in the
    // Parent area with the first-actions handoff, and hands off to the kid
    // home.
    func testFirstRunSetupHandsOffToParentAreaThenKidHome() throws {
        let app = launch("first-run")

        let signIn = app.buttons["Sign in with Apple"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()

        let nicknameField = app.textFields["Child's nickname"]
        XCTAssertTrue(nicknameField.waitForExistence(timeout: 10))
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

        app.buttons["Show Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your wallet is ready!"].exists)
    }

    /// Regression guard: the first-run sign-in control must read as a plain
    /// sign-in, never as child/wallet setup - a parent adding a second
    /// device to an existing wallet is only signing in, not creating a
    /// child. Real child setup still happens later, in `SetupView`.
    func testWelcomeSignInButtonDoesNotImplyNewChildSetup() throws {
        let app = launch("first-run")

        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons["Set up your child's wallet"].exists,
            "the sign-in control must not read as child setup - a returning parent may just be adding a device"
        )
    }

    /// A wallet already on the signed-in Apple account is a deliberate choice
    /// before setup, and choosing the free local wallet still reaches setup.
    func testExistingWalletChoiceIsOfferedBeforeSetupAndCanBeDeclined() throws {
        let app = launch("first-run-existing-wallet")

        let title = app.staticTexts["existing-wallet-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["existing-wallet-accept-button"].exists)
        XCTAssertTrue(app.staticTexts["Nothing is lost"].exists)
        XCTAssertFalse(app.staticTexts["Set up your child's wallet"].exists, "setup must not sit behind the offer")

        app.buttons["existing-wallet-decline-button"].tap()

        XCTAssertTrue(app.staticTexts["Set up your child's wallet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["existing-wallet-title"].exists)
    }

    /// A check that could not complete never strands onboarding: setup is
    /// available and the account can be checked again.
    func testUncheckableAccountStillReachesLocalFirstSetupWithARetry() throws {
        let app = launch("first-run-check-unavailable")

        XCTAssertTrue(app.staticTexts["Set up your child's wallet"].waitForExistence(timeout: 10))
        let checkAgain = app.buttons["existing-wallet-check-again-button"]
        XCTAssertTrue(checkAgain.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "could not check whether")).count > 0,
            "the setup screen states plainly that the account could not be checked"
        )
        XCTAssertTrue(app.textFields["Child's nickname"].exists, "the free local wallet stays available")
    }
}

extension XCTestCase {
    /// Blocks until the Debug StoreKit proof surface has an answer, and returns
    /// the status it settled on.
    ///
    /// The latency of that answer is not ours to bound. A scheme's
    /// `StoreKitConfigurationFileReference` is an Xcode-IDE setting that
    /// `xcodebuild` ignores, so under CI the app resolves the *live* App Store
    /// sandbox catalog over the network: a bag fetch, a session handshake, and
    /// a catalog query against `amp-api.sandbox.apple.com`, all on the first
    /// product request on a cold device. That is why the eddies-wallet-v0.1.4
    /// tag run sat at "loading" for the whole 15-second window on a build whose
    /// products, prices, and configuration were correct - the same run's later
    /// tour resolved in about a second once the device cache was warm.
    ///
    /// So wait for the surface to reach *any* terminal status rather than
    /// racing Apple to a particular one. This hides nothing: a StoreKit error,
    /// a renamed product, or a partial result is terminal as soon as the store
    /// answers, so a genuine product-loading failure fails the caller at once
    /// and names the status the app actually showed instead of expiring into an
    /// opaque timeout that cannot tell "wrong" from "not yet".
    func terminalStoreKitDiagnosticsStatus(
        in app: XCUIApplication,
        timeout: TimeInterval = 120,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let status = app.staticTexts["storekit-diagnostics-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the diagnostics surface never rendered", file: file, line: line)

        let deadline = Date().addingTimeInterval(timeout)
        var label = status.label
        while label == "loading", Date() < deadline {
            usleep(250_000)
            label = status.label
        }
        XCTAssertNotEqual(
            label, "loading",
            "StoreKit never answered within \(Int(timeout))s; the surface is still loading",
            file: file,
            line: line
        )
        return label
    }
}

private struct RenderedPixels {
    struct Color {
        let red: Int
        let green: Int
        let blue: Int

        func maximumChannelDistance(to other: Color) -> Int {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(image: CGImage) {
        let imageWidth = image.width
        let imageHeight = image.height
        var storage = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        let rendered = storage.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: imageWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard rendered else { return nil }
        width = imageWidth
        height = imageHeight
        bytes = storage
    }

    func averageColor(around point: CGPoint, radius: CGFloat, pointSize: CGSize) -> Color {
        let scaleX = CGFloat(width) / pointSize.width
        let scaleY = CGFloat(height) / pointSize.height
        let centerX = Int(point.x * scaleX)
        let centerY = Int(point.y * scaleY)
        let radiusX = max(1, Int(radius * scaleX))
        let radiusY = max(1, Int(radius * scaleY))
        let xRange = max(0, centerX - radiusX)...min(width - 1, centerX + radiusX)
        let yRange = max(0, centerY - radiusY)...min(height - 1, centerY + radiusY)
        var red = 0
        var green = 0
        var blue = 0
        var count = 0

        for y in yRange {
            for x in xRange {
                let offset = (y * width + x) * 4
                red += Int(bytes[offset])
                green += Int(bytes[offset + 1])
                blue += Int(bytes[offset + 2])
                count += 1
            }
        }

        return Color(red: red / count, green: green / count, blue: blue / count)
    }
}
