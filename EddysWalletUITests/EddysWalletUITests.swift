import XCTest

/// End-to-end proof of the kid-first navigation model, driven through the
/// real app the way a person would tap it. Scenarios use the Debug-only
/// launch-environment seam with synthetic fixture data (nickname "Eddie",
/// PIN 1234) - no real accounts, families, or services.
final class EddysWalletUITests: XCTestCase {
    private let doorLabel = "Grown-ups area. Asks for the parent PIN."
    private let parentActionTitles = ["Add deposit", "Record withdrawal", "Create loan", "Record repayment", "Record allowance"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EW_UITEST_SCENARIO"] = scenario
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            app.buttons["PIN digit \(digit)"].tap()
        }
    }

    @discardableResult
    private func openParentArea(in app: XCUIApplication) -> XCUIElement {
        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Grown-ups only"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        let header = app.staticTexts["Parent area"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        return header
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
        XCTAssertFalse(app.buttons["Parent"].exists, "No peer role switch on the kid home")
        XCTAssertFalse(app.staticTexts["Parent area"].exists)
    }

    // Report criterion 3 (P4): wrong PIN stays gated; cancel returns to the
    // kid home with no parent data revealed.
    func testWrongPINStaysGatedAndCancelReturnsToKidHome() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Grown-ups only"].waitForExistence(timeout: 5))
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
            XCTAssertTrue(app.buttons[title].exists, "\(title) must exist inside the Parent area")
        }
        XCTAssertTrue(app.buttons["Sign out"].exists)
        XCTAssertTrue(app.buttons["Change PIN"].exists)

        app.buttons["Done. Back to Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add deposit"].exists)
    }

    // Report criterion 2 (P3): backgrounding drops elevation; foregrounding
    // shows the kid home again.
    func testBackgroundingDropsParentElevation() throws {
        let app = launch("configured")
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        openParentArea(in: app)

        XCUIDevice.shared.press(.home)
        sleep(1)
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
        XCTAssertTrue(app.staticTexts["Grown-ups only"].waitForExistence(timeout: 5))

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
        XCTAssertFalse(app.staticTexts["What's been happening"].exists)
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
    }

    // Report 8.5: an expired session keeps the cached kid view with a quiet
    // note; the door renews the session, then asks for the PIN as usual.
    func testExpiredSessionKeepsKidHomeAndDoorRenewsSession() throws {
        let app = launch("expired")

        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A grown-up needs to sign in again."].waitForExistence(timeout: 5))

        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Sign in again"].waitForExistence(timeout: 5))
        app.buttons["Sign in with Apple"].tap()

        XCTAssertTrue(app.staticTexts["Grown-ups only"].waitForExistence(timeout: 5))
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

        app.buttons["Create your child's wallet"].tap()

        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 5))

        app.buttons["Show Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your wallet is ready!"].exists)
    }
}
