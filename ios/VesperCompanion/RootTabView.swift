import SwiftUI
import VesperCore

struct RootTabView: View {
    let connection: CompanionConnectionManager

    @State private var sseTick = 0
    @State private var inboxBadge = 0

    var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusBanner(connection: connection)

            TabView {
                ChatListView(connection: connection, sseTick: sseTick)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

                InboxView(connection: connection, sseTick: sseTick, badgeCount: $inboxBadge)
                    .tabItem { Label("Inbox", systemImage: "tray") }
                    .badge(inboxBadge)

                RunsView(connection: connection, sseTick: sseTick)
                    .tabItem { Label("Runs", systemImage: "bolt.horizontal.circle") }

                QuickCaptureView(connection: connection)
                    .tabItem { Label("Capture", systemImage: "plus.square.on.square") }

                CompanionSettingsView(connection: connection)
                    .tabItem { Label("Mac", systemImage: "desktopcomputer") }
            }
        }
        .onChange(of: connection.state) { _, _ in
            wireSSE()
        }
        .onAppear {
            wireSSE()
        }
    }

    private func wireSSE() {
        connection.eventStream?.onEvent = { _ in
            sseTick += 1
        }
    }
}

private struct ConnectionStatusBanner: View {
    let connection: CompanionConnectionManager

    var body: some View {
        switch connection.state {
        case .unpaired:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting to \(connection.pairedHost?.hostName ?? "Mac")…")
                    .font(.caption.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
        case .connected(let transport, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(transport == .lan ? Color.green : Color.blue)
                    .frame(width: 8, height: 8)
                Text("\(connection.pairedHost?.hostName ?? "Mac") · \(transport.displayName)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
        case .unreachable(let msg):
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    Task { await connection.reconnect() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.14))
        }
    }
}
