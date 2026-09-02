import Foundation
import XCTest
@testable import EddysWallet

/// Guards the App Store Connect distribution metadata that a TestFlight
/// upload validates: every built app bundle must carry the registered bundle
/// identifier, deterministic numeric versions, and the exempt-encryption
/// declaration. `.github/workflows/release.yml` overrides the versions per
/// release tag; these tests prove the project defaults are already valid so
/// a local Release archive is never missing required keys.
final class ReleaseMetadataTests: XCTestCase {
    private var appInfo: [String: Any] {
        guard let bundle = Bundle(identifier: AppleAppIdentity.bundleIdentifier),
              let info = bundle.infoDictionary else {
            XCTFail("Host app bundle \(AppleAppIdentity.bundleIdentifier) is not loaded")
            return [:]
        }
        return info
    }

    private func assertNumericVersion(_ value: String?, key: String, components: ClosedRange<Int>) {
        guard let value else {
            XCTFail("\(key) is missing from the built app Info.plist")
            return
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertTrue(
            components.contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
            "\(key) '\(value)' must be \(components.lowerBound)-\(components.upperBound) dot-separated integers"
        )
    }

    func testBuiltAppDeclaresDeterministicMarketingVersion() {
        assertNumericVersion(appInfo["CFBundleShortVersionString"] as? String, key: "CFBundleShortVersionString", components: 2...3)
    }

    func testBuiltAppDeclaresNumericBuildVersion() {
        assertNumericVersion(appInfo["CFBundleVersion"] as? String, key: "CFBundleVersion", components: 1...3)
    }

    func testBuiltAppDeclaresExemptEncryption() {
        guard let uses = appInfo["ITSAppUsesNonExemptEncryption"] as? Bool else {
            XCTFail("ITSAppUsesNonExemptEncryption is missing from the built app Info.plist")
            return
        }
        XCTAssertFalse(uses, "The app must declare it uses only exempt encryption")
    }

    /// The StoreKit test configuration must never ship inside the app bundle.
    /// The shared Debug/Test scheme still selects it from its source path.
    func testStoreKitTestConfigurationIsNotBundledWithTheApp() throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: AppleAppIdentity.bundleIdentifier))
        XCTAssertNil(appBundle.url(forResource: "EddysWallet", withExtension: "storekit"))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: appBundle.bundlePath)
                .allSatisfy { !$0.hasSuffix(".storekit") },
            "no StoreKit configuration resource may be present in the built app bundle"
        )
    }

    /// The privacy manifest must ship at the app bundle root so App Store
    /// Connect can ingest it. Assertions are against the parsed plist the
    /// store consumes, not the source file on disk.
    func testBuiltAppBundlesPrivacyManifestAtRoot() throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: AppleAppIdentity.bundleIdentifier))
        let url = try XCTUnwrap(
            appBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy must land at the built app bundle root"
        )
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            URL(fileURLWithPath: appBundle.bundlePath, isDirectory: true).standardizedFileURL
        )

        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
            "PrivacyInfo.xcprivacy must be a dictionary plist"
        )
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)

        let apiTypes = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apiTypes.count, 1)
        XCTAssertEqual(apiTypes[0]["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(apiTypes[0]["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])

        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(
            Set(types),
            [
                "NSPrivacyCollectedDataTypeUserID",
                "NSPrivacyCollectedDataTypeEmailAddress",
                "NSPrivacyCollectedDataTypeName",
                "NSPrivacyCollectedDataTypeOtherUserContent",
                "NSPrivacyCollectedDataTypePurchaseHistory",
            ]
        )
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, "\(entry["NSPrivacyCollectedDataType"] ?? "?") must be linked")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, "\(entry["NSPrivacyCollectedDataType"] ?? "?") must not be used for tracking")
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }
    }
}
