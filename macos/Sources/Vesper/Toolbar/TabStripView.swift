import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// What the compact tab strip can ask of its window.
struct TabStripActions {
    var select: (WebContentController) -> Void
    var close: (WebContentController) -> Void
    var newTab: () -> Void
    var closeOthers: (WebContentController) -> Void
    var closeToTheRight: (WebContentController) -> Void
    var moveToNewWindow: (WebContentController) -> Void
    var duplicate: (WebContentController) -> Void
    var reopenClosed: () -> Void
    var canReopen: () -> Bool
    var move: (_ from: Int, _ to: Int) -> Void
}

/// Safari-style compact tabs for the toolbar: title, area icon, a close button on hover and on the
/// active tab. Tabs shrink to fit, then scroll.
struct TabStripView: View {
    let model: TabsModel
    let actions: TabStripActions

    @State private var dragging: ObjectIdentifier?

    /// The strip as a toolbar item's view: flexible width (at least 240 pt), 28 pt tall.
    static func hostView(model: TabsModel, actions: TabStripActions) -> NSView {
        let hosting = NSHostingView(rootView: TabStripView(model: model, actions: actions))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.heightAnchor.constraint(equalToConstant: 28),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        container.widthAnchor.constraint(lessThanOrEqualToConstant: 4000).isActive = true
        return container
    }

    private static let minTabWidth: CGFloat = 110
    private static let maxTabWidth: CGFloat = 220
    private static let spacing: CGFloat = 2

    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return maxTabWidth }
        let fit = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return min(maxTabWidth, max(minTabWidth, fit))
    }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                let tabs = model.list.items
                let width = Self.tabWidth(available: geo.size.width, count: tabs.count)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Self.spacing) {
                            ForEach(tabs) { tab in
                                TabCell(tab: tab, active: model.list.active === tab, actions: actions)
                                    .frame(width: width)
                                    .id(tab.id)
                                    .onDrag {
                                        dragging = tab.id
                                        return NSItemProvider(object: "vesper-tab" as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: TabDropDelegate(tab: tab, model: model, dragging: $dragging, move: actions.move))
                            }
                        }
                        .frame(minWidth: geo.size.width, alignment: .leading)
                    }
                    .onChange(of: model.list.active?.id) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
            }
            Button(action: actions.newTab) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
        .frame(height: 28)
        .padding(.horizontal, 2)
    }
}

private struct TabCell: View {
    let tab: WebContentController
    let active: Bool
    let actions: TabStripActions
    @State private var hovering = false

    private var iconName: String {
        guard tab.kind == .vesper else { return "globe" }
        guard let area = tab.state.currentArea else { return "bubble.left" }
        let areas = (tab.state.shell ?? ShellState.fallbackShell).areas
        if let icon = areas.first(where: { $0.id == area })?.icon { return SidebarIcons.symbolName(icon) }
        return area == .apps ? "square.grid.2x2" : "bubble.left"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: 14)
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(active ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { actions.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(active || hovering ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(active ? 0.14 : hovering ? 0.07 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .onTapGesture { actions.select(tab) }
        .overlay(MiddleClickCatcher { actions.close(tab) })
        .contextMenu {
            Button("Close Tab") { actions.close(tab) }
            Button("Close Other Tabs") { actions.closeOthers(tab) }
            Button("Close Tabs to the Right") { actions.closeToTheRight(tab) }
            Divider()
            Button("Move Tab to New Window") { actions.moveToNewWindow(tab) }
            Button("Duplicate Tab") { actions.duplicate(tab) }
            Divider()
            Button("Reopen Closed Tab") { actions.reopenClosed() }.disabled(!actions.canReopen())
        }
    }
}

/// Reorders as the dragged tab enters another tab.
private struct TabDropDelegate: DropDelegate {
    let tab: WebContentController
    let model: TabsModel
    @Binding var dragging: ObjectIdentifier?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != tab.id,
              let from = model.list.items.firstIndex(where: { $0.id == dragging }),
              let to = model.list.items.firstIndex(where: { $0 === tab }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { move(from, to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// An invisible overlay that only takes middle-button clicks (everything else falls through to the
/// tab), which SwiftUI has no gesture for.
private struct MiddleClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onClick = onClick }

    final class CatcherView: NSView {
        var onClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp: return super.hitTest(point)
            default: return nil
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { onClick?() }
        }
    }
}
