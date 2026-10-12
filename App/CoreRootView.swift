import SwiftUI
import HerdrKit

/// The stock-Herder app surface. Legacy feature screens have no launch route.
struct CoreRootView: View {
    @StateObject private var connection = CoreConnection()
    @ObservedObject private var hosts = SavedHostsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: HostEditorTarget?

    var body: some View {
        Group {
            if let client = connection.client {
                CoreDashboard(connection: connection, client: client)
                    .id(ObjectIdentifier(client))
            } else {
                NavigationStack {
                    List {
                        Section {
                            Text("Connect to a host running stock Herder to see agent status and control its terminals.")
                                .foregroundStyle(.secondary)
                            if connection.connecting { ProgressView("Connecting over SSH…") }
                            if let error = connection.error {
                                Text(error).foregroundStyle(Palette.died).textSelection(.enabled)
                                if connection.hasCredentials {
                                    Button("Retry connection") { connection.resume() }
                                }
                            }
                        }
                        Section("SSH hosts") {
                            ForEach(hosts.hosts) { host in
                                Button { connection.connect(host, store: hosts) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(host.label).foregroundStyle(Palette.text)
                                        Text("\(host.username)@\(host.host)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("core-host-\(host.id.uuidString)")
                                .contextMenu {
                                    Button("Edit host") { editor = .edit(host) }
                                    Button("Remove host", role: .destructive) {
                                        if !hosts.delete(host) { connection.error = "Couldn't remove the saved credential. Try again after unlocking the device." }
                                    }
                                }
                            }
                            Button { editor = .add } label: { Label("Add SSH host", systemImage: "plus") }
                        }
                    }
                    .navigationTitle("Herdr Core")
                }
            }
        }
        .sheet(item: $editor) { target in
            HostEditor(target: target, store: hosts) { connection.connect($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.resume() } else { connection.suspend() }
        }
    }
}

@MainActor
final class CoreConnection: ObservableObject {
    @Published private(set) var client: HerdrClient?
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var sessions: [HerdrSession] = []
    @Published private(set) var connecting = false
    @Published private(set) var hostLabel = ""
    @Published private(set) var sessionName = "default"
    @Published private(set) var lastUpdated: Date?
    @Published var error: String?
    private var credentials: SSHCredentials?
    private var transport: CitadelTransport?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    var hasCredentials: Bool { credentials != nil }

    func connect(_ host: SavedHost, store: SavedHostsStore) {
        guard let endpoint = HostEndpoint.parse(host.host) else {
            error = "The saved host address is invalid. Edit the host and try again."
            return
        }
        let creds: SSHCredentials
        switch host.auth {
        case .key:
            guard let secret = store.key(for: host) else { error = "The saved SSH key is unavailable. Unlock the device or edit this host."; return }
            creds = SSHCredentials(host: endpoint.host, port: endpoint.port, username: host.username, privateKeyPEM: secret, remoteSocketPath: "")
        case .password:
            guard let secret = store.password(for: host) else { error = "The saved SSH password is unavailable. Unlock the device or edit this host."; return }
            creds = SSHCredentials(host: endpoint.host, port: endpoint.port, username: host.username, password: secret, remoteSocketPath: "")
        }
        connect(creds, label: host.label)
    }

    func connect(_ creds: SSHCredentials, label: String? = nil) {
        suspend()
        credentials = creds
        hostLabel = label ?? creds.host
        sessionName = creds.session ?? "default"
        resume()
    }

    func switchSession(_ name: String) {
        guard var creds = credentials, name != sessionName else { return }
        creds.session = name == "default" ? nil : name
        connect(creds, label: hostLabel)
    }

    func resume() {
        guard work == nil, let creds = credentials else { return }
        let token = UUID()
        generation = token
        connecting = true
        error = nil
        let ssh = CitadelTransport(credentials: creds, hostKeyPolicy: KeychainHostKeyPolicy.shared)
        transport = ssh
        let api = HerdrClient(transport: ssh)
        work = Task {
            defer { Task { await ssh.close() } }
            do {
                // Successful stock agent.list is the connection's readiness check.
                let first = try await api.agentList()
                try Task.checkCancellation()
                guard generation == token else { return }
                agents = first
                client = api
                connecting = false
                lastUpdated = Date()
                let availableSessions = (try? await api.listSessions()) ?? []
                try Task.checkCancellation()
                guard generation == token else { return }
                sessions = availableSessions
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    do {
                        let updated = try await api.agentList()
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        agents = updated
                        lastUpdated = Date()
                        error = nil
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard generation == token else { return }
                        self.error = "Status refresh failed: \(error.localizedDescription)"
                    }
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = "SSH connection failed: \(error.localizedDescription)"
            }
            guard generation == token else { return }
            connecting = false
            client = nil
            transport = nil
            work = nil
        }
    }

    func suspend() {
        generation = UUID()
        work?.cancel()
        work = nil
        let old = transport
        transport = nil
        client = nil
        agents = []
        sessions = []
        lastUpdated = nil
        connecting = false
        Task { await old?.close() }
    }

    func disconnect() {
        suspend()
        credentials = nil
        error = nil
    }

    func reconnect() {
        suspend()
        resume()
    }
}

private struct CoreDashboard: View {
    @ObservedObject var connection: CoreConnection
    let client: HerdrClient
    @State private var selectedPane: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                Section {
                    Text(connection.hostLabel).font(.headline)
                    if connection.sessions.count > 1 {
                        Picker("Session", selection: Binding(get: { connection.sessionName }, set: connection.switchSession)) {
                            ForEach(connection.sessions.filter(\.running)) { session in Text(session.name).tag(session.name) }
                        }
                    } else { Text("Session: \(connection.sessionName)").font(.caption).foregroundStyle(.secondary) }
                    if let error = connection.error {
                        Text(error).font(.caption).foregroundStyle(Palette.waiting)
                        Button("Reconnect") { connection.reconnect() }
                    }
                    if let date = connection.lastUpdated {
                        Text("Updated \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Agents · \(connection.agents.count)") {
                    ForEach(connection.agents) { agent in
                        NavigationLink(value: agent.paneID) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(agent.displayName).font(.headline)
                                HStack {
                                    Circle().fill(statusColor(agent.agentStatus)).frame(width: 7, height: 7)
                                    Text(agent.agentStatus ?? "unknown").font(.caption)
                                    if let kind = agent.agent { Text(kind).font(.caption).foregroundStyle(.secondary) }
                                }
                                if let cwd = agent.cwd { Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                    if connection.agents.isEmpty { Text("No agents in this session.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Agents")
            .toolbar { Button("Hosts") { connection.disconnect() } }
        } detail: {
            if let selectedPane, let agent = connection.agents.first(where: { $0.paneID == selectedPane }) {
                CoreAgentDetail(client: client, agent: agent)
                    .id(selectedPane)
            } else {
                ContentUnavailableView("Select an agent", systemImage: "terminal", description: Text("View its terminal and send prompts or keys."))
            }
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "working": Palette.working
        case "blocked": Palette.waiting
        case "done": Palette.done
        default: Palette.textDim
        }
    }
}

private struct CoreAgentDetail: View {
    let client: HerdrClient
    let agent: AgentInfo
    @State private var prompt = ""
    @State private var sending = false
    @State private var deliveryMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            UpstreamTerminalView(client: client, paneID: agent.paneID)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let deliveryMessage { Text(deliveryMessage).font(.caption).textSelection(.enabled) }
                HStack(alignment: .bottom) {
                    TextField("Prompt agent…", text: $prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button(sending ? "Sending…" : "Send") { sendPrompt() }
                        .disabled(sending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isAwaitingMenuInput)
                }
                if agent.isAwaitingMenuInput {
                    Text("This agent needs terminal input. Use the keys above to answer its prompt.").font(.caption).foregroundStyle(Palette.waiting)
                }
            }
            .padding()
        }
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendPrompt() {
        guard !sending else { return }
        let text = prompt
        sending = true
        deliveryMessage = nil
        Task {
            defer { sending = false }
            do {
                _ = try await client.prompt(pane: agent.paneID, text: text)
                if prompt == text { prompt = "" }
                deliveryMessage = "Prompt submitted."
            } catch {
                // Keep the draft, but never retry uncertain input automatically.
                deliveryMessage = "Prompt failed: \(error.localizedDescription). Check the terminal before sending again."
            }
        }
    }
}
