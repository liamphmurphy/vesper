import AppKit
import SwiftUI
import VesperCore

/// The compact top bar of the native inspector: tab icons, title, active tab header actions, and pop-out.
struct InspectorHeaderView: View {
    let tabs: TabsModel
    let isPoppedOut: Bool
    let onSelectTab: (String) -> Void
    let onHeaderAction: (String, String, String?) -> Void
    let onPopOutToggle: () -> Void

    var body: some View {
        let model = tabs.list.active?.state.inspector
        let active = InspectorLogic.activeTab(in: model)
        let popoutTabs = isPoppedOut ? (model?.tabs.filter { $0.kind != .web } ?? []) : []
        HStack(spacing: 6) {
            if popoutTabs.count > 1 {
                HStack(spacing: 2) {
                    ForEach(popoutTabs) { tab in
                        InspectorTabButton(
                            tab: tab,
                            selected: tab.id == active?.id,
                            action: { onSelectTab(tab.id) }
                        )
                    }
                }
            }
            if let active {
                Text(active.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            if let active, let actions = active.headerActions, !actions.isEmpty {
                ForEach(actions) { action in
                    InspectorHeaderActionButton(action: action) { menuId in
                        onHeaderAction(active.id, action.id, menuId)
                    }
                }
            }
            Button(action: onPopOutToggle) {
                Image(systemName: isPoppedOut ? "arrow.down.right.and.arrow.up.left" : "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isPoppedOut ? "Re-dock inspector" : "Pop out inspector")
            .accessibilityLabel(isPoppedOut ? "Re-dock inspector" : "Pop out inspector")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: SidebarIcons.symbolName(tab.icon))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.accentColor.opacity(0.15) : hovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if tab.unread == true {
                        Circle().fill(Color.purple).frame(width: 5, height: 5).padding(2)
                    } else if tab.busy == true {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct InspectorHeaderActionButton: View {
    let action: InspectorAction
    let onTrigger: (String?) -> Void

    var body: some View {
        Group {
            if let menu = action.menu, !menu.isEmpty {
                Button {
                    let ns = MenuBuilder.menu(from: menu) { onTrigger($0) }
                    ns.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                } label: {
                    buttonLabel
                }
            } else {
                Button { onTrigger(nil) } label: {
                    buttonLabel
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(action.disabled == true)
        .help(action.label)
        .accessibilityLabel(action.label)
    }

    private var buttonLabel: some View {
        Image(systemName: SidebarIcons.symbolName(action.icon ?? "dots"))
            .font(.system(size: 12))
            .foregroundStyle(action.destructive == true ? Color.red : action.accent == true ? Color.accentColor : Color.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

/// Hosts the native SwiftUI body for whichever native tab is active on the window's active tab.
struct InspectorBodyHost: View {
    let tabs: TabsModel
    let send: (NativeCommand) -> Void
    let navigate: (String, Bool) -> Void
    let openURL: (URL) -> Void

    var body: some View {
        let state = tabs.list.active?.state
        let model = state?.inspector
        if let active = InspectorLogic.activeTab(in: model), active.kind == .native {
            if let custom = state?.nativeInspectorView?(active.id) {
                // Do not wrap `custom` in `.frame(maxWidth: .infinity, maxHeight: .infinity)`:
                // inside `InspectorViewController`'s split pane (`sizingOptions = []`), a flexible
                // frame over `AnyView` triggers an AppKit `Update Constraints in Window` loop when
                // hosting `DockedChatView` (TextKit 2 `MarkdownTextView` + `ChatComposerSlot`).
                // `nativeHost.view` is already edge-pinned to `bodyContainer` via Auto Layout.
                custom
                    .id("\(model?.id ?? ""):\(active.id)")
            } else {
                InspectorBodyView(tab: active, send: send, navigate: navigate, openURL: openURL)
                    .id("\(model?.id ?? ""):\(active.id)")
            }
        } else if InspectorLogic.activeTab(in: model) == nil {
            Text("No inspector for this tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
        } else {
            Color.clear
        }
    }
}

/// Renders an `InspectorTab` of kind `.native` from declarative `InspectorSection` descriptions.
struct InspectorBodyView: View {
    let tab: InspectorTab
    let send: (NativeCommand) -> Void
    let navigate: (String, Bool) -> Void
    let openURL: (URL) -> Void

    @State private var collapsedSections: [String: Bool] = [:]

    var body: some View {
        let sections = tab.sections ?? []
        if sections.isEmpty {
            Text(tab.emptyText ?? "Nothing to inspect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        InspectorSectionView(
                            tabId: tab.id,
                            section: section,
                            collapsed: isCollapsed(section),
                            onToggleCollapse: { collapsedSections[section.id] = !isCollapsed(section) },
                            send: send,
                            navigate: navigate,
                            openURL: openURL
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private func isCollapsed(_ section: InspectorSection) -> Bool {
        collapsedSections[section.id] ?? section.collapsed ?? false
    }
}

private struct InspectorSectionView: View {
    let tabId: String
    let section: InspectorSection
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let send: (NativeCommand) -> Void
    let navigate: (String, Bool) -> Void
    let openURL: (URL) -> Void

    private var hasHeader: Bool {
        section.title != nil || section.aside != nil || section.badge != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasHeader {
                headerRow
            }
            if !collapsed {
                if section.items.isEmpty {
                    if let empty = section.emptyText {
                        Text(empty)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(section.items) { item in
                            InspectorItemView(
                                tabId: tabId,
                                item: item,
                                send: send,
                                navigate: navigate,
                                openURL: openURL
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var headerRow: some View {
        let content = HStack(spacing: 6) {
            if section.collapsible == true {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let title = section.title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let badge = section.badge {
                BadgeView(text: badge.text, tone: badge.tone)
            }
            Spacer(minLength: 4)
            if let aside = section.aside {
                Text(aside)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        if section.collapsible == true {
            Button(action: onToggleCollapse) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

private struct InspectorItemView: View {
    let tabId: String
    let item: InspectorItem
    let send: (NativeCommand) -> Void
    let navigate: (String, Bool) -> Void
    let openURL: (URL) -> Void

    private static let labelWidth: CGFloat = 82

    var body: some View {
        switch item.kind {
        case .fact:
            factView
        case .picker:
            pickerView
        case .segmented:
            segmentedView
        case .toggle:
            toggleView
        case .text:
            InspectorTextField(
                label: item.label,
                value: item.value ?? "",
                placeholder: item.placeholder ?? "",
                multiline: item.multiline == true,
                disabled: item.disabled == true,
                onCommit: { next in send(.inspectorChange(tabId: tabId, fieldId: item.id, value: next)) }
            )
        case .checklist:
            checklistView
        case .progress:
            progressView
        case .chips:
            chipsView
        case .list:
            listView
        case .actions:
            actionsView
        case .note:
            noteView
        case .chart:
            chartView
        }
    }

    // MARK: Fact

    private var factView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.icon != nil || item.label != nil {
                HStack(spacing: 5) {
                    if let icon = item.icon {
                        Image(systemName: SidebarIcons.symbolName(icon))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let label = item.label {
                        Text(label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: item.label != nil ? Self.labelWidth : nil, alignment: .leading)
            }
            Spacer(minLength: 6)
            factValueView
            if let badge = item.badge {
                BadgeView(text: badge.text, tone: badge.tone)
            }
        }
    }

    @ViewBuilder private var factValueView: some View {
        let text = item.value ?? item.detail ?? ""
        let font: Font = item.mono == true ? .system(.callout, design: .monospaced) : .callout
        let isInteractive = item.href != nil || item.url != nil || item.actionId != nil
        if isInteractive {
            Button {
                if let href = item.href {
                    let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                    navigate(href, newTab)
                } else if let raw = item.url, let url = URL(string: raw) {
                    openURL(url)
                } else if let actionId = item.actionId {
                    send(.inspectorAction(tabId: tabId, actionId: actionId, itemId: item.id, menuItemId: nil))
                }
            } label: {
                Text(text)
                    .font(font)
                    .foregroundStyle(item.tone?.color ?? Color.accentColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.plain)
            .disabled(item.disabled == true)
            .help(text)
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(item.tone?.color ?? Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: Picker & Segmented

    private var pickerView: some View {
        let options = item.options ?? []
        let current = item.value ?? ""
        let selection = Binding<String>(
            get: { current },
            set: { next in
                guard next != current else { return }
                send(.inspectorChange(tabId: tabId, fieldId: item.id, value: next))
            }
        )
        return HStack(spacing: 8) {
            if let label = item.label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .lineLimit(1)
            }
            Picker(item.label ?? item.id, selection: selection) {
                if !current.isEmpty && !options.contains(where: { $0.value == current }) {
                    Text(current).tag(current)
                }
                ForEach(options, id: \.value) { option in
                    if let icon = option.icon {
                        Label(option.label, systemImage: SidebarIcons.symbolName(icon)).tag(option.value)
                    } else {
                        Text(option.label).tag(option.value)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(item.disabled == true)
        }
    }

    private var segmentedView: some View {
        let options = item.options ?? []
        let current = item.value ?? ""
        let selection = Binding<String>(
            get: { current },
            set: { next in
                guard next != current else { return }
                send(.inspectorChange(tabId: tabId, fieldId: item.id, value: next))
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            if let label = item.label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker(item.label ?? item.id, selection: selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(item.disabled == true)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Toggle

    private var toggleView: some View {
        let isOn = Binding<Bool>(
            get: { item.checked == true },
            set: { next in send(.inspectorToggle(tabId: tabId, fieldId: item.id, checked: next)) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Text(item.label ?? item.id)
                        .font(.callout)
                    if let detail = item.detail, !detail.isEmpty, item.value != nil {
                        Spacer(minLength: 4)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(item.disabled == true)
            if let detail = item.detail, !detail.isEmpty, item.value == nil {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Checklist

    private var checklistView: some View {
        let steps = item.steps ?? []
        return VStack(alignment: .leading, spacing: 6) {
            if let label = item.label {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 7) {
                    if step.interactive == true {
                        Button {
                            send(.inspectorToggle(tabId: tabId, fieldId: step.id, checked: step.state != .done))
                        } label: {
                            stepSymbol(step.state)
                                .frame(width: 14, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.disabled == true)
                    } else {
                        stepSymbol(step.state)
                            .frame(width: 14, height: 16)
                    }
                    Text(step.text)
                        .font(.callout)
                        .foregroundStyle(step.state == .done ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func stepSymbol(_ state: InspectorStepState) -> some View {
        let (name, color): (String, Color) = switch state {
        case .done: ("checkmark.circle.fill", .green)
        case .current: ("circle.inset.filled", .accentColor)
        case .needsHuman: ("exclamationmark.circle.fill", .purple)
        case .failed: ("xmark.circle.fill", .orange)
        case .pending: ("circle", .secondary)
        }
        return Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(color)
    }

    // MARK: Progress

    private var progressView: some View {
        let clamped = min(max(item.fraction ?? 0, 0), 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let label = item.label {
                    Text(label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let detail = item.detail ?? item.value {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            ProgressView(value: clamped)
                .progressViewStyle(.linear)
                .tint((item.tone ?? .accent).color)
        }
    }

    // MARK: Chips

    private var chipsView: some View {
        let chips = item.chips ?? []
        let actionId = item.actionId ?? item.id
        return VStack(alignment: .leading, spacing: 6) {
            if let label = item.label {
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 5) {
                ForEach(chips) { chip in
                    HStack(spacing: 4) {
                        if let color = Color(cssHex: chip.color) {
                            Circle().fill(color).frame(width: 7, height: 7)
                        } else if let icon = chip.icon {
                            Image(systemName: SidebarIcons.symbolName(icon))
                                .font(.system(size: 10))
                                .foregroundStyle(chip.tone?.color ?? Color.secondary)
                        }
                        if let href = chip.href {
                            Button {
                                let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                                navigate(href, newTab)
                            } label: {
                                Text(chip.text).font(.caption).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(chip.text).font(.caption).lineLimit(1)
                        }
                        if chip.removable == true {
                            Button {
                                send(.inspectorAction(tabId: tabId, actionId: actionId, itemId: chip.id, menuItemId: nil))
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(chip.text)")
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                if let menu = item.menu, !menu.isEmpty {
                    Button {
                        let ns = MenuBuilder.menu(from: menu) { menuId in
                            send(.inspectorAction(tabId: tabId, actionId: actionId, itemId: nil, menuItemId: menuId))
                        }
                        ns.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help(item.placeholder ?? "Add")
                }
            }
        }
    }

    // MARK: List

    private var listView: some View {
        let rows = item.rows ?? []
        let actionId = item.actionId ?? item.id
        return VStack(alignment: .leading, spacing: 3) {
            if let label = item.label {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            ForEach(rows) { row in
                Button {
                    if let href = row.href {
                        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                        navigate(href, newTab)
                    } else {
                        send(.inspectorAction(tabId: tabId, actionId: actionId, itemId: row.id, menuItemId: nil))
                    }
                } label: {
                    HStack(spacing: 7) {
                        if let status = row.status {
                            Circle().fill(status.color).frame(width: 6, height: 6)
                        }
                        if let avatar = row.avatar {
                            AvatarView(avatar: avatar)
                        } else if let icon = row.icon {
                            Image(systemName: SidebarIcons.symbolName(icon))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let subtitle = row.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if let trailing = row.trailing, !trailing.isEmpty {
                            Text(trailing)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let badge = row.badge {
                            BadgeView(text: badge.text, tone: badge.tone)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.disabled == true)
                .contextMenu {
                    if let menu = row.contextMenu, !menu.isEmpty {
                        MenuItems(items: menu) { menuId in
                            send(.inspectorAction(tabId: tabId, actionId: actionId, itemId: row.id, menuItemId: menuId))
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actionsView: some View {
        let actions = item.actions ?? []
        return FlowLayout(spacing: 6) {
            ForEach(actions) { action in
                InspectorActionPill(action: action) { menuId in
                    send(.inspectorAction(tabId: tabId, actionId: action.id, itemId: item.id, menuItemId: menuId))
                }
            }
        }
    }

    // MARK: Note

    private var noteView: some View {
        let tint: Color = item.tone?.color.opacity(0.10) ?? Color.primary.opacity(0.05)
        return VStack(alignment: .leading, spacing: 3) {
            if let label = item.label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.tone?.color ?? Color.secondary)
            }
            if let text = item.value ?? item.detail, !text.isEmpty {
                Text(text)
                    .font(item.mono == true ? .system(.caption, design: .monospaced) : .callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint))
    }

    // MARK: Chart

    private var chartView: some View {
        let points = item.points ?? []
        return VStack(alignment: .leading, spacing: 4) {
            if let label = item.label {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            InspectorChartCanvas(points: points)
        }
    }
}

private struct InspectorActionPill: View {
    let action: InspectorAction
    let onTrigger: (String?) -> Void

    var body: some View {
        Group {
            if action.accent == true || action.active == true {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .tint(action.destructive == true ? Color.red : nil)
        .disabled(action.disabled == true)
    }

    @ViewBuilder private var button: some View {
        if let menu = action.menu, !menu.isEmpty {
            Button(role: action.destructive == true ? .destructive : nil) {
                let ns = MenuBuilder.menu(from: menu) { onTrigger($0) }
                ns.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } label: {
                buttonLabel
            }
        } else {
            Button(role: action.destructive == true ? .destructive : nil) {
                onTrigger(nil)
            } label: {
                buttonLabel
            }
        }
    }

    @ViewBuilder private var buttonLabel: some View {
        if let icon = action.icon {
            Label(action.label, systemImage: SidebarIcons.symbolName(icon))
        } else {
            Text(action.label)
        }
    }
}

private struct InspectorTextField: View {
    let label: String?
    let value: String
    let placeholder: String
    let multiline: Bool
    let disabled: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Group {
                    if multiline {
                        TextField("", text: $draft, prompt: Text(placeholder), axis: .vertical)
                            .lineLimit(2...6)
                    } else {
                        TextField("", text: $draft, prompt: Text(placeholder))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .disabled(disabled)
                .onSubmit { commit() }

                if !draft.isEmpty && !disabled {
                    Button {
                        draft = ""
                        onCommit("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in
            if !focused, newValue != draft { draft = newValue }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value {
            onCommit(trimmed)
        }
    }
}

private struct InspectorChartCanvas: View {
    let points: [InspectorBarPoint]

    var body: some View {
        let maxVal = max(points.flatMap { [$0.value, $0.secondary ?? 0] }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                guard points.count >= 2, size.width > 4, size.height > 4 else { return }
                let stepX = size.width / CGFloat(points.count - 1)
                func y(_ v: Double) -> CGFloat {
                    let norm = CGFloat(min(max(v / maxVal, 0), 1))
                    return size.height - 4 - norm * (size.height - 8)
                }
                if points.contains(where: { $0.secondary != nil }) {
                    var targetPath = Path()
                    for (idx, pt) in points.enumerated() {
                        let p = CGPoint(x: CGFloat(idx) * stepX, y: y(pt.secondary ?? pt.value))
                        if idx == 0 { targetPath.move(to: p) } else { targetPath.addLine(to: p) }
                    }
                    ctx.stroke(targetPath, with: .color(Color.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                var line = Path()
                var area = Path()
                for (idx, pt) in points.enumerated() {
                    let p = CGPoint(x: CGFloat(idx) * stepX, y: y(pt.value))
                    if idx == 0 {
                        line.move(to: p)
                        area.move(to: CGPoint(x: p.x, y: size.height))
                        area.addLine(to: p)
                    } else {
                        line.addLine(to: p)
                        area.addLine(to: p)
                    }
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(Color.accentColor.opacity(0.16)))
                ctx.stroke(line, with: .color(Color.accentColor), lineWidth: 1.5)
            }
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

            if let first = points.first, let last = points.last {
                HStack {
                    Text(first.label)
                    Spacer(minLength: 4)
                    Text("\(Int(last.value.rounded())) / \(Int(maxVal.rounded())) pts")
                    Spacer(minLength: 4)
                    Text(last.label)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
