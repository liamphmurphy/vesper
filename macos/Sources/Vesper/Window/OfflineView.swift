import SwiftUI
import VesperCore

/// Shown over the page while the stack is starting or failed, or when a page failed to load.
struct OfflineView: View {
    let app: AppModel
    let state: ShellState
    let kind: WindowKind
    let retry: () -> Void
    let restartStack: () -> Void
    let showLogs: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            content.padding(32).frame(maxWidth: 460)
        }
    }

    @ViewBuilder private var content: some View {
        if kind == .vesper, app.connection == nil, let health = app.stack?.health {
            stackStatus(health)
        } else if let error = state.loadError {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Couldn't load this page").font(.title3.weight(.semibold))
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Retry", action: retry).keyboardShortcut(.defaultAction)
                    if kind == .vesper, app.stack != nil {
                        Button("Restart Stack", action: restartStack)
                        Button("Show Logs…", action: showLogs)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ViewBuilder private func stackStatus(_ health: StackHealth) -> some View {
        VStack(spacing: 14) {
            switch health.phase {
            case .error, .stopped, .degraded:
                Image(systemName: health.phase == .degraded ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.system(size: 34)).foregroundStyle(health.phase == .degraded ? .orange : .red)
            default:
                ProgressView().controlSize(.large)
            }
            Text(health.title).font(.title3.weight(.semibold))
            if !health.message.isEmpty { Text(health.message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let next = health.nextStep { Text(next).multilineTextAlignment(.center) }
            if let fraction = health.downloadFraction {
                ProgressView(value: fraction).frame(maxWidth: 260)
            }
            if health.phase == .error || health.phase == .stopped || health.phase == .degraded {
                HStack {
                    Button("Restart Stack", action: restartStack).keyboardShortcut(.defaultAction)
                    Button("Show Logs…", action: showLogs)
                }
            }
        }
    }
}
