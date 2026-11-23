import SwiftUI
import VesperCore

// MARK: - Timeline & Waterfall Card View (LAZYAGENTS-320)

struct ChatTimelineCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatTimelineSpec

    @State private var hoveredItemID: Int?
    @State private var showLightbox = false

    private var viz: ChatVizPalette { ChatVizPalette(theme: theme) }

    var body: some View {
        ChatVizCard(
            icon: "timeline.selection",
            title: spec.title ?? "Timeline",
            subtitle: spec.subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            Text("\(spec.items.count) \(spec.items.count == 1 ? "item" : "items")")
                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
        } content: {
            timelineBody(minTrackWidth: 380)
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Timeline", subtitle: spec.subtitle) {
                timelineBody(minTrackWidth: 700)
            }
        }
    }

    private func timelineBody(minTrackWidth: CGFloat) -> some View {
        let p = theme.palette
        let ticks = spec.axisTicks(count: 5)
        let palette = viz

        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Top time axis header
                HStack(spacing: 0) {
                    Text("Lane")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                        .frame(width: 112, alignment: .leading)
                        .padding(.horizontal, 10)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            ForEach(Array(ticks.enumerated()), id: \.offset) { idx, tick in
                                let x = geo.size.width * tick.fraction
                                Text(tick.label)
                                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                    .foregroundStyle(p.tertiaryText)
                                    .position(
                                        x: idx == 0 ? 22 : (idx == ticks.count - 1 ? max(22, geo.size.width - 26) : x),
                                        y: geo.size.height / 2
                                    )
                            }
                        }
                    }
                    .frame(minWidth: minTrackWidth, minHeight: 24, maxHeight: 24)
                }
                .padding(.vertical, 4)
                .background(p.surface.opacity(0.5))

                ForEach(Array(spec.lanes.enumerated()), id: \.element) { laneIdx, lane in
                    let laneItems = spec.items.filter { $0.lane == lane }
                    let laneColor = palette.seriesColor(at: laneIdx)
                    Rectangle().fill(p.rowBorder).frame(height: 1)
                    HStack(alignment: .top, spacing: 0) {
                        Text(lane)
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(2)
                            .frame(width: 112, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(laneItems) { item in
                                timelineRow(item: item, defaultColor: laneColor, ticks: ticks)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.trailing, 14)
                        .frame(minWidth: minTrackWidth, maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func timelineRow(item: ChatTimelineItem, defaultColor: Color, ticks: [ChatTimelineTick]) -> some View {
        let p = theme.palette
        let color = item.tone != nil ? ChatVizPalette.toneColor(item.tone, theme: theme) : defaultColor
        let isHovered = hoveredItemID == item.id
        let startFrac = spec.fraction(for: item.start)
        let endFrac = spec.fraction(for: item.end ?? item.start)

        return GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let x0 = startFrac * w
            let barWidth = item.isPoint ? 10 : max(8, (endFrac - startFrac) * w)

            ZStack(alignment: .leading) {
                // Subtle vertical tick guides
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    Rectangle()
                        .fill(viz.grid)
                        .frame(width: 1, height: 24)
                        .offset(x: tick.fraction * w)
                }

                if item.isPoint {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                        .offset(x: max(0, x0 - 5))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(isHovered ? 0.95 : 0.78))
                        .frame(width: barWidth, height: 18)
                        .offset(x: x0)
                }

                let labelText = item.annotation.map { "\(item.label) · \($0)" } ?? item.label
                let fitsInside = !item.isPoint && barWidth > 120
                let labelX: CGFloat = fitsInside ? (x0 + 6) : min(max(0, x0 + barWidth + 6), max(0, w - 130))

                Text(labelText)
                    .font(.system(size: theme.pointSize(.micro), weight: isHovered ? .semibold : .medium))
                    .foregroundStyle(fitsInside ? Color.white : p.text)
                    .lineLimit(1)
                    .offset(x: labelX)
            }
        }
        .frame(height: 24)
        .onHover { inside in
            hoveredItemID = inside ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
        .help(item.annotation.map { "\(item.label) (\($0))" } ?? item.label)
    }
}

// MARK: - Collapsible Tree Card View (LAZYAGENTS-323)

struct ChatTreeCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatTreeSpec

    @State private var expanded: Set<String>

    init(spec: ChatTreeSpec) {
        self.spec = spec
        self._expanded = State(initialValue: spec.allExpandableIDs)
    }

    var body: some View {
        let p = theme.palette
        let allIDs = spec.allExpandableIDs

        ChatVizCard(
            icon: "list.bullet.indent",
            title: spec.title ?? "Tree",
            supportsLightbox: false
        ) {
            if !allIDs.isEmpty {
                HStack(spacing: 8) {
                    Button("Expand all") { expanded = allIDs }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(expanded.count == allIDs.count ? p.tertiaryText : p.secondaryText)
                        .disabled(expanded.count == allIDs.count)

                    Button("Collapse all") { expanded.removeAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(expanded.isEmpty ? p.tertiaryText : p.secondaryText)
                        .disabled(expanded.isEmpty)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(spec.roots) { root in
                    ChatTreeNodeRowView(node: root, depth: 0, expanded: $expanded)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
    }
}

private struct ChatTreeNodeRowView: View {
    @Environment(\.vesperTheme) private var theme

    let node: ChatTreeNode
    let depth: Int
    @Binding var expanded: Set<String>

    private var hasChildren: Bool { !node.children.isEmpty }
    private var isOpen: Bool { expanded.contains(node.id) }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if hasChildren {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id) }
                        }
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }

                Image(systemName: node.isFolder ? (isOpen && hasChildren ? "folder.fill" : "folder") : "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(node.isFolder ? p.accent : p.secondaryText)

                Text(node.label)
                    .font(.system(size: theme.pointSize(.small), weight: node.isFolder ? .medium : .regular, design: .monospaced))
                    .foregroundStyle(p.text)
                    .textSelection(.enabled)

                if let note = node.annotation, !note.isEmpty {
                    Text(note)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(depth * 16))
            .padding(.vertical, 2)

            if hasChildren && isOpen {
                ForEach(node.children) { child in
                    ChatTreeNodeRowView(node: child, depth: depth + 1, expanded: $expanded)
                }
            }
        }
    }
}

// MARK: - Before/After Image Comparison Slider (LAZYAGENTS-325)

struct ChatCompareImagesCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatCompareImagesSpec

    @State private var split: Double = 0.5
    @State private var sideBySide = false
    @State private var showLightbox = false

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "rectangle.split.2x1",
            title: spec.title ?? "Image Comparison",
            subtitle: spec.subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            HStack(spacing: 4) {
                Button("Slider") { sideBySide = false }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small), weight: !sideBySide ? .medium : .regular))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(!sideBySide ? p.text : p.tertiaryText)
                    .background(!sideBySide ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 4))

                Button("Side by Side") { sideBySide = true }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small), weight: sideBySide ? .medium : .regular))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(sideBySide ? p.text : p.tertiaryText)
                    .background(sideBySide ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        } content: {
            comparisonBody(height: 320)
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Image Comparison", subtitle: "\(spec.beforeLabel) vs \(spec.afterLabel)") {
                comparisonBody(height: 520)
            }
        }
    }

    @ViewBuilder
    private func comparisonBody(height: CGFloat) -> some View {
        let p = theme.palette
        if sideBySide {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.beforeLabel)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                    ChatResolvedImageView(ref: spec.before)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: height)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.afterLabel)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                    ChatResolvedImageView(ref: spec.after)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: height)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 8) {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let dividerX = w * split

                    ZStack {
                        // After image (full width, fit without distortion)
                        ChatResolvedImageView(ref: spec.after)
                            .frame(width: geo.size.width, height: geo.size.height)

                        // Before image clipped to left of divider
                        ChatResolvedImageView(ref: spec.before)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: dividerX, height: geo.size.height)
                            }

                        // Labels
                        HStack {
                            Text(spec.beforeLabel)
                                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                            Spacer()
                            Text(spec.afterLabel)
                                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(10)
                        .frame(maxHeight: .infinity, alignment: .top)

                        // Vertical divider line + handle
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: geo.size.height)
                            .shadow(color: .black.opacity(0.45), radius: 2)
                            .position(x: dividerX, y: geo.size.height / 2)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.8))
                            )
                            .shadow(color: .black.opacity(0.35), radius: 3)
                            .position(x: dividerX, y: geo.size.height / 2)
                    }
                    .background(p.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                split = max(0.02, min(0.98, value.location.x / w))
                            }
                    )
                }
                .frame(height: height)

                // Keyboard-accessible slider fallback for full accessibility
                HStack(spacing: 8) {
                    Text(spec.beforeLabel)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                    Slider(value: $split, in: 0.02...0.98)
                        .accessibilityLabel("Image comparison divider")
                    Text(spec.afterLabel)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(12)
        }
    }
}

private struct ChatResolvedImageView: View {
    @Environment(\.vesperTheme) private var theme
    let ref: ChatImageRef
    @State private var useFallback = false

    private var activeSource: String {
        if useFallback, let fallback = ref.fallbackPath { return fallback }
        return ref.primaryPath
    }

    var body: some View {
        AuthenticatedImageView(source: activeSource, maxPixel: 1400) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } placeholder: {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } failure: {
            VStack(spacing: 4) {
                Image(systemName: "photo")
                    .foregroundStyle(theme.palette.tertiaryText)
                Text("Image unavailable")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                if !useFallback, ref.fallbackPath != nil {
                    useFallback = true
                }
            }
        }
        .id(activeSource)
    }
}
