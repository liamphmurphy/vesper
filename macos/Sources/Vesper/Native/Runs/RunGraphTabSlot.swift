import SwiftUI
import VesperCore

/// Seam for LAZYAGENTS-282: hosts `/runs/:id?tab=graph` via `HostedWebPageView` until the Graph DAG
/// becomes a native Canvas/SwiftUI view. Bridges turn/event node clicks back into the native Trace tab.
struct RunGraphTabSlot: View {
    let runId: String
    let onOpenTurn: (Int) -> Void
    let onOpenEvent: (Int) -> Void

    var body: some View {
        HostedWebPageView(path: "/runs/\(runId)?tab=graph") { message in
            guard case .openInMain(let path, let newTab) = message, !newTab else { return }
            guard let hashIndex = path.firstIndex(of: "#") else { return }
            let fragment = String(path[hashIndex...])
            guard let anchor = RunsLogic.parseAnchor(fragment) else { return }
            switch anchor.kind {
            case .turn:
                onOpenTurn(anchor.number)
            case .event:
                onOpenEvent(anchor.number)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
