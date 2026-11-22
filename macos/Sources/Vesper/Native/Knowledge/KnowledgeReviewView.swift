import SwiftUI
import VesperCore

/// Native review panel for persona suggestions and direct-edit post-reviews on a Knowledge page.
struct KnowledgeReviewView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let page: KnowledgePage

    @State private var busyKeys: Set<String> = []
    @State private var bulkBusy = false
    @State private var rejectingId: String?
    @State private var rejectReason = ""
    @State private var errorMessage: String?
    @State private var showPastReviews = false

    var body: some View {
        let p = theme.palette
        let pending = KnowledgePanelsLogic.pendingChanges(in: page)
        let undecidedCount = pending.filter { !$0.isStale }.count
        let staleCount = pending.filter(\.isStale).count
        let past = KnowledgePanelsLogic.pastReviews(in: page)

        VStack(alignment: .leading, spacing: 12) {
            if pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No pending suggestions")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.text)
                    Text("Persona edits and suggested patches appear here with line diffs so you can accept or reject each change.")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            } else {
                summaryBar(undecidedCount: undecidedCount, staleCount: staleCount)

                ForEach(pending) { item in
                    changeCard(item)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            if !past.isEmpty {
                DisclosureGroup(isExpanded: $showPastReviews) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(past) { review in
                            pastReviewRow(review)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Past reviews (\(past.count))")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                }
            }
        }
    }

    private func summaryBar(undecidedCount: Int, staleCount: Int) -> some View {
        let p = theme.palette
        let humanBg = theme.swiftUIColor("pill-human-bg", fallback: p.selected)
        let humanFg = theme.swiftUIColor("state-human", fallback: p.accent)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(humanFg)
                Text(page.direct
                     ? "\(undecidedCount) applied \(undecidedCount == 1 ? "change" : "changes") to review"
                     : "\(undecidedCount) suggested \(undecidedCount == 1 ? "change" : "changes")")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
            }

            if staleCount > 0 {
                Text("\(staleCount) stale (page edited after suggestion)")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(humanFg)
            }

            if undecidedCount > 0 {
                HStack(spacing: 8) {
                    Button(page.direct ? "Undo all" : "Reject all") {
                        resolveAll(accept: false)
                    }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                    .disabled(bulkBusy)

                    Button(page.direct ? "Keep all" : "Accept all") {
                        resolveAll(accept: true)
                    }
                    .buttonStyle(.vesper(.primary))
                    .controlSize(.small)
                    .disabled(bulkBusy)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(humanBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(humanFg.opacity(0.35)))
    }

    private func changeCard(_ item: KnowledgePendingChange) -> some View {
        let p = theme.palette
        let isBusy = bulkBusy || busyKeys.contains(item.id)
        let isRejecting = rejectingId == item.id

        return VStack(alignment: .leading, spacing: 8) {
            if item.isStale {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Change \(item.changeIndex + 1) is stale")
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.text)
                        Text("You edited this passage after it was suggested. Your text was kept.")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 6) {
                    if let kind = item.change.kind, kind != "body" {
                        TonePill(label: item.change.key.map { "Property: \($0)" } ?? "Properties", tone: "neutral")
                    } else {
                        Text("Change \(item.changeIndex + 1)")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                    }
                    Spacer()
                    Button {
                        resolveSingle(item, accept: true)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                            .frame(width: 24, height: 24)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(page.direct ? "Keep change" : "Accept change")

                    Button {
                        if isRejecting {
                            rejectingId = nil
                            rejectReason = ""
                        } else {
                            rejectingId = item.id
                            rejectReason = ""
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.swiftUIColor("state-blocked", fallback: .red))
                            .frame(width: 24, height: 24)
                            .background(isRejecting ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(page.direct ? "Undo change" : "Reject change")
                }

                diffBlock(before: item.change.before ?? "", after: item.change.after ?? "")

                Text(item.change.why.flatMap { $0.isEmpty ? nil : "Why: \($0)" } ?? "No reason given")
                    .font(.system(size: theme.pointSize(.micro)))
                    .italic()
                    .foregroundStyle(p.tertiaryText)

                if isRejecting {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Optional reason for persona…", text: $rejectReason)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: theme.pointSize(.small)))
                            .onSubmit {
                                resolveSingle(item, accept: false, reason: rejectReason)
                            }
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                rejectingId = nil
                                rejectReason = ""
                            }
                            .buttonStyle(.vesper())
                            .controlSize(.small)

                            Button(page.direct ? "Undo" : "Reject") {
                                resolveSingle(item, accept: false, reason: rejectReason)
                            }
                            .buttonStyle(.vesper(.danger))
                            .controlSize(.small)
                            .disabled(isBusy)
                        }
                    }
                    .padding(8)
                    .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }

    private func diffBlock(before: String, after: String) -> some View {
        let lines = KnowledgePanelsLogic.diffLines(before: before, after: after)
        let removedBg = theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.14))
        let removedFg = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let addedBg = theme.swiftUIColor("pill-done-bg", fallback: Color.green.opacity(0.14))
        let addedFg = theme.swiftUIColor("pill-done-fg", fallback: .green)
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                let prefix: String = switch line.kind {
                case .removed: "−"
                case .added: "+"
                case .unchanged: " "
                }
                let bg: Color = switch line.kind {
                case .removed: removedBg
                case .added: addedBg
                case .unchanged: .clear
                }
                let fg: Color = switch line.kind {
                case .removed: removedFg
                case .added: addedFg
                case .unchanged: p.secondaryText
                }

                HStack(alignment: .top, spacing: 4) {
                    Text(prefix)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                        .foregroundStyle(fg)
                        .frame(width: 10, alignment: .leading)
                    Text(attributedLine(line, foreground: fg))
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(bg, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func attributedLine(_ line: KnowledgeDiffLine, foreground: Color) -> AttributedString {
        var combined = AttributedString()
        let segments = line.segments.isEmpty
            ? [KnowledgeDiffSegment(text: line.text, isChanged: line.kind != .unchanged)]
            : line.segments
        for seg in segments {
            var part = AttributedString(seg.text)
            part.foregroundColor = foreground
            if seg.isChanged && line.kind == .removed {
                part.strikethroughStyle = .single
            }
            if seg.isChanged && line.kind != .unchanged {
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            combined.append(part)
        }
        return combined
    }

    private func pastReviewRow(_ review: KnowledgeReview) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(review.reviewState ?? review.state)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
                Text(KnowledgeShellLogic.relativeAgo(review.createdAt))
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
            }
            Text("\(review.changes.count) \(review.changes.count == 1 ? "change" : "changes")")
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.tertiaryText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }

    private func resolveSingle(_ item: KnowledgePendingChange, accept: Bool, reason: String? = nil) {
        errorMessage = nil
        busyKeys.insert(item.id)
        let decision = KnowledgePanelsLogic.singleDecision(for: item, accept: accept, reason: reason)
        Task {
            defer { busyKeys.remove(item.id) }
            do {
                _ = try await context.store.mutate(
                    KnowledgeAPI.resolveReview(id: page.id, versionId: item.reviewId, decisions: [decision]),
                    invalidating: KnowledgeAPI.invalidation
                )
                if rejectingId == item.id {
                    rejectingId = nil
                    rejectReason = ""
                }
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func resolveAll(accept: Bool) {
        let batches = KnowledgePanelsLogic.bulkDecisions(for: page, accept: accept)
        guard !batches.isEmpty else { return }
        errorMessage = nil
        bulkBusy = true
        Task {
            defer { bulkBusy = false }
            do {
                for batch in batches {
                    _ = try await context.store.mutate(
                        KnowledgeAPI.resolveReview(id: page.id, versionId: batch.reviewId, decisions: batch.decisions),
                        invalidating: KnowledgeAPI.invalidation
                    )
                }
                rejectingId = nil
                rejectReason = ""
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
