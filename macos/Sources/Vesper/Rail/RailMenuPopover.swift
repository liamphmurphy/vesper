import AppKit
import SwiftUI
import VesperCore

/// A rail item's menu (PR review requests, etc.) as a popover that flies out to the left of the
/// rail with the system animation, like the Needs-you popover, instead of a plain menu.
@MainActor
final class RailMenuPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private(set) var itemId: String?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func close() { popover.performClose(nil) }

    /// Shows `item`'s menu beside `button`; `choose` gets the picked entry's id.
    func show(_ item: RailItem, relativeTo button: NSView, choose: @escaping (String) -> Void) {
        itemId = item.id
        let view = RailMenuView(title: item.label, items: item.menu ?? []) { [weak self] id in
            self?.popover.performClose(nil)
            choose(id)
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minX)
    }

    func popoverDidClose(_ notification: Notification) { itemId = nil }
}

private struct RailMenuView: View {
    let title: String
    let items: [MenuItem]
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in entry(item, indent: 0) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 280)
    }

    @ViewBuilder private func entry(_ item: MenuItem, indent: CGFloat) -> some View {
        if item.separator == true {
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
        } else if let children = item.children, !children.isEmpty {
            Text(item.label ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8 + indent).padding(.top, 6).padding(.bottom, 2)
            ForEach(children) { child in AnyView(entry(child, indent: indent + 8)) }
        } else {
            MenuRow(item: item, indent: indent) { choose(item.id) }
        }
    }
}

private struct MenuRow: View {
    let item: MenuItem
    let indent: CGFloat
    let action: () -> Void
    @State private var hovering = false

    private var enabled: Bool { item.disabled != true }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if item.checked == true {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(width: 14)
                } else if let icon = item.icon {
                    Image(systemName: SidebarIcons.symbolName(icon)).frame(width: 14)
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
                Text(item.label ?? "").lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut = item.shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(foreground)
            .padding(.vertical, 5)
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && enabled ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if !enabled { return .secondary }
        if hovering { return .white }
        return item.destructive == true ? .red : .primary
    }
}

/// One usage reading, like the web bubble's row: heading and big value, a bar, meta and sub lines.
struct UsageRowView: View {
    let row: RailUsage

    private var tint: Color {
        switch row.tone ?? .normal {
        case .normal: .accentColor
        case .warn: .orange
        case .limited: .red
        }
    }
    private var emphasis: Color? { row.tone == nil || row.tone == .normal ? nil : tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if let value = row.value {
                    Text(value).font(.system(size: 18)).tracking(-0.6).foregroundStyle(emphasis ?? .primary)
                }
            }
            UsageTrack(fraction: row.unavailable == true ? nil : row.fraction, tint: tint)
                .frame(height: 4).padding(.top, 7).padding(.bottom, 8)
            if let meta = row.meta, let left = meta.first {
                HStack(spacing: 5) {
                    Text(left)
                    Spacer(minLength: 0)
                    if meta.count > 1 { Text(meta[1]) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let sub = row.sub, !sub.isEmpty {
                Text(sub).font(.system(size: 11)).foregroundStyle(row.tone == .limited ? Color.red : Color(nsColor: .tertiaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            }
            if let note = row.footnote, !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The bar: a rounded track with a tinted fill; with no fraction, the web's striped "unavailable" look.
private struct UsageTrack: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let fraction {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
                } else {
                    Canvas { ctx, size in
                        var x = 0.0
                        while x < size.width {
                            ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(Color(nsColor: .tertiaryLabelColor)))
                            x += 7
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}
