import XCTest
import Foundation
import Sparkle
@testable import Blackbird

/// Blind behaviour tests for `SparkleAlertOverride.isOnLatestVersion(_:)`.
///
/// Sparkle reports "no update found" for several distinct reasons via
/// `SPUNoUpdateFoundReasonKey` in the error's userInfo. Only ONE of them —
/// `.onLatestVersion` — means the user is genuinely current. The others
/// (OS too old / too new, running a build newer than the appcast, Intel
/// hardware without ARM64 support) describe an update the user CAN'T take,
/// and must not be rewritten into the reassuring "you're up to date" alert.
///
/// Memory + time pre-flight: a handful of NSError allocations per test —
/// < 32 KB, < 1 ms. No Sparkle UI, no network, no swizzle installed.
@MainActor
final class SparkleOnLatestVersionBlindTests: XCTestCase {

    private func error(userInfo: [String: Any]) -> Error {
        NSError(domain: "SUSparkleErrorDomain", code: 1001, userInfo: userInfo)
    }

    private func error(reason: SPUNoUpdateFoundReason) -> Error {
        error(userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
    }

    func testOnLatestVersionIsTrue() {
        XCTAssertTrue(SparkleAlertOverride.isOnLatestVersion(error(reason: .onLatestVersion)))
    }

    func testOnLatestVersionAsPlainIntIsTrue() {
        let e = error(userInfo: [SPUNoUpdateFoundReasonKey: Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
        XCTAssertTrue(SparkleAlertOverride.isOnLatestVersion(e),
                      "an Int-bridged reason value must be recognised as well as an NSNumber")
    }

    func testSystemIsTooOldIsFalse() {
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(error(reason: .systemIsTooOld)))
    }

    func testSystemIsTooNewIsFalse() {
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(error(reason: .systemIsTooNew)))
    }

    func testOnNewerThanLatestVersionIsFalse() {
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(error(reason: .onNewerThanLatestVersion)))
    }

    func testHardwareDoesNotSupportARM64IsFalse() {
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(error(reason: .hardwareDoesNotSupportARM64)))
    }

    func testUnknownReasonIsFalse() {
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(error(reason: .unknown)))
    }

    func testMissingReasonKeyIsFalse() {
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(error(userInfo: [:])),
                       "no reason ⇒ we cannot claim the user is current")
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(
            error(userInfo: [NSLocalizedDescriptionKey: "No update found"])))
    }

    func testStringReasonValueIsFalse() {
        let e = error(userInfo: [SPUNoUpdateFoundReasonKey: "\(SPUNoUpdateFoundReason.onLatestVersion.rawValue)"])
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(e),
                       "a string-typed reason must not be coerced into a match")
    }

    func testNonNSErrorSwiftErrorIsFalse() {
        struct Plain: Error {}
        XCTAssertFalse(SparkleAlertOverride.isOnLatestVersion(Plain()))
    }
}
