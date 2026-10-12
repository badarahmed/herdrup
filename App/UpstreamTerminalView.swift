#if canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm
import HerdrKit

/// Stock Herder's controller sends rendered ANSI viewports, not a PTY byte log.
/// History and geometry therefore belong to the controller, not local scrollback.
struct UpstreamTerminalView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection: UpstreamTerminalConnection
    private let fontSize: CGFloat

    init(client: HerdrClient, paneID: String, fontSize: CGFloat = 14) {
        _connection = StateObject(wrappedValue: UpstreamTerminalConnection(client: client, paneID: paneID))
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(connection.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(connection.status).font(.caption).lineLimit(2)
                Spacer()
                if !connection.connected {
                    Button("Reconnect") { connection.restart() }
                        .disabled(connection.connecting)
                }
                Button { connection.terminal?.becomeFirstResponder() } label: {
                    Image(systemName: "keyboard")
                }.accessibilityLabel("Type in terminal")
                Button { connection.terminal?.resignFirstResponder() } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }.accessibilityLabel("Dismiss keyboard")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            UpstreamTerminalSurface(connection: connection, fontSize: fontSize)
                .accessibilityIdentifier("upstreamTerminal")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    Button("History ↑") { connection.scroll(.up, lines: 12) }
                    Button("History ↓") { connection.scroll(.down, lines: 12) }
                    Button("Latest") { connection.scroll(.down, lines: 65535) }
                    Divider().frame(height: 20)
                    key("Esc", "\u{1b}")
                    key("Tab", "\t")
                    key("Ctrl-C", "\u{03}")
                    key("↑", "\u{1b}[A")
                    key("↓", "\u{1b}[B")
                    key("←", "\u{1b}[D")
                    key("→", "\u{1b}[C")
                    key("Enter", "\r")
                }.padding(12)
            }
            .disabled(!connection.connected)
            .background(.bar)
        }
        .onAppear { if scenePhase == .active { connection.start() } }
        .onDisappear { connection.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.start() } else { connection.stop() }
        }
    }

    private func key(_ label: String, _ bytes: String) -> some View {
        Button(label) { connection.input(Data(bytes.utf8)) }
            .font(.system(.callout, design: .monospaced))
    }
}

