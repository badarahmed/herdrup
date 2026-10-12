import Foundation
import Citadel
import NIOCore

/// A bounded line decoder and owned duplex channel for stock CLI commands.
actor UpstreamJSONChannel {
    nonisolated let lines: AsyncThrowingStream<String, Error>
    private let output: AsyncThrowingStream<String, Error>.Continuation
    private let input: AsyncStream<ByteBuffer>.Continuation
    private let stdin: AsyncStream<ByteBuffer>
    private let host: String
    private var runner: Task<Void, Never>?
    private var closingRunner: Task<Void, Never>?
    private var pending = Data()
    private var stderr = ""
    private var closed = false
    static let maxLineBytes = 32 * 1024 * 1024

    init(host: String) {
        self.host = host
        let outbound = AsyncStream<ByteBuffer>.makeStream()
        stdin = outbound.stream
        input = outbound.continuation
        let inbound = AsyncThrowingStream<String, Error>.makeStream()
        lines = inbound.stream
        output = inbound.continuation
    }

    func start(link: RequestChannelLink, request: String? = nil) throws {
        if let request { try send(request) }
        let stdin = stdin
        runner = Task {
            do {
                try await link.run(stdin: stdin) { chunk in await self.receive(chunk) }
                self.ended(nil)
            } catch { self.ended(error) }
        }
        output.onTermination = { [weak self] _ in Task { await self?.close() } }
    }

    func send(_ line: String) throws {
        guard !closed else { throw UpstreamProtocolError.closed }
        guard line.utf8.count <= Self.maxLineBytes else { throw UpstreamProtocolError.oversizedLine }
        guard !line.contains("\n"), !line.contains("\r") else { throw UpstreamProtocolError.invalidMessage }
        var buffer = ByteBufferAllocator().buffer(capacity: line.utf8.count + 1)
        buffer.writeString(line)
        buffer.writeInteger(UInt8(10))
        input.yield(buffer)
    }

    private func receive(_ chunk: ExecCommandOutput) {
        guard !closed else { return }
        switch chunk {
        case .stderr(let bytes):
            if stderr.utf8.count < 64 * 1024 { stderr += String(buffer: bytes) }
        case .stdout(let bytes):
            var remaining = bytes.readableBytesView[...]
            while !remaining.isEmpty {
                let newline = remaining.firstIndex(of: 10)
                let segment = newline.map { remaining[..<$0] } ?? remaining[...]
                guard segment.count <= Self.maxLineBytes - pending.count else {
                    output.finish(throwing: UpstreamProtocolError.oversizedLine)
                    close()
                    return
                }
                pending.append(contentsOf: segment)
                guard let newline else { break }
                let line = String(decoding: pending, as: UTF8.self)
                pending.removeAll(keepingCapacity: true)
                if let error = CitadelTransport.daemonSocketFailure(in: line, host: host) {
                    output.finish(throwing: error)
                    close()
                    return
                }
                output.yield(line)
                remaining = remaining[remaining.index(after: newline)...]
            }
        }
    }

    private func ended(_ error: Error?) {
        guard !closed else { return }
        if !pending.isEmpty { output.yield(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        if let error { output.finish(throwing: RequestChannel.endFailure(error, stderr: stderr, host: host)) }
        else if !stderr.isEmpty { output.finish(throwing: RequestChannel.endFailure(nil, stderr: stderr, host: host)) }
        else { output.finish() }
        close()
    }

    /// External teardown awaits channel ownership release before a new controller opens.
    func stop() async {
        let running = runner ?? closingRunner
        close()
        await running?.value
    }

    func close() {
        guard !closed else { return }
        closed = true
        input.finish()
        closingRunner = runner
        runner?.cancel()
        runner = nil
        output.finish()
    }
}
