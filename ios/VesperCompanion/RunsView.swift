import SwiftUI
import VesperCore

struct RunsView: View {
    let connection: CompanionConnectionManager
    let sseTick: Int

    @State private var liveRuns: [RunSummary] = []
    @State private var recentRuns: [RunSummary] = []
    @State private var loading = false
    @State private var errorMessage: String?

    private struct RunsResponse: Decodable {
        var runs: [RunSummary]
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if !liveRuns.isEmpty {
                    Section("Live (\(liveRuns.count))") {
                        ForEach(liveRuns, id: \.id) { run in
                            RunRow(run: run)
                        }
                    }
                }
                if !recentRuns.isEmpty {
                    Section("Recent") {
                        ForEach(recentRuns, id: \.id) { run in
                            RunRow(run: run)
                        }
                    }
                }
                if liveRuns.isEmpty && recentRuns.isEmpty && !loading {
                    ContentUnavailableView(
                        "No Runs",
                        systemImage: "bolt.horizontal.circle",
                        description: Text("Agent runs on your Mac will appear here live.")
                    )
                }
            }
            .navigationTitle("Runs")
            .refreshable { await load() }
            .task(id: connection.state) { await load() }
            .onChange(of: sseTick) { _, _ in
                Task { await load(silent: true) }
            }
        }
    }

    private func load(silent: Bool = false) async {
        guard let client = connection.apiClient else { return }
        if !silent { loading = true }
        defer { loading = false }
        do {
            async let live: RunsResponse = client.get("/api/v1/runs?state=live", as: RunsResponse.self)
            async let all: RunsResponse = client.get("/api/v1/runs?state=all", as: RunsResponse.self)
            let (liveResp, allResp) = try await (live, all)
            liveRuns = liveResp.runs
            let liveIds = Set(liveResp.runs.map(\.id))
            recentRuns = allResp.runs.filter { !liveIds.contains($0.id) }.prefix(25).map { $0 }
            errorMessage = nil
        } catch {
            if !silent {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private struct RunRow: View {
    let run: RunSummary

    private var stateColor: Color {
        switch run.state {
        case "running", "starting", "queued": return .blue
        case "waiting": return .orange
        case "completed": return .green
        case "failed": return .red
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let key = run.ticketKey, !key.isEmpty {
                    Text(key)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(run.state.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(stateColor)
                Spacer()
                if let agent = run.agent?.name, !agent.isEmpty {
                    Text(agent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(run.workTitle ?? run.purpose.capitalized)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if let reason = run.waitReason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }
}
