import SwiftUI
import VesperCore

@main
struct VesperCompanionApp: App {
    @State private var connection = CompanionConnectionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if connection.state == .unpaired {
                    PairingView(connection: connection)
                } else {
                    RootTabView(connection: connection)
                }
            }
            .task {
                await connection.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, connection.pairedHost != nil, !connection.state.isConnected {
                    Task { await connection.reconnect() }
                }
            }
        }
    }
}
