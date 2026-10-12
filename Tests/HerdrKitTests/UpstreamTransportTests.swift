import XCTest
import Foundation
import Citadel
import NIOCore
@testable import HerdrKit

final class UpstreamTransportTests: XCTestCase {
    private func transport(_ bridge: ScriptedBridge) -> CitadelTransport {
        let credentials = SSHCredentials(host: "test", username: "tester", password: "unused", remoteSocketPath: "")
        let connection = SSHConnectionCore(credentials: credentials, hostKeyValidator: .acceptAnything(), connectTimeoutNanoseconds: 1)
        return CitadelTransport(credentials: credentials, connection: connection,
            backend: ExecBackend(execute: { _ in XCTFail("Stock API must use stdin"); throw ScriptedDrop() },
                                 openLink: { command in
                                     XCTAssertTrue(command.contains("remote-api-bridge"))
                                     XCTAssertFalse(command.contains("--multi"))
                                     XCTAssertFalse(command.contains("method"))
                                     return bridge
                                 }), bridgeMode: .upstream)
    }

    func testStockRequestWrittenOnceToStdin() async throws {
        let bridge = ScriptedBridge(responder: ScriptedBridge.answerAll)
        let request = #"{"id":"one","method":"agent.list","params":{}}"#
        let client = transport(bridge)
        let response = try await client.roundTrip(request)
        XCTAssertEqual(RequestChannel.responseID(response), "one")
        XCTAssertEqual(bridge.requests, [request])
        await client.close()
    }

    func testSubscriptionKeepsInputAliveForEvents() async throws {
        let bridge = ScriptedBridge(responder: { _ in #"{"id":"events","result":{"type":"subscription_started"}}"# })
        let request = #"{"id":"events","method":"events.subscribe","params":{}}"#
        let client = transport(bridge)
        let stream = client.stream(request)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        XCTAssertFalse(bridge.stdinClosed)
        bridge.emit(#"{"event":"status_changed"}"#)
        let event = try await iterator.next()
        XCTAssertEqual(event, #"{"event":"status_changed"}"#)
        bridge.exit(code: 0)
        _ = try await iterator.next()
        await client.close()
    }

    func testFrameDecodesANSIAndGeometry() throws {
        let event = try UpstreamTerminalSession.decode(#"{"type":"terminal.frame","seq":7,"encoding":"ansi","width":100,"height":30,"full":true,"bytes":"G1tISGk="}"#)
        guard case .frame(let frame) = event else { return XCTFail("Expected frame") }
        XCTAssertEqual(frame.bytes, Data([27, 91, 72, 72, 105]))
        XCTAssertEqual(frame.width, 100)
        XCTAssertEqual(frame.height, 30)
        XCTAssertEqual(frame.seq, 7)
        XCTAssertTrue(frame.full)
    }

    func testMalformedFrameAndInvalidGeometryFail() throws {
        XCTAssertThrowsError(try UpstreamTerminalSession.decode(#"{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"!!"}"#))
        XCTAssertThrowsError(try UpstreamTerminalSession.validateSize(cols: 0, rows: 24))
        XCTAssertThrowsError(try UpstreamTerminalSession.validateSize(cols: 80, rows: 65536))
    }

    func testStockTerminalCommandTargetPrecedesOptions() {
        let command = CitadelTransport.terminalSessionCommand(target: "w4:p1", cols: 100, rows: 30, observe: false, session: "named")
        XCTAssertTrue(command.contains("--session named terminal session control w4:p1 --cols 100 --rows 30"))
        XCTAssertFalse(command.contains("--takeover"))
    }

    func testObserverCannotWrite() async throws {
        let channel = UpstreamJSONChannel(host: "test")
        let session = UpstreamTerminalSession(channel: channel, observe: true)
        do { try await session.sendInput(Data([13])); XCTFail("Observer accepted input") }
        catch { XCTAssertEqual(error as? UpstreamProtocolError, .readOnly) }
        await session.close()
    }

    func testFragmentedUTF8Preserved() async throws {
        let channel = UpstreamJSONChannel(host: "test")
        let link = FragmentedUpstreamLink()
        try await channel.start(link: link)
        var iterator = channel.lines.makeAsyncIterator()
        let result = try await iterator.next()
        XCTAssertEqual(result, "{\"name\":\"🐑\"}")
        await channel.close()
    }
}

private struct FragmentedUpstreamLink: RequestChannelLink {
    func run(stdin: AsyncStream<ByteBuffer>, onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void) async throws {
        let bytes = Array("{\"name\":\"🐑\"}\n".utf8)
        for byte in bytes {
            var buffer = ByteBufferAllocator().buffer(capacity: 1)
            buffer.writeInteger(byte)
            await onOutput(.stdout(buffer))
        }
    }
}
