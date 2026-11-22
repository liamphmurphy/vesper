import SwiftUI

/// Graph view screen slot for Knowledge.
///
/// **Seam for LAZYAGENTS-287** (native Canvas/Metal Knowledge graph view):
/// currently renders the hosted web graph view at `/knowledge/graph` cleanly inside the native shell.
struct KnowledgeGraphScreenSlot: View {
    var body: some View {
        HostedWebPageView(path: "/knowledge/graph")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
