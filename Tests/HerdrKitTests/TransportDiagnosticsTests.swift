import Foundation
import XCTest
@testable import HerdrKit

final class TransportDiagnosticsTests: XCTestCase {
    func testLocalizedConnectionErrorIncludesActionableHostDiagnostic() {
        let error: Error = TransportError.herdrIncompatible(host: "workstation")
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("workstation"))
        XCTAssertTrue(message.contains("Update Herdr"))
        XCTAssertTrue(message.contains("reconnect"))
        XCTAssertFalse(message.contains("fork"))
    }

    func testLocalizedBridgeErrorPreservesTerminalDiagnostic() {
        let error: Error = TransportError.bridgeFailed(stderr: "terminal is already controlled")
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("terminal is already controlled"))
        XCTAssertFalse(message.contains("api-bridge"))
        let noDiagnostic: Error = TransportError.bridgeFailed(stderr: "")
        XCTAssertTrue(noDiagnostic.localizedDescription.contains("daemon is running"))
    }
}
