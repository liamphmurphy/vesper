import SwiftUI
import VesperCore

/// Inline memory diff pills rendered under turns where `save_memory`, `update_memory`, or
/// `forget_memory` ran, offering 1-click Edit and Undo right inside the chat transcript.
struct ChatMemoryDiffPillsView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let diffs: [ChatMemoryDiff]
    let personaId: String?

    @State private var undoneIds: Set<String> = []
    @State private var busyIds: Set<String> = []
    @State private var editingDiff: ChatMemoryDiff?
    @State private var editTitle = ""
    @State private var editSummary = ""
    @State private var savingEdit = false
    @State private var editError: String?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            ForEach(diffs) { diff in
                let undone = undoneIds.contains(diff.id)
                let busy = busyIds.contains(diff.id)
                HStack(spacing: 8) {
                    Image(systemName: icon(for: diff.action, undone: undone))
                        .imageScale(.small)
                        .foregroundStyle(tint(for: diff.action, undone: undone, palette: p))

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(labelPrefix(for: diff.action, undone: undone))
                                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                                .foregroundStyle(tint(for: diff.action, undone: undone, palette: p))
                            Text(diff.title)
                                .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                .foregroundStyle(undone ? p.tertiaryText : p.text)
                                .strikethrough(undone)
                                .lineLimit(1)
                            if diff.about == "persona" {
                                Text("persona")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(p.surface, in: Capsule())
                            }
                        }
                        if !diff.summary.isEmpty && !undone {
                            Text(diff.summary)
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)

                    if !undone {
                        if diff.action != .forgotten, diff.memoryId != nil {
                            Button("Edit") {
                                editTitle = diff.title
                                editSummary = diff.summary
                                editError = nil
                                editingDiff = diff
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(p.secondaryText)
                            .disabled(busy)
                        }

                        if canUndo(diff) {
                            Button(busy ? "…" : "Undo") {
                                Task { await undo(diff) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(p.accent)
                            .disabled(busy)
                        }
                    } else {
                        Text("Undone")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }
        }
        .sheet(item: $editingDiff) { diff in
            editSheet(for: diff)
        }
    }

    private func icon(for action: ChatMemoryDiff.Action, undone: Bool) -> String {
        if undone { return "arrow.uturn.backward.circle" }
        switch action {
        case .created: return "brain.head.profile"
        case .updated: return "pencil.circle"
        case .forgotten: return "trash.circle"
        }
    }

    private func labelPrefix(for action: ChatMemoryDiff.Action, undone: Bool) -> String {
        if undone { return "Reverted:" }
        switch action {
        case .created: return "Remembered:"
        case .updated: return "Updated memory:"
        case .forgotten: return "Forgot:"
        }
    }

    private func tint(for action: ChatMemoryDiff.Action, undone: Bool, palette p: NativePalette) -> Color {
        if undone { return p.tertiaryText }
        switch action {
        case .created: return theme.swiftUIColor("state-done", fallback: .green)
        case .updated: return p.accent
        case .forgotten: return theme.swiftUIColor("state-human", fallback: .orange)
        }
    }

    private func canUndo(_ diff: ChatMemoryDiff) -> Bool {
        switch diff.action {
        case .created: return diff.memoryId != nil
        case .updated: return diff.memoryId != nil && (diff.previousTitle != nil || diff.previousSummary != nil)
        case .forgotten: return !diff.title.isEmpty
        }
    }

    private func undo(_ diff: ChatMemoryDiff) async {
        busyIds.insert(diff.id)
        defer { busyIds.remove(diff.id) }
        do {
            switch diff.action {
            case .created:
                guard let id = diff.memoryId else { return }
                _ = try await context.store.mutate(
                    API.deleteMemory(id: id),
                    invalidating: QueryInvalidation(resources: ["memories"])
                )
            case .updated:
                guard let id = diff.memoryId else { return }
                _ = try await context.store.mutate(
                    API.updateMemory(id: id, body: API.MemoryPatch(
                        summary: diff.previousSummary,
                        title: diff.previousTitle
                    )),
                    invalidating: QueryInvalidation(resources: ["memories"])
                )
            case .forgotten:
                _ = try await context.store.mutate(
                    API.createMemory(body: API.MemoryCreate(
                        personaId: diff.about == "persona" ? personaId : nil,
                        summary: diff.summary.isEmpty ? nil : diff.summary,
                        title: diff.title,
                        type: diff.type
                    )),
                    invalidating: QueryInvalidation(resources: ["memories"])
                )
            }
            undoneIds.insert(diff.id)
            context.showToast(ToastItemModel(id: "chat.memory.undo.\(diff.id)", title: "Reverted memory change", tone: .success))
        } catch {
            context.showToast(ToastItemModel(
                id: "chat.memory.undo.err",
                title: (error as? APIError)?.userMessage ?? "Couldn’t undo memory change",
                tone: .error
            ))
        }
    }

    private func editSheet(for diff: ChatMemoryDiff) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 12) {
            Text("Edit memory")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                TextField("Title", text: $editTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                TextField("Summary", text: $editSummary, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }

            if let editError {
                Text(editError)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { editingDiff = nil }
                    .buttonStyle(.vesper())
                    .disabled(savingEdit)
                Button(savingEdit ? "Saving…" : "Save") {
                    guard let id = diff.memoryId else { return }
                    let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTitle.isEmpty else { return }
                    savingEdit = true
                    editError = nil
                    Task {
                        defer { savingEdit = false }
                        do {
                            _ = try await context.store.mutate(
                                API.updateMemory(id: id, body: API.MemoryPatch(
                                    summary: editSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                                    title: trimmedTitle
                                )),
                                invalidating: QueryInvalidation(resources: ["memories"])
                            )
                            editingDiff = nil
                            context.showToast(ToastItemModel(id: "chat.memory.edit.\(id)", title: "Updated memory", tone: .success))
                        } catch {
                            editError = (error as? APIError)?.userMessage ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(savingEdit || editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
