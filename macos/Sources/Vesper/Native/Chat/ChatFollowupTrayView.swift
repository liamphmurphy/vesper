import SwiftUI
import VesperCore

/// Queued follow-up tray above the chat composer (`FollowupTray` in web).
/// Lists messages queued behind the running reply (or held after a stop/failure) with
/// Send now, Edit (back into the composer), and Remove actions.
struct ChatFollowupTrayView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let items: [API.ChatFollowup]
    let speakerName: String
    let isRunning: Bool
    let isHeld: Bool
    let disabled: Bool
    let onSendNow: @MainActor (String) async -> String?
    let onEdit: @MainActor (String) -> Void

    @State private var busyFollowupId: String?
    @State private var actionError: String?

    private static let maxVisibleRows = 5
    private static let approxRowHeight: CGFloat = 30

    private var followupsRequest: APIRequest<API.ChatFollowupList> {
        API.listChatFollowups(id: chatId)
    }

    private var isMutating: Bool { busyFollowupId != nil }

    var body: some View {
        let p = theme.palette
        let heldColor = theme.swiftUIColor("pill-human-fg", fallback: .orange)
        let heldBg = theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.15))
        let accentSoft = theme.swiftUIColor("accent-soft", fallback: p.selected)
        let tintColor = isHeld ? heldColor : p.accent
        let badgeBg = isHeld ? heldBg : accentSoft
        let header = ChatFollowupLogic.header(speakerName: speakerName, running: isRunning, held: isHeld)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: isHeld ? "pause.circle" : "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tintColor)

                Text(header)
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(items.count)")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))
                    .foregroundStyle(tintColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(badgeBg, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle()
                .fill(p.rowBorder)
                .frame(height: 1)

            if items.count > Self.maxVisibleRows {
                ScrollView {
                    rowsList(p: p)
                }
                .frame(height: CGFloat(Self.maxVisibleRows) * Self.approxRowHeight)
            } else {
                rowsList(p: p)
            }

            if let actionError {
                HStack(spacing: 6) {
                    Text(actionError)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Dismiss") { self.actionError = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }
        }
        .background(
            theme.swiftUIColor("surface-raised", fallback: p.surface),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tintColor.opacity(isHeld ? 0.35 : 0.28))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued follow-ups (\(items.count))")
        .onChange(of: chatId) { _, _ in
            actionError = nil
            busyFollowupId = nil
        }
    }

    private func rowsList(p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, followup in
                if index > 0 {
                    Rectangle()
                        .fill(p.rowBorder)
                        .frame(height: 1)
                }
                rowView(followup: followup, index: index, p: p)
            }
        }
    }

    private func rowView(followup: API.ChatFollowup, index: Int, p: NativePalette) -> some View {
        let fullText = ChatFollowupLogic.displayBody(followup.body)
        let preview = ChatFollowupLogic.previewText(followup.body)
        let rowBusy = busyFollowupId == followup.id

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                .foregroundStyle(p.tertiaryText)
                .frame(minWidth: 14, alignment: .trailing)
                .accessibilityHidden(true)

            Text(preview)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(fullText)

            Button {
                Task { await sendNow(followup) }
            } label: {
                Text("Send now")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(disabled || isMutating)
            .opacity(disabled || isMutating ? 0.5 : 1)
            .help(ChatFollowupLogic.sendNowTooltip(speakerName: speakerName, running: isRunning))

            Button {
                Task { await edit(followup) }
            } label: {
                Text("Edit")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isMutating)
            .opacity(isMutating ? 0.5 : 1)
            .help("Move back to composer to edit")

            Button {
                Task { await remove(followup) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isMutating)
            .opacity(isMutating ? 0.5 : 1)
            .accessibilityLabel("Remove follow-up \(index + 1)")
            .help("Remove queued message")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .opacity(rowBusy ? 0.6 : 1)
    }

    // MARK: - Actions

    private func sendNow(_ followup: API.ChatFollowup) async {
        busyFollowupId = followup.id
        actionError = nil
        defer { busyFollowupId = nil }

        let body = ChatFollowupLogic.displayBody(followup.body)
        if let err = await onSendNow(body) {
            actionError = err
            return
        }
        await deleteFollowup(id: followup.id, ignoreNotFound: true)
    }

    private func edit(_ followup: API.ChatFollowup) async {
        let originChatId = chatId
        busyFollowupId = followup.id
        actionError = nil
        defer { busyFollowupId = nil }

        let deleted = await deleteFollowup(id: followup.id, ignoreNotFound: false)
        if deleted, chatId == originChatId {
            onEdit(ChatFollowupLogic.displayBody(followup.body))
        }
    }

    private func remove(_ followup: API.ChatFollowup) async {
        busyFollowupId = followup.id
        actionError = nil
        defer { busyFollowupId = nil }

        _ = await deleteFollowup(id: followup.id, ignoreNotFound: true)
    }

    @discardableResult
    private func deleteFollowup(id followupId: String, ignoreNotFound: Bool) async -> Bool {
        let optimistic = OptimisticUpdate.update(followupsRequest) { list in
            list.followups.removeAll { $0.id == followupId }
        }
        do {
            _ = try await context.store.mutate(
                API.deleteChatFollowup(id: chatId, followupId: followupId),
                optimistic: [optimistic]
            )
            return true
        } catch let error as APIError {
            if ignoreNotFound, case .http(status: 404, _) = error {
                context.store.invalidate(QueryInvalidation(resources: ["chats"]))
                return true
            }
            actionError = error.userMessage
            return false
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}
