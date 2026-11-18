import Foundation
import Observation
import VesperCore

/// The tabs one window holds (a separate-layout window holds exactly one). Observable, so the
/// toolbar, sidebar and tab strip follow the active tab.
@MainActor
@Observable
final class TabsModel {
    var list = TabList<WebContentController>()
}

extension WebContentController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
