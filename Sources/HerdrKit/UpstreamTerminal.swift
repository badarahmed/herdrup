import Foundation
import Citadel
import NIOCore

public protocol UpstreamTerminalTransport: HerdrTransport {
    func openTerminal(target: String, cols: Int, rows: Int, observe: Bool) async throws -> UpstreamTerminalSession
}

public enum UpstreamScrollDirection: String, Sendable { case up, down }

/// A rendered ANSI viewport. Sequence numbers are frame identities, never PTY offsets.
public struct UpstreamTerminalFrame: Sendable {
    public let seq: UInt64
    public let width: Int
    public let height: Int
    public let full: Bool
    public let bytes: Data
}

public enum UpstreamTerminalEvent: Sendable {
    case frame(UpstreamTerminalFrame)
    case closed(reason: String)
}

public enum UpstreamProtocolError: Error, LocalizedError, Sendable, Equatable {
    case invalidMessage, oversizedLine, invalidTarget, invalidSize, readOnly, closed
    public var errorDescription: String? {
        switch self {
        case .invalidMessage: return "The host sent an invalid terminal message."
        case .oversizedLine: return "The host response exceeded the safe size limit."
        case .invalidTarget: return "Invalid terminal target."
        case .invalidSize: return "Terminal dimensions must be between 1 and 65535."
        case .readOnly: return "This terminal is a read-only observer."
        case .closed: return "The terminal connection is closed."
        }
    }
}

/// Owns one stock duplex exec channel. No retries, byte resume, leases or idle timeout.
public actor UpstreamTerminalSession {
    public nonisolated let events: AsyncThrowingStream<UpstreamTerminalEvent, Error>
    private let output: AsyncThrowingStream<UpstreamTerminalEvent, Error>.Continuation
    private let channel: UpstreamJSONChannel
    private let observe: Bool
    private var task: Task<Void, Never>?
    private var closed = false

    init(channel: UpstreamJSONChannel, observe: Bool) {
        self.channel = channel
        self.observe = observe
        let pair = AsyncThrowingStream<UpstreamTerminalEvent, Error>.makeStream()
        events = pair.stream
        output = pair.continuation
    }

    func start() {
        let channel = channel
        let output = output
        task = Task {
            do {
                var hasFullFrame = false
                for try await line in channel.lines {
                    let event = try Self.decode(line)
                    if case .frame(let frame) = event {
                        guard hasFullFrame || frame.full else { throw UpstreamProtocolError.invalidMessage }
                        hasFullFrame = hasFullFrame || frame.full
                    }
                    output.yield(event)
                    if case .closed = event { break }
                }
                output.finish()
            } catch { output.finish(throwing: error) }
            await channel.stop()
        }
        output.onTermination = { [weak self] _ in Task { await self?.close() } }
    }

    public func sendInput(_ bytes: Data) async throws {
        try await send(["type": "terminal.input", "bytes": bytes.base64EncodedString()])
    }

    public func resize(cols: Int, rows: Int) async throws {
        try Self.validateSize(cols: cols, rows: rows)
        try await send(["type": "terminal.resize", "cols": cols, "rows": rows])
    }

    public func scroll(direction: UpstreamScrollDirection, lines: Int) async throws {
        guard (1...65535).contains(lines) else { throw UpstreamProtocolError.invalidSize }
        try await send(["type": "terminal.scroll", "direction": direction.rawValue, "lines": lines])
    }

    private func send(_ value: [String: Any]) async throws {
        guard !closed else { throw UpstreamProtocolError.closed }
        guard !observe else { throw UpstreamProtocolError.readOnly }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try await channel.send(String(decoding: data, as: UTF8.self))
    }

    public func close() async {
        guard !closed else { await channel.stop(); return }
        closed = true
        // EOF releases controller ownership; it does not close the pane.
        await channel.stop()
        task?.cancel()
        task = nil
        output.finish()
    }

    static func validateSize(cols: Int, rows: Int) throws {
        guard (1...65535).contains(cols), (1...65535).contains(rows) else {
            throw UpstreamProtocolError.invalidSize
        }
    }

    static func decode(_ line: String) throws -> UpstreamTerminalEvent {
        struct Message: Decodable {
            let type: String
            let seq: UInt64?
            let encoding: String?
            let width: Int?
            let height: Int?
            let full: Bool?
            let bytes: String?
            let reason: String?
        }
        let message = try JSONDecoder().decode(Message.self, from: Data(line.utf8))
        if message.type == "terminal.closed" { return .closed(reason: message.reason ?? "Terminal closed") }
        guard message.type == "terminal.frame", message.encoding == "ansi",
              let seq = message.seq, let width = message.width, let height = message.height,
              let full = message.full, let encoded = message.bytes,
              let bytes = Data(base64Encoded: encoded) else { throw UpstreamProtocolError.invalidMessage }
        try validateSize(cols: width, rows: height)
        return .frame(UpstreamTerminalFrame(seq: seq, width: width, height: height, full: full, bytes: bytes))
    }
}
