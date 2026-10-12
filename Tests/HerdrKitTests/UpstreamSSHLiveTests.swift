import Foundation
import XCTest
@testable import HerdrKit

/// Opt-in only: the launcher must provide a fresh daemon and SSH server whose
/// forced command isolates Herdr config/state/socket. Never auto-discovers :22.
final class UpstreamSSHLiveTests: XCTestCase {
    func testIsolatedStockSSHBridgeAndTerminal() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HERDR_UPSTREAM_ISOLATED_TEST"] == "1",
              let keyPath = env["HERDR_UPSTREAM_TEST_KEY"],
              let portString = env["HERDR_UPSTREAM_TEST_PORT"], let port = UInt16(portString),
              let user = env["HERDR_UPSTREAM_TEST_USER"],
              let target = env["HERDR_UPSTREAM_TEST_TERMINAL"],
              let pane = env["HERDR_UPSTREAM_TEST_PANE"] else {
            throw XCTSkip("Requires an explicitly isolated stock daemon and loopback SSH fixture")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let credentials = SSHCredentials(host: "127.0.0.1", port: port, username: user, privateKeyPEM: key, remoteSocketPath: "")
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: PinningHostKeyPolicy(store: .init()))
        do {
            let reply = try await transport.roundTrip(#"{"id":"stock-live","method":"ping","params":{}}"#)
            XCTAssertTrue(reply.contains("pong"))
            XCTAssertTrue(reply.contains("stock-live"))

            // Read acknowledgment, deliver a synthetic status event in the isolated pane,
            // then observe it over the retained subscription channel.
            let subscription = #"{"id":"stock-events","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":"\#(pane)"}]}}"#
            let eventTask = Task {
                var iterator = transport.stream(subscription).makeAsyncIterator()
                let acknowledgment = try await iterator.next()
                XCTAssertTrue(acknowledgment?.contains("subscription_started") == true)
                _ = try await transport.roundTrip(#"{"id":"stock-report","method":"pane.report_agent","params":{"pane_id":"\#(pane)","source":"custom:swift-test","agent":"swift-test","state":"working"}}"#)
                let event = try await iterator.next()
                XCTAssertTrue(event?.contains("pane.agent_status_changed") == true)
            }
            try await eventTask.value

            let terminal = try await transport.openTerminal(target: target, cols: 80, rows: 24)
            var iterator = terminal.events.makeAsyncIterator()
            guard case .frame(let first)? = try await iterator.next() else { return XCTFail("No terminal baseline") }
            XCTAssertTrue(first.full)
            try await terminal.sendInput(Data("printf 'SWIFT_%s\\n' VERIFIED\r".utf8))
            var found = false
            for _ in 0..<30 {
                guard let event = try await iterator.next() else { break }
                if case .frame(let frame) = event,
                   String(decoding: frame.bytes, as: UTF8.self).contains("SWIFT_VERIFIED") {
                    found = true
                    break
                }
            }
            XCTAssertTrue(found, "Input sent through Citadel must reach the isolated PTY")
            try await terminal.resize(cols: 100, rows: 30)
            var resized = false
            for _ in 0..<30 {
                guard let event = try await iterator.next() else { break }
                if case .frame(let frame) = event, frame.width == 100, frame.height == 30 {
                    resized = true
                    break
                }
            }
            XCTAssertTrue(resized)
            await terminal.close()
            let reconnected = try await transport.openTerminal(target: target, cols: 100, rows: 30)
            var reconnectIterator = reconnected.events.makeAsyncIterator()
            guard case .frame(let restored)? = try await reconnectIterator.next() else { return XCTFail("No reconnect baseline") }
            XCTAssertTrue(restored.full)
            XCTAssertTrue(String(decoding: restored.bytes, as: UTF8.self).contains("SWIFT_VERIFIED"))
            await reconnected.close()
            await transport.close()
        } catch {
            await transport.close()
            throw error
        }
    }
}
