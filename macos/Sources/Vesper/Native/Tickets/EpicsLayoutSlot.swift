import SwiftUI
import VesperCore

/// Layout seam for `/tickets?layout=epics` until LAZYAGENTS-281 lands a fully native Epics list.
/// Renders the temporary `/epics/list` web route inside `HostedWebPageView` without redirect loops.
struct EpicsLayoutSlot: View {
    let query: [String: String]

    var body: some View {
        HostedWebPageView(path: Self.hostedPath(for: query))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func hostedPath(for query: [String: String]) -> String {
        let items = query
            .filter { $0.key != "layout" && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = APIQuery.encode(items)
        return encoded.isEmpty ? "/epics/list" : "/epics/list?\(encoded)"
    }
}
