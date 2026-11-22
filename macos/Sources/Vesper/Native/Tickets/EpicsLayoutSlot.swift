import SwiftUI
import VesperCore

/// Native Epics layout slot inside `TicketsScreen` (`/tickets?layout=epics`).
struct EpicsLayoutSlot: View {
    let query: [String: String]

    var body: some View {
        EpicsListView(embeddedProject: query["project"], embedded: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
