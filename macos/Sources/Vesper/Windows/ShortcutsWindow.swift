import AppKit
import SwiftUI
import VesperCore

@MainActor
private final class ShortcutsPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// The `?` / `⌘/` keyboard shortcuts window rendered natively with SwiftUI over vibrancy.
@MainActor
final class ShortcutsWindowController {
    private var panel: ShortcutsPanel?

    func show() {
        if panel == nil {
            let host = NSHostingController(rootView: ShortcutsWindowView())
            let panel = ShortcutsPanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            panel.title = "Keyboard Shortcuts"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 480, height: 380)
            panel.contentViewController = host
            panel.setFrameAutosaveName("VesperShortcuts")
            panel.center()
            self.panel = panel
        }
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }
}

private struct ShortcutsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ShortcutsWindowView: View {
    @State private var query = ""

    private var filtered: [ShortcutSection] {
        KeyboardShortcutsCatalog.filter(query: query)
    }

    var body: some View {
        ZStack {
            ShortcutsBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter shortcuts…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Divider()

                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No matching shortcuts")
                            .font(.headline)
                        Text("Try another keyword or clear the filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(filtered) { section in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.title.uppercased())
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .tracking(0.6)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 0) {
                                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                            HStack(spacing: 12) {
                                                Text(item.label)
                                                    .font(.system(size: 13))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                HStack(spacing: 4) {
                                                    ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in
                                                        KeyCapBadge(label: key)
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)

                                            if index < section.items.count - 1 {
                                                Divider().opacity(0.45)
                                            }
                                        }
                                    }
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                                    )
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }
}

private struct KeyCapBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}
