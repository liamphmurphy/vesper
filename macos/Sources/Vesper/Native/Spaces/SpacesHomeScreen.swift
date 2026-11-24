import SwiftUI
import VesperCore

/// Native `/spaces` landing screen: opens the first Space when one exists, or shows `NewSpaceScreen` when empty.
struct SpacesHomeScreen: View {
    @Environment(NativeScreenContext.self) private var context

    private static let spacesRequest = API.listChatSpaces()

    var body: some View {
        let entry = context.store.entry(Self.spacesRequest)
        let spaces = entry.data?.spaces ?? []

        Group {
            if entry.data == nil && entry.error == nil {
                ProgressView("Loading spaces\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if spaces.isEmpty {
                NewSpaceScreen()
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        if let first = spaces.first {
                            context.navigate("/spaces/\(first.id)")
                        }
                    }
            }
        }
        .onChange(of: spaces.first?.id) { _, firstId in
            if let firstId {
                context.navigate("/spaces/\(firstId)")
            }
        }
        .onAppear {
            context.store.observe(Self.spacesRequest)
            context.store.load(Self.spacesRequest)
        }
        .onDisappear {
            context.store.stopObserving(Self.spacesRequest.key)
        }
    }
}
