import SwiftUI
import VesperCore

// MARK: - Live Entity Cards Strip (LAZYAGENTS-317)

struct ChatEntityCardsStripView: View {
    let refs: [ChatEntityRef]

    var body: some View {
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(refs) { ref in
                    switch ref {
                    case .page(let pageRef):
                        ChatLivePageCardView(pageRef: pageRef)
                    }
                }
            }
        }
    }
}

// MARK: - Wiki Page Entity Card

private struct ChatLivePageCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let pageRef: String

    var body: some View {
        let resolveReq = API.resolveLinks(ref: [pageRef])
        let entry = context.store.entry(resolveReq)
        let target = entry.data?.links.first?.target

        Group {
            if let target, target.kind != .unresolved, let href = target.href, !href.isEmpty {
                ChatLiveResolvedPageCardView(target: target, href: href)
            } else if entry.data != nil || entry.error != nil {
                notFoundChip(icon: "doc.text", label: pageRef)
            } else {
                loadingChip(icon: "doc.text", label: pageRef)
            }
        }
        .task(id: pageRef) {
            context.store.load(resolveReq)
        }
    }
}

private struct ChatLiveResolvedPageCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let target: API.LinkTarget
    let href: String

    var body: some View {
        let p = theme.palette
        let pageReq = target.path.flatMap { !$0.isEmpty ? API.getWikiPage(path: $0) : nil }
        let artifact = pageReq.flatMap { context.store.entry($0).data }
        let folder = ChatEntityRefExtractor.folderPath(from: artifact?.path ?? target.path)
        let edited = artifact.map { APIDate.shortAgo($0.updatedAt) }

        Button {
            context.navigate(href)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .imageScale(.small)
                    .foregroundStyle(p.accent)
                Text(artifact?.title ?? target.title)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                if let folder {
                    Text(folder)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let edited {
                    Text("edited \(edited)")
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
        .buttonStyle(.plain)
        .task(id: target.path ?? "") {
            if let pageReq { context.store.load(pageReq) }
        }
    }
}

// MARK: - Shared Missing / Loading Chips

@MainActor
private func notFoundChip(icon: String, label: String) -> some View {
    ChatEntityFallbackChip(icon: icon, label: label, suffix: "not found", loading: false)
}

@MainActor
private func loadingChip(icon: String, label: String) -> some View {
    ChatEntityFallbackChip(icon: icon, label: label, suffix: nil, loading: true)
}

private struct ChatEntityFallbackChip: View {
    @Environment(\.vesperTheme) private var theme
    let icon: String
    let label: String
    let suffix: String?
    let loading: Bool

    var body: some View {
        let p = theme.palette
        HStack(spacing: 6) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(p.tertiaryText)
            Text(label)
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(p.secondaryText)
                .lineLimit(1)
            if let suffix {
                Text("· \(suffix)")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
            }
            Spacer(minLength: 4)
            if loading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }
}