@MainActor
private final class UpstreamTerminalConnection: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "Connecting…"
    weak var terminal: TerminalView?
    private let client: HerdrClient
    private let paneID: String
    private var session: UpstreamTerminalSession?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var releasing: Task<Void, Never>?
    private var active = false
    private var generation = 0
    private var cols = 80
    private var rows = 24
    private var sentGrid: (cols: Int, rows: Int)?
    private var hasBaseline = false
    private var lastSequence: UInt64?

    init(client: HerdrClient, paneID: String) {
        self.client = client
        self.paneID = paneID
    }

    func start() {
        active = true
        guard reader == nil else { return }
        generation += 1
        let current = generation
        let released = releasing
        reader = Task { [weak self] in
            guard let self else { return }
            // A fast background/foreground or retry must finish releasing the
            // previous controller before trying to acquire a new one.
            await released?.value
            defer {
                if self.generation == current { self.reader = nil; self.connecting = false }
            }
            var reconnectDelay: UInt64 = 1
            while self.active && !Task.isCancelled && self.generation == current {
                self.connecting = true
                self.status = "Connecting…"
                let opened: UpstreamTerminalSession
                do {
                    opened = try await self.client.openUpstreamTerminal(
                        pane: self.paneID, cols: self.cols, rows: self.rows)
                } catch {
                    if self.generation == current {
                        self.connected = false
                        self.status = error.localizedDescription
                    }
                    return // Includes controller contention; never take over automatically.
                }
                guard self.active, !Task.isCancelled, self.generation == current else {
                    await opened.close()
                    return
                }
                self.session = opened
                self.hasBaseline = false
                self.lastSequence = nil
                self.connecting = false
                // Layout may have changed while opening the channel.
                let initialGrid = (cols: self.cols, rows: self.rows)
                self.sentGrid = initialGrid
                do { try await opened.resize(cols: initialGrid.cols, rows: initialGrid.rows) }
                catch { self.status = error.localizedDescription }
                var closed = false
                do {
                    for try await event in opened.events {
                        guard self.active, self.generation == current,
                              self.session === opened, !Task.isCancelled else { break }
                        switch event {
                        case .frame(let frame):
                            guard self.apply(frame) else { continue }
                            let firstFrame = !self.connected
                            self.connected = true
                            self.status = "Connected"
                            if firstFrame { self.sendDesiredSize() }
                            reconnectDelay = 1
                        case .closed(let reason):
                            self.status = reason.isEmpty ? "Terminal closed" : reason
                            closed = true
                        }
                    }
                } catch {
                    if self.generation == current { self.status = error.localizedDescription }
                }
                if self.generation == current {
                    self.session = nil
                    self.connected = false
                    self.writer?.cancel()
                    self.writer = nil
                }
                await opened.close()
                guard self.generation == current else { return }
                if closed || !self.active || Task.isCancelled { return }
                self.status = "Connection lost. Reconnecting…"
                do { try await Task.sleep(nanoseconds: reconnectDelay * 1_000_000_000) }
                catch { return }
                reconnectDelay = min(reconnectDelay * 2, 15)
            }
        }
    }

    func stop() {
        active = false
        generation += 1
        let previousReader = reader
        previousReader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        resizeTask?.cancel(); resizeTask = nil
        connected = false
        connecting = false
        sentGrid = nil
        terminal?.resignFirstResponder()
        let old = session
        session = nil
        if old != nil || previousReader != nil {
            let previous = releasing
            releasing = Task {
                await previous?.value
                await old?.close()
                await previousReader?.value
            }
        }
    }

    func restart() { stop(); start() }

    private func apply(_ frame: UpstreamTerminalFrame) -> Bool {
        guard let terminal else { return false }
        if let lastSequence, frame.seq <= lastSequence { return false }
        // Never apply a delta to a former connection's display.
        guard frame.full || hasBaseline else { return false }
        if frame.full {
            terminal.getTerminal().resetToInitialState()
            hasBaseline = true
        }
        terminal.applyTerminalSize(cols: frame.width, rows: frame.height)
        terminal.feed(byteArray: Array(frame.bytes)[...])
        lastSequence = frame.seq
        return true
    }

    func proposeSize(cols: Int, rows: Int) {
        let cols = min(max(cols, 4), 65535)
        let rows = min(max(rows, 2), 65535)
        guard self.cols != cols || self.rows != rows else { return }
        self.cols = cols
        self.rows = rows
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            // Coalesce the intermediate grids from keyboard and rotation animations.
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, self.active else { return }
            self.sendDesiredSize()
        }
    }

    private func sendDesiredSize() {
        guard active, connected, session != nil else { return }
        guard sentGrid?.cols != cols || sentGrid?.rows != rows else { return }
        let grid = (cols: cols, rows: rows)
        sentGrid = grid
        enqueue { try await $0.resize(cols: grid.cols, rows: grid.rows) }
    }

    func input(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        enqueue { try await $0.sendInput(bytes) }
    }

    func scroll(_ direction: UpstreamScrollDirection, lines: Int) {
        enqueue { try await $0.scroll(direction: direction, lines: min(max(lines, 1), 65535)) }
    }

    private func enqueue(_ operation: @escaping (UpstreamTerminalSession) async throws -> Void) {
        guard active, connected, let session else { return }
        let preceding = writer
        let current = generation
        writer = Task { [weak self] in
            await preceding?.value
            guard !Task.isCancelled, let self, self.active, self.connected,
                  self.generation == current, self.session === session else { return }
            do { try await operation(session) }
            catch {
                guard self.generation == current else { return }
                // A failed write may already have reached the PTY. Discard pending
                // input, then reconnect for a fresh viewport without replaying it.
                self.status = "Input connection lost: \(error.localizedDescription)"
                self.writer?.cancel()
                self.writer = nil
                self.connected = false
                self.session = nil
                await session.close()
            }
        }
    }
}

private struct UpstreamTerminalSurface: UIViewRepresentable {
    let connection: UpstreamTerminalConnection
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(connection: connection) }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = UpstreamViewportTerminalView(frame: .zero,
                                    font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.contentInsetAdjustmentBehavior = .never
        terminal.inputAccessoryView = nil
        terminal.allowMouseReporting = false
        terminal.changeScrollback(nil)
        // The viewport is rendered remotely. Disable SwiftTerm's local scrolling
        // and route one-finger vertical gestures to terminal.scroll instead.
        terminal.isScrollEnabled = false
        terminal.terminalDelegate = context.coordinator
        terminal.sizeChangeRequestHandler = { [weak connection] cols, rows in
            connection?.proposeSize(cols: cols, rows: rows)
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        terminal.addGestureRecognizer(pan)
        connection.terminal = terminal
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if uiView.font.pointSize != fontSize {
            uiView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.connection.stop()
        uiView.terminalDelegate = nil
        uiView.sizeChangeRequestHandler = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let connection: UpstreamTerminalConnection
        init(connection: UpstreamTerminalConnection) { self.connection = connection }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            let y = gesture.translation(in: view).y
            let cellHeight = max(view.cellSize.height, 1)
            let lines = Int(abs(y) / cellHeight)
            guard lines > 0 else { return }
            connection.scroll(y > 0 ? .up : .down, lines: lines)
            gesture.setTranslation(.zero, in: view)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { connection.input(Data(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            UIApplication.shared.open(url)
        }
        func bell(source: TerminalView) {}
    }
}

/// The daemon's renderer already owns terminal query responses and mouse modes.
/// Only actual keyboard input should travel back from this viewport emulator.
private final class UpstreamViewportTerminalView: TerminalView {
    override func send(source: Terminal, data: ArraySlice<UInt8>) {}
    override func mouseModeChanged(source: Terminal) {}
}
#endif
