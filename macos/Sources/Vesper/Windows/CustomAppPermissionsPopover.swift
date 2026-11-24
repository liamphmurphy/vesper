import SwiftUI
import VesperCore

/// Native SwiftUI popover anchored to a standalone Custom App window's Permissions toolbar button.
/// Shows granted/pending OS and bridge capabilities plus read-only host mounts, with instant toggles.
struct CustomAppPermissionsPopoverView: View {
    let slug: String
    let store: QueryStore
    let theme: ThemeTokens
    let onOpenInVesper: () -> Void

    @State private var updatingKey: String?
    @State private var errorMessage: String?

    private var detailRequest: APIRequest<API.CustomAppDetail> {
        API.getCustomApp(slug: slug)
    }

    var body: some View {
        let p = theme.palette
        let entry = store.entry(detailRequest)

        VStack(alignment: .leading, spacing: 0) {
            header(app: entry.data, p: p)
            Divider()

            if let app = entry.data {
                let snapshot = CustomAppStandaloneLogic.buildPermissions(from: app)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                Text(errorMessage)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        }

                        capabilitySection(
                            title: CustomAppStandaloneLogic.CapabilityGroup.os.title,
                            entries: snapshot.osCapabilities,
                            app: app,
                            p: p
                        )

                        capabilitySection(
                            title: CustomAppStandaloneLogic.CapabilityGroup.bridge.title,
                            entries: snapshot.bridgeCapabilities,
                            app: app,
                            p: p
                        )

                        if !snapshot.externalCapabilities.isEmpty {
                            capabilitySection(
                                title: CustomAppStandaloneLogic.CapabilityGroup.external.title,
                                entries: snapshot.externalCapabilities,
                                app: app,
                                p: p
                            )
                        }

                        if !snapshot.mounts.isEmpty {
                            mountsSection(mounts: snapshot.mounts, p: p)
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 420)
            } else if let error = entry.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn\u{2019}t load permissions")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(error.userMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.secondaryText)
                    Button("Retry") {
                        Task { _ = await store.refetch(detailRequest) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading permissions\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(p.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }

            Divider()

            HStack {
                Text("Changes apply immediately")
                    .font(.system(size: 11))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button {
                    onOpenInVesper()
                } label: {
                    Label("Open in Vesper", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(p.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 376)
        .background(p.background)
        .foregroundStyle(p.text)
        .environment(\.vesperTheme, theme)
        .environment(\.colorScheme, theme.mode == .dark ? .dark : .light)
        .onAppear {
            store.load(detailRequest)
        }
    }

    private func header(app: API.CustomAppDetail?, p: NativePalette) -> some View {
        let snapshot = app.map(CustomAppStandaloneLogic.buildPermissions)
        return HStack(spacing: 10) {
            Image(systemName: SidebarIcons.symbolName(AppsHomeLogic.resolveIcon(app?.icon)))
                .font(.system(size: 14))
                .foregroundStyle(p.text)
                .frame(width: 28, height: 28)
                .background(theme.swiftUIColor("surface-raised", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))

            VStack(alignment: .leading, spacing: 1) {
                Text(app?.name ?? slug)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                if let app, let snapshot {
                    Text("v\(app.currentSeq) \u{00B7} \(snapshot.allowedCount) allowed \u{00B7} \(snapshot.askCount) ask")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    Text("/apps/\(slug)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
            }

            Spacer(minLength: 4)

            if let pending = snapshot?.pendingRequestCount, pending > 0 {
                Text("\(pending) requested")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .purple))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.swiftUIColor("pill-human-bg", fallback: Color.purple.opacity(0.14)), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func capabilitySection(
        title: String,
        entries: [CustomAppStandaloneLogic.CapabilityEntry],
        app: API.CustomAppDetail,
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(p.tertiaryText)

            VStack(spacing: 8) {
                ForEach(entries) { cap in
                    capabilityRow(cap, app: app, p: p)
                }
            }
        }
    }

    private func capabilityRow(
        _ cap: CustomAppStandaloneLogic.CapabilityEntry,
        app: API.CustomAppDetail,
        p: NativePalette
    ) -> some View {
        let modeBinding = Binding<API.CustomAppCapabilityMode>(
            get: { cap.mode },
            set: { next in
                guard next != cap.mode else { return }
                setCapability(app: app, key: cap.key, mode: next)
            }
        )

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Text(cap.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                if cap.isPendingRequest {
                    Text("Requested")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .purple))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.swiftUIColor("pill-human-bg", fallback: Color.purple.opacity(0.14)), in: Capsule())
                }
                Spacer(minLength: 4)
                Picker(cap.label, selection: modeBinding) {
                    Text("Allow").tag(API.CustomAppCapabilityMode.allowed)
                    Text("Ask").tag(API.CustomAppCapabilityMode.requiresApproval)
                    Text("Deny").tag(API.CustomAppCapabilityMode.denied)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 146)
                .disabled(updatingKey != nil)
            }

            Text(cap.hint)
                .font(.system(size: 11))
                .foregroundStyle(p.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }

    private func mountsSection(mounts: [CustomAppStandaloneLogic.MountEntry], p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HOST MOUNTS (READ-ONLY)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button("Configure in Vesper") {
                    onOpenInVesper()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(p.accent)
            }

            VStack(spacing: 6) {
                ForEach(mounts) { mount in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: mount.isConfigured ? "folder.fill" : "folder.badge.questionmark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(mount.isConfigured ? p.secondaryText : p.tertiaryText)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mount.name)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(p.text)
                            if let path = mount.hostPath, !path.isEmpty {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(p.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(mount.description.map { "Not configured \u{00B7} \($0)" } ?? "Requested by manifest \u{00B7} not configured")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
            }
        }
    }

    private func setCapability(app: API.CustomAppDetail, key: String, mode: API.CustomAppCapabilityMode) {
        let nextCaps = CustomAppStandaloneLogic.updatedCapabilities(app.capabilities, key: key, mode: mode)
        updatingKey = key
        errorMessage = nil
        let req = detailRequest
        Task {
            defer { updatingKey = nil }
            do {
                _ = try await store.mutate(
                    API.updateCustomApp(slug: slug, body: API.UpdateCustomApp(capabilities: nextCaps)),
                    optimistic: [
                        .update(req) { cached in
                            cached.capabilities = nextCaps
                        },
                    ],
                    invalidating: QueryInvalidation(resources: ["custom-apps"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
