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
        app.buttons[doorLabel].tap()
        XCTAssertTrue(app.staticTexts["Parent only"].waitForExistence(timeout: 5))
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

        // Welcome / onboarding keeps the honest external brand wordmark.
        let plain = XCUIApplication()
        plain.launch()
        XCTAssertTrue(plain.staticTexts["Eddie's Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(plain.descendants(matching: .any)["product-brand-wordmark"].exists)
        XCTAssertTrue(plain.staticTexts["Virtual practice only"].exists)
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

        app.buttons["Create your child's wallet"].tap()

        XCTAssertTrue(app.staticTexts["Parent area"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 5))

        app.buttons["Show Eddie's wallet"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Eddie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your wallet is ready!"].exists)
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
