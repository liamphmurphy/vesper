import SwiftUI
import VesperCore

/// Start ready: what each run will get, one line per ticket, and nothing starts until the person
/// approves (web components/domain/dispatch-dialog.tsx, its bulk layout; one ticket shows the same
/// line rather than the web's full single-ticket preview).
struct WorkDispatchSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let keys: [String]
    let close: () -> Void

    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        let entries = keys.map { context.store.entry(API.getDispatchPreview(key: $0)) }
        let previews = entries.compactMap(\.data)
        let loaded = previews.count == keys.count
        let checks = previews.map(\.check)
        let summary = DispatchLogic.summary(checks)
        let single = keys.count == 1
        let loadError = entries.compactMap(\.error).first

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if single, let agent = previews.first?.agent, !agent.name.isEmpty {
                    WorkPersonaAvatarView(agent: agent, size: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if single {
                            Text("Dispatch ") + Text(keys[0]).font(.system(size: theme.pointSize(.heading), weight: .semibold, design: .monospaced))
                                + Text(previews.first.map { $0.agent.name.isEmpty ? "" : " to \($0.agent.name)" } ?? "")
                        } else {
                            Text("Dispatch \(keys.count) tickets")
                        }
                    }
                    .vesperText(.heading, theme)
                    Text("This is exactly what \(single ? "the run" : "each run") will get. Nothing starts until you approve.")
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let loadError {
                        banner(.blocked, "Couldn\u{2019}t load the preview", loadError.userMessage)
                    }
                    if single, let check = checks.first {
                        if !check.blockers.isEmpty {
                            banner(.blocked, "This ticket can\u{2019}t be dispatched", check.blockers.joined(separator: ". ") + ".")
                        } else if !check.queuedBehind.isEmpty {
                            banner(.human, "Queued behind blockers",
                                   check.queuedBehind.joined(separator: ". ") + ". The run starts automatically once they are Done.")
                        }
                    }
                    rows(entries)
                    if let first = previews.first {
                        let starts = DispatchLogic.starts(online: first.runner.online, starting: first.runner.starting ?? false,
                                                          busy: first.runner.busy, slots: first.runner.slots, queued: first.runner.queued)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Starts").foregroundStyle(theme.palette.tertiaryText).frame(width: 116, alignment: .leading)
                            Circle().fill(color(starts.tone)).frame(width: 6, height: 6)
                            Text(starts.title).fontWeight(starts.detail.isEmpty ? .regular : .medium)
                            if !starts.detail.isEmpty { Text(starts.detail).foregroundStyle(theme.palette.tertiaryText) }
                        }
                        .font(.system(size: theme.pointSize(.body)))
                    }
                    if !summary.stuckReasons.isEmpty {
                        banner(.blocked, "No harness can run this",
                               summary.stuckReasons.joined(separator: ". ") + ". Every online runner uses an isolated sandbox, so the run would sit in starting.",
                               addKey: true)
                    } else if let secret = summary.missingKey {
                        banner(.human, "No harness API key",
                               "Sandboxed runs fail at start without \(secret). A local runner can use the machine\u{2019}s own CLI login instead.",
                               addKey: true)
                    }
                    if let failure {
                        banner(.blocked, "Couldn\u{2019}t dispatch", failure)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }

            HStack(spacing: 12) {
                Text("Logged on the ticket as dispatched by you")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).buttonStyle(.vesper())
                Button("Approve & dispatch") { dispatch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.vesper(.approve))
                    .disabled(!loaded || summary.blocked || !summary.stuckReasons.isEmpty || sending)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
        }
        .frame(width: 640)
        .frame(minHeight: 280, maxHeight: 640)
        .background(theme.palette.surface)
        .foregroundStyle(theme.palette.text)
        .task {
            for key in keys { context.store.load(API.getDispatchPreview(key: key)) }
        }
    }

    private func rows(_ entries: [QueryEntry<API.DispatchPreview>]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(zip(keys, entries).enumerated()), id: \.element.0) { index, pair in
                if index > 0 { Divider() }
                if let preview = pair.1.data {
                    let status = DispatchLogic.rowStatus(preview.check)
                    HStack(spacing: 10) {
                        Text(preview.ticketKey).font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText).frame(width: 64, alignment: .leading)
                        if !preview.agent.name.isEmpty { WorkPersonaAvatarView(agent: preview.agent, size: 20) }
                        Text(preview.agent.name.isEmpty ? "No agent" : preview.agent.name).fontWeight(.medium)
                        chip(preview.resolved.harness.rawValue)
                        chip(preview.resolved.model)
                        Spacer()
                        Text(status.text).font(.system(size: theme.pointSize(.small))).foregroundStyle(color(status.tone))
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.system(size: theme.pointSize(.body)))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    SkeletonBar(height: 12).padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: theme.pointSize(.small), design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.palette.selected, in: RoundedRectangle(cornerRadius: 5))
    }

    private func banner(_ tone: DispatchLogic.Tone, _ title: String, _ message: String, addKey: Bool = false) -> some View {
        let pill = tone == .blocked ? "blocked" : "human"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).foregroundStyle(theme.swiftUIColor("pill-\(pill)-fg", fallback: .primary))
                Text(message).foregroundStyle(theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if addKey {
                Button("Add a key") {
                    close()
                    context.navigate("/settings#secrets")
                }
                .buttonStyle(.vesper())
            }
        }
        .font(.system(size: theme.pointSize(.body)))
        .padding(12)
        .background(theme.swiftUIColor("pill-\(pill)-bg", fallback: Color.secondary.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10))
    }

    private func color(_ tone: DispatchLogic.Tone) -> Color {
        switch tone {
        case .blocked: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .human: theme.swiftUIColor("pill-human-fg", fallback: .orange)
        case .done: theme.swiftUIColor("state-done", fallback: .green)
        case .neutral: theme.palette.tertiaryText
        }
    }

    private func dispatch() {
        sending = true
        failure = nil
        Task {
            defer { sending = false }
            let invalidation = QueryInvalidation(resources: ["tickets", "bootstrap", "runner"])
            do {
                if keys.count == 1 {
                    _ = try await context.store.mutate(API.dispatchTicket(key: keys[0]), invalidating: invalidation)
                } else {
                    _ = try await context.store.mutate(API.dispatchTickets(body: .init(keys: keys)), invalidating: invalidation)
                }
                close()
            } catch {
                failure = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
