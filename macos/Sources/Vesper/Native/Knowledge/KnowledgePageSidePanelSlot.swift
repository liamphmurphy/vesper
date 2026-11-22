import SwiftUI
import VesperCore

/// Trailing metadata / side panel slot beside a Knowledge page.
struct KnowledgePageSidePanelSlot: View {
    let page: KnowledgePage
    let onSelectTag: (String) -> Void

    var body: some View {
        KnowledgeSidePanelsView(page: page, onSelectTag: onSelectTag)
    }
}
