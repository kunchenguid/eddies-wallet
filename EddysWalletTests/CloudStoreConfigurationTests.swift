import Foundation
import XCTest
@testable import EddysWallet

/// Guards the Cloud subscription contract that the App Store Connect products
/// were configured against. `docs/app-store-configuration.md` records the live
/// store state; these tests prove the checked-in StoreKit configuration and the
/// runtime product identifiers still agree with it.
///
/// A price edit, an added free trial, or a Family Sharing flip that lands here
/// without the matching App Store Connect change is a drift bug: local StoreKit
/// testing would then exercise a product the store does not sell.
final class CloudStoreConfigurationTests: XCTestCase {
    private static let expectedGroupName = "Cloud"
    private static let expectedDescription = "Cloud backup and sync for one parent household."

    private struct Expected {
        let productID: String
        let referenceName: String
        let period: String
        let displayPrice: String
    }

    private static let expectedProducts = [
        Expected(
            productID: CloudProductID.monthly,
            referenceName: "Cloud monthly",
            period: "P1M",
            displayPrice: "2.99"
        ),
        Expected(
            productID: CloudProductID.annual,
            referenceName: "Cloud annual",
            period: "P1Y",
            displayPrice: "24.99"
        ),
    ]

    // MARK: - Runtime identifiers

    func testRuntimeProductIdentifiersMatchTheConfiguredStoreProducts() {
        XCTAssertEqual(CloudProductID.monthly, "com.kunchenguid.eddieswallet.cloud.monthly")
        XCTAssertEqual(CloudProductID.annual, "com.kunchenguid.eddieswallet.cloud.annual")
        XCTAssertEqual(CloudProductID.all, [CloudProductID.monthly, CloudProductID.annual])
        XCTAssertEqual(CloudProductID.all.count, 2, "Exactly two Cloud products are configured in App Store Connect")
    }

    func testProductIdentifiersAreScopedToTheAppBundle() {
        for product in Self.expectedProducts {
            XCTAssertTrue(
                product.productID.hasPrefix(AppleAppIdentity.bundleIdentifier + "."),
                "\(product.productID) must live under the registered bundle identifier"
            )
        }
    }

    // MARK: - StoreKit configuration

