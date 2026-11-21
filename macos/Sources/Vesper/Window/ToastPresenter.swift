import AppKit
import Observation
import SwiftUI
import VesperCore
import WebKit

/// Window-level host contract so tabs, companion, and inspector panels can trigger native window overlays.
@MainActor
protocol ShellHostActions: AnyObject {
    func showToast(_ toast: ToastItemModel, from webView: WKWebView?)
    func dismissToast(id: String)
    func showShortcuts()
    func openCommandPalette(_ request: CommandPaletteRequest?)
    func closeCommandPalette()
    func showQuickLook(items: [QuickLookItem], index: Int?)
}

/// Manages active toast pills for a single window, including hover-pause countdown timers and
/// routing action/dismiss/timeout events back to the originating WKWebView.
@MainActor
@Observable
final class ToastStore {
    private(set) var toasts: [ToastItemModel] = []

    @ObservationIgnored private var entries: [String: TimerEntry] = [:]

    private struct TimerEntry {
        weak var webView: WKWebView?
        /// A native screen's handler, for a toast it showed itself (no page to tell).
        var onEvent: (@MainActor (ToastEventKind) -> Void)?
        var remainingMs: Int
        var hovered: Bool
        var task: Task<Void, Never>?
    }

    func show(_ toast: ToastItemModel, from webView: WKWebView?, onEvent: (@MainActor (ToastEventKind) -> Void)? = nil) {
        let clampedDuration = max(500, toast.durationMs)
        let normalized = ToastItemModel(
            id: toast.id,
            title: toast.title,
            description: toast.description,
            tone: toast.tone,
            actionLabel: toast.actionLabel,
            durationMs: clampedDuration
        )
        let (next, evicted) = ToastQueueLogic.upsert(normalized, into: toasts)
        toasts = next
        for gone in evicted {
            if let entry = entries.removeValue(forKey: gone.id) {
                entry.task?.cancel()
                ShellBridge.send(.toastEvent(id: gone.id, event: .dismissed), to: entry.webView)
                entry.onEvent?(.dismissed)
            }
        }
        if let existing = entries.removeValue(forKey: normalized.id) {
            existing.task?.cancel()
        }
        var entry = TimerEntry(webView: webView, onEvent: onEvent, remainingMs: clampedDuration, hovered: false, task: nil)
        entry.task = makeTimerTask(for: normalized.id)
        entries[normalized.id] = entry
    }

    func dismissFromPage(id: String) {
        let (next, _) = ToastQueueLogic.remove(id: id, from: toasts)
        toasts = next
        if let entry = entries.removeValue(forKey: id) {
            entry.task?.cancel()
        }
    }

    func triggerAction(id: String) {
        complete(id: id, event: .action)
    }

    func dismissByUser(id: String) {
        complete(id: id, event: .dismissed)
    }

    func setHovered(id: String, hovered: Bool) {
        entries[id]?.hovered = hovered
    }

    func teardown() {
        for entry in entries.values {
            entry.task?.cancel()
        }
        entries.removeAll()
        toasts.removeAll()
    }

    private func makeTimerTask(for id: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard var entry = self.entries[id] else { return }
                if entry.hovered { continue }
                entry.remainingMs -= 100
                self.entries[id] = entry
                if entry.remainingMs <= 0 {
                    self.complete(id: id, event: .timeout)
                    return
                }
            }
        }
    }

    private func complete(id: String, event: ToastEventKind) {
        let (next, _) = ToastQueueLogic.remove(id: id, from: toasts)
        toasts = next
        if let entry = entries.removeValue(forKey: id) {
            entry.task?.cancel()
            ShellBridge.send(.toastEvent(id: id, event: event), to: entry.webView)
            entry.onEvent?(event)
        }
    }
}

private struct ToastPillGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ToastOverlayView: View {
    let store: ToastStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.toasts) { toast in
                ToastPillView(
                    toast: toast,
                    onAction: { store.triggerAction(id: toast.id) },
                    onDismiss: { store.dismissByUser(id: toast.id) },
                    onHover: { store.setHovered(id: toast.id, hovered: $0) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: store.toasts)
    }
}

private struct ToastPillView: View {
    let toast: ToastItemModel
    let onAction: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    private var iconName: String? {
        switch toast.tone {
        case .neutral: nil
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.tone {
        case .neutral: .secondary
        case .success: .green
        case .error: .red
        }
    }

    private var borderColor: Color {
        toast.tone == .error ? Color.red.opacity(0.42) : Color.primary.opacity(0.14)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .padding(.top, 1.5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(toast.tone == .error ? Color.red : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = toast.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionLabel = toast.actionLabel, !actionLabel.isEmpty {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Dismiss notification")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(minWidth: 260, maxWidth: 420)
        .background(ToastPillGlass())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .onHover(perform: onHover)
    }
}
