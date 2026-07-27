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
}
