import SwiftUI
import VesperCore

/// Trailing metadata / side panel slot beside a Knowledge page.
///
/// **Seam for LAZYAGENTS-287** (native Backlinks, Links, Outline, Calendar & History panels):
/// provides a clean collapsible slot displaying page audience, mode, properties, tags, and
/// version history until LAZYAGENTS-287 replaces it with full native inspector tabs.
struct KnowledgePageSidePanelSlot: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info"
        case properties = "Properties"
        case history = "History"
        var id: String { rawValue }
    }

    @Environment(\.vesperTheme) private var theme
    let page: KnowledgePage
    let onSelectTag: (String) -> Void

    @State private var tab: Tab = .info

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            Picker("Side Panel", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(10)

            Divider().overlay(p.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .info:
                        infoContent
                    case .properties:
                        propertiesContent
                    case .history:
                        historyContent
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 272)
        .frame(maxHeight: .infinity)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    private var infoContent: some View {
        let p = theme.palette
        let modeText: String = {
            if page.paused { return "Persona edits paused" }
            if page.direct { return "Persona edits directly" }
            return "Persona suggests changes"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            detailRow(label: "Location", value: KnowledgeShellLogic.folderDisplay(of: page.path ?? ""))
            detailRow(label: "Audience", value: page.audience.rawValue.capitalized)
            detailRow(label: "Kind", value: page.kind.rawValue.capitalized)
            detailRow(label: "Version", value: "v\(page.seq)")
            detailRow(label: "Persona mode", value: modeText)
            detailRow(label: "Reviews", value: "\(page.reviews.count)")
            detailRow(label: "Embeds", value: "\(page.embeds.count)")

            let tags = KnowledgeShellLogic.tags(of: page.properties)
            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TAGS")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                onSelectTag(tag)
                            } label: {
                                Text("#\(tag)")
                                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                                    .foregroundStyle(p.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var propertiesContent: some View {
        let p = theme.palette
        let props = KnowledgeShellLogic.visibleProperties(page.properties)
        return VStack(alignment: .leading, spacing: 10) {
            if props.isEmpty {
                Text("No properties on this page.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
            } else {
                ForEach(props, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.key)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.secondaryText)
                        Text(KnowledgeShellLogic.formatPropertyValue(item.value))
                            .vesperText(.small, theme)
                            .foregroundStyle(p.text)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }
        }
    }

    private var historyContent: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            if page.versions.isEmpty {
                Text("No saved versions yet.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
            } else {
                ForEach(page.versions) { version in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(version.label.isEmpty ? "v\(version.seq)" : version.label)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                .foregroundStyle(p.text)
                            Spacer()
                            Text(KnowledgeShellLogic.relativeAgo(version.createdAt))
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                        }
                        if !version.note.isEmpty {
                            Text(version.note)
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(3)
                        }
                        Text(version.authorType == "agent" ? "Persona edit" : "You")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        let p = theme.palette
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.tertiaryText)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(p.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
