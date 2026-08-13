import XCTest
@testable import EddysWallet

#if DEBUG
@MainActor
final class DebugLaunchScenarioTests: XCTestCase {
    func testNoPriceCloudPlansScenarioExposesPlansWithoutStoreKitPrices() throws {
        let store = try XCTUnwrap(
            DebugLaunchScenario.makeStore(environment: ["EW_UITEST_SCENARIO": "cloud-plans-no-price"])
        )

        XCTAssertEqual(store.cloudPlans.count, 2)
        XCTAssertTrue(store.canOfferCloudPlans)
        XCTAssertEqual(
            store.cloudPlans.map(\.id),
            [
                "com.kunchenguid.eddieswallet.cloud.monthly",
                "com.kunchenguid.eddieswallet.cloud.annual"
            ]
        )
        XCTAssertEqual(store.cloudPlans.map(\.displayName), ["Cloud monthly", "Cloud annual"])
        XCTAssertEqual(store.cloudPlans.map(\.displayPrice), ["", ""])
        XCTAssertEqual(store.cloudPlans.map(\.periodDescription), ["every month", "every year"])
        for plan in store.cloudPlans {
            XCTAssertFalse(plan.displayPrice.contains("$"))
            XCTAssertFalse(plan.displayPrice.contains("2.99"))
            XCTAssertFalse(plan.displayPrice.contains("24.99"))
        }
    }

    func testPricedCloudPlansScenarioStillInjectsStoreKitShapedPrices() throws {
        let store = try XCTUnwrap(
            DebugLaunchScenario.makeStore(environment: ["EW_UITEST_SCENARIO": "cloud-plans-available"])
        )

        XCTAssertEqual(store.cloudPlans.map(\.displayPrice), ["$2.99", "$24.99"])
        XCTAssertEqual(store.cloudPlans.map(\.periodDescription), ["every month", "every year"])
    }
}
#endif
