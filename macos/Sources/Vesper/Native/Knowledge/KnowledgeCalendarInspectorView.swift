import SwiftUI
import VesperCore

/// Native Knowledge inspector panel for Daily Notes calendar and Capture Inbox filing.
/// Replaces the web `knowledge.calendar` `/inspector-panel` tab.
struct KnowledgeCalendarInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var displayedYear: Int
    @State private var displayedMonth: Int
    @State private var openingDay: String?
    @State private var calendarError: String?

    private static let dailyNotesRequest = KnowledgeAPI.listPages(folder: "Daily", limit: 200)
    private static let inboxRequest = KnowledgeAPI.listPages(folder: "Inbox", limit: 20)

    init() {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        _displayedYear = State(initialValue: comps.year ?? 2026)
        _displayedMonth = State(initialValue: comps.month ?? 1)
    }

    var body: some View {
        let p = theme.palette
        let todayKey = KnowledgeCalendarLogic.isoDay(for: Date())
        let dailyRows = context.store.entry(Self.dailyNotesRequest).data?.rows ?? []
        let existingDays = Set(dailyRows.map(\.title))
        let inboxRows = context.store.entry(Self.inboxRequest).data?.rows ?? []
        let weeks = KnowledgeCalendarLogic.monthGrid(year: displayedYear, month: displayedMonth)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(KnowledgeCalendarLogic.monthTitle(year: displayedYear, month: displayedMonth).uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(p.tertiaryText)
                        Spacer()
                        Button {
                            let shifted = KnowledgeCalendarLogic.shiftedMonth(year: displayedYear, month: displayedMonth, delta: -1)
                            displayedYear = shifted.year
                            displayedMonth = shifted.month
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(p.tertiaryText)
                        .help("Previous month")
                        .accessibilityLabel("Previous month")

                        Button {
                            let shifted = KnowledgeCalendarLogic.shiftedMonth(year: displayedYear, month: displayedMonth, delta: 1)
                            displayedYear = shifted.year
                            displayedMonth = shifted.month
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(p.tertiaryText)
                        .help("Next month")
                        .accessibilityLabel("Next month")
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                        ForEach(Array(KnowledgeCalendarLogic.dayHeaders.enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 2)
                        }
                        ForEach(Array(weeks.flatMap { $0 }.enumerated()), id: \.offset) { _, day in
                            if let day {
                                let key = KnowledgeCalendarLogic.isoDay(year: displayedYear, month: displayedMonth, day: day)
                                let isToday = key == todayKey
                                let hasNote = existingDays.contains(key)
                                Button {
                                    openDailyNote(date: key)
                                } label: {
                                    ZStack(alignment: .bottom) {
                                        Text("\(day)")
                                            .font(.system(size: 13, weight: isToday ? .semibold : .regular))
                                            .foregroundStyle(isToday ? Color.white : p.text)
                                            .frame(width: 32, height: 30)
                                            .background(
                                                RoundedRectangle(cornerRadius: 7)
                                                    .fill(isToday ? p.accent : Color.clear)
                                            )
                                        if hasNote && !isToday {
                                            Circle()
                                                .fill(p.accent)
                                                .frame(width: 4, height: 4)
                                                .padding(.bottom, 3)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(openingDay != nil)
                                .accessibilityLabel(key)
                            } else {
                                Color.clear.frame(height: 30)
                            }
                        }
                    }

                    if let calendarError {
                        Text(calendarError)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("INBOX")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(p.tertiaryText)
                        if !inboxRows.isEmpty {
                            Text("\(inboxRows.count)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(p.tertiaryText)
                        }
                        Spacer()
                    }

                    if inboxRows.isEmpty {
                        Text("Nothing to file. Capture with \u{2325}\u{2318}N.")
                            .font(.system(size: 12))
                            .foregroundStyle(p.tertiaryText)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(inboxRows) { row in
                                KnowledgeInboxCaptureRow(row: row) {
                                    Task {
                                        _ = await context.store.refetch(Self.inboxRequest)
                                        _ = await context.store.refetch(Self.dailyNotesRequest)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .task {
            context.store.observe(Self.dailyNotesRequest)
            context.store.observe(Self.inboxRequest)
            context.store.load(Self.dailyNotesRequest)
            context.store.load(Self.inboxRequest)
        }
        .onDisappear {
            context.store.stopObserving(Self.dailyNotesRequest.key)
            context.store.stopObserving(Self.inboxRequest.key)
        }
    }

    private func openDailyNote(date: String) {
        openingDay = date
        calendarError = nil
        Task {
            defer { openingDay = nil }
            do {
                let page = try await context.store.mutate(
                    KnowledgeAPI.dailyNote(date: date),
                    invalidating: QueryInvalidation(resources: ["knowledge"])
                )
                context.navigate(KnowledgeShellLogic.pageHref(id: page.id, title: page.title))
            } catch {
                calendarError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private struct KnowledgeInboxCaptureRow: View {
    enum Mode { case file, merge }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let row: KnowledgePageRow
    let onFiled: () -> Void

    @State private var mode: Mode?
    @State private var inputText = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var mergeMatches: [KnowledgePageRow] {
        guard mode == .merge else { return [] }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return [] }
        let req = KnowledgeAPI.listPages(q: trimmed, limit: 6)
        return (context.store.entry(req).data?.rows ?? []).filter { $0.id != row.id }
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            Button {
                context.navigate(KnowledgeShellLogic.pageHref(id: row.id, title: row.title))
            } label: {
                Text(row.title.isEmpty ? "Untitled" : row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            Text(APIDate.shortAgo(row.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(p.tertiaryText)

            if let mode {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        mode == .file ? "Folder, e.g. Campaign/NPCs" : "Page to add it to",
                        text: $inputText
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(busy)
                    .onSubmit {
                        if mode == .file {
                            let folder = KnowledgeCalendarLogic.sanitizedFolder(inputText)
                            if !folder.isEmpty {
                                submitFile(folder: folder, merge: nil)
                            }
                        }
                    }
                    .onChange(of: inputText) { _, next in
                        if mode == .merge {
                            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.count > 1 {
                                context.store.load(KnowledgeAPI.listPages(q: trimmed, limit: 6))
                            }
                        }
                    }

                    if mode == .merge {
                        ForEach(mergeMatches) { target in
                            Button {
                                submitFile(folder: nil, merge: target.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(target.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(p.text)
                                        .lineLimit(1)
                                    let parentPath = target.path.split(separator: "/").dropLast().joined(separator: "/")
                                    if !parentPath.isEmpty {
                                        Text(parentPath)
                                            .font(.system(size: 11))
                                            .foregroundStyle(p.tertiaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                    }

                    HStack(spacing: 6) {
                        if mode == .file {
                            Button("File") {
                                let folder = KnowledgeCalendarLogic.sanitizedFolder(inputText)
                                if !folder.isEmpty {
                                    submitFile(folder: folder, merge: nil)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(busy || KnowledgeCalendarLogic.sanitizedFolder(inputText).isEmpty)
                        }
                        Button("Cancel") {
                            self.mode = nil
                            inputText = ""
                            errorMessage = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(busy)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Button("File into\u{2026}") {
                        mode = .file
                        inputText = ""
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Merge into\u{2026}") {
                        mode = .merge
                        inputText = ""
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func submitFile(folder: String?, merge: String?) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    KnowledgeAPI.fileCapture(id: row.id, folder: folder, merge: merge),
                    invalidating: QueryInvalidation(resources: ["knowledge"])
                )
                mode = nil
                inputText = ""
                onFiled()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