    private func loadStoreKitConfiguration() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EddysWallet/Configuration/EddysWallet.storekit")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("EddysWallet.storekit is not a JSON object")
            return [:]
        }
        return root
    }

    private func subscriptions(in root: [String: Any]) -> [[String: Any]] {
        let groups = root["subscriptionGroups"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 1, "Exactly one Cloud subscription group is configured")
        guard let group = groups.first else { return [] }
        XCTAssertEqual(group["name"] as? String, Self.expectedGroupName)
        return group["subscriptions"] as? [[String: Any]] ?? []
    }

    func testConfigurationDeclaresOnlyTheTwoCloudSubscriptions() throws {
        let root = try loadStoreKitConfiguration()

        XCTAssertEqual(
            (root["products"] as? [Any])?.count ?? 0, 0,
            "No non-subscription in-app purchase is configured for this app"
        )
        XCTAssertEqual(
            (root["nonRenewingSubscriptions"] as? [Any])?.count ?? 0, 0,
            "No non-renewing subscription is configured for this app"
        )

        let subscriptions = subscriptions(in: root)
        XCTAssertEqual(subscriptions.count, 2)
        XCTAssertEqual(
            Set(subscriptions.compactMap { $0["productID"] as? String }),
            CloudProductID.all,
            "The checked-in StoreKit products must be exactly the runtime product identifiers"
        )
    }

    func testEachSubscriptionMatchesTheAcceptedPriceAndPeriod() throws {
        let subscriptions = subscriptions(in: try loadStoreKitConfiguration())

        for expected in Self.expectedProducts {
            guard let subscription = subscriptions.first(where: { $0["productID"] as? String == expected.productID }) else {
                XCTFail("\(expected.productID) is missing from the bundled StoreKit configuration")
                continue
            }
            XCTAssertEqual(subscription["type"] as? String, "RecurringSubscription", "\(expected.productID) type")
            XCTAssertEqual(subscription["recurringSubscriptionPeriod"] as? String, expected.period, "\(expected.productID) period")
            XCTAssertEqual(subscription["displayPrice"] as? String, expected.displayPrice, "\(expected.productID) price")
            XCTAssertEqual(subscription["referenceName"] as? String, expected.referenceName, "\(expected.productID) reference name")

            let localizations = subscription["localizations"] as? [[String: Any]] ?? []
            XCTAssertEqual(localizations.count, 1, "\(expected.productID) has one localization")
            XCTAssertEqual(localizations.first?["displayName"] as? String, expected.referenceName)
            XCTAssertEqual(
                localizations.first?["description"] as? String, Self.expectedDescription,
                "\(expected.productID) description must match the App Store product description"
            )
        }
    }

    func testNoSubscriptionOffersFamilySharing() throws {
        let subscriptions = subscriptions(in: try loadStoreKitConfiguration())

        for subscription in subscriptions {
            let productID = subscription["productID"] as? String ?? "unknown"
            XCTAssertEqual(
                subscription["familyShareable"] as? Bool, false,
                "\(productID) must not be Family Shareable; the Cloud plan is one parent household"
            )
        }
    }

    // MARK: - Debug proof surface

    #if DEBUG
    /// Regression coverage for the eddies-wallet-v0.1.4 tag CI failure. Resolving
    /// products can take an unbounded first call - under `xcodebuild` it is a
    /// live App Store round trip - and that run sat at "loading" for the whole
    /// window, reported as a product failure on a build whose products were fine.
    ///
    /// The surface stays trustworthy only while "not answered yet" is impossible
    /// to confuse with any answer, so a test can wait out a slow store without
    /// ever waiting out a broken one.
    func testDiagnosticsLoadingIsDistinctFromEveryTerminalVerdict() {
        let terminal: [CloudDiagnosticsStatus] = [
            .loaded(count: 2),
            .loaded(count: 0),
            .missingProducts(found: 1),
            .storeKitError,
        ]

        XCTAssertFalse(CloudDiagnosticsStatus.loading.isTerminal)
        for status in terminal {
            XCTAssertTrue(status.isTerminal, "\(status.label) is an answer, not a pending load")
            XCTAssertNotEqual(
                status.label, CloudDiagnosticsStatus.loading.label,
                "a terminal verdict must never render as the pending label"
            )
        }
    }

    /// The exact strings the UI proof test judges. A silent copy edit here would
    /// otherwise turn into a UI test that waits for a label that never appears.
    func testDiagnosticsStatusLabelsAreTheExactStringsTheProofTestReads() {
        XCTAssertEqual(CloudDiagnosticsStatus.loading.label, "loading")
        XCTAssertEqual(
            CloudDiagnosticsStatus.loaded(count: CloudProductID.ordered.count).label,
            "loaded 2 products",
            "the success label must name both configured Cloud products"
        )
        XCTAssertEqual(CloudDiagnosticsStatus.missingProducts(found: 1).label, "missing products (1)")
        XCTAssertEqual(CloudDiagnosticsStatus.storeKitError.label, "storekit error")
    }
    #endif

    func testNoSubscriptionOffersAFreeTrialOrIntroductoryOffer() throws {
        let subscriptions = subscriptions(in: try loadStoreKitConfiguration())

        for subscription in subscriptions {
            let productID = subscription["productID"] as? String ?? "unknown"
            XCTAssertNil(
                subscription["introductoryOffer"],
                "\(productID) must not declare an introductory offer; App Store Connect has none"
            )
            XCTAssertEqual(
                (subscription["promotionalOffers"] as? [Any])?.count ?? 0, 0,
                "\(productID) must not declare promotional offers; App Store Connect has none"
            )
            XCTAssertEqual(
                (subscription["offerCodes"] as? [Any])?.count ?? 0, 0,
                "\(productID) must not declare offer codes; App Store Connect has none"
            )
            XCTAssertEqual(
                (subscription["winBackOffers"] as? [Any])?.count ?? 0, 0,
                "\(productID) must not declare win-back offers; App Store Connect has none"
            )
        }
    }
}
