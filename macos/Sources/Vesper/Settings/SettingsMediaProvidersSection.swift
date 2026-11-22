import SwiftUI
import VesperCore

/// Workspace Settings section for pluggable media providers (Lyria music, Gemini Omni video,
/// and Gemini TTS persona voices) and workspace capability defaults.
struct SettingsMediaProvidersSection: View {
    let aux: AuxWindows

    @State private var settingDefault = false
    @State private var defaultError: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let entry = store?.entry(API.listMediaProviders())

        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(
                "Media providers",
                subtitle: "Configure providers and models for music (Lyria), video (Gemini Omni), and persona voices (TTS)."
            ) {
                if let defaultError {
                    SettingsBanner(tone: .blocked, title: "Couldn't update active engine", message: defaultError)
                }

                if let data = entry?.data {
                    let groups = MediaProviderHelpers.capabilityGroups(in: data)
                    if groups.isEmpty {
                        Text("No media providers are registered.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            capabilityRow(group)
                            if index < groups.count - 1 {
                                Divider()
                            }
                        }
                    }
                } else if entry?.isFetching == true {
                    ProgressView().controlSize(.small)
                } else {
                    SettingsUnavailableCard(title: "Couldn't load media providers", error: entry?.error) {
                        Task { await store?.refetch(API.listMediaProviders()) }
                    }
                }
            }

            if let providers = entry?.data?.providers {
                ForEach(providers, id: \.id) { provider in
                    MediaProviderCard(aux: aux, provider: provider)
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(_ group: MediaCapabilityGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Active \(group.label.lowercased()) engine")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let active = group.active {
                    Text("Using \(active.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if group.providers.count > 1 {
                ForEach(group.providers, id: \.id) { provider in
                    let selected = group.selectedId == provider.id
                    let disabled = settingDefault || provider.comingSoon || !provider.available || !provider.enabled
                    Button {
                        if !selected && !disabled {
                            setDefault(capability: group.capability, providerId: provider.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.label).font(.callout.weight(.medium))
                                    if provider.comingSoon {
                                        SettingsBadge(label: "Soon", tone: .neutral)
                                    }
                                }
                                Text(provider.available ? (provider.description ?? "Ready.") : (provider.unavailableReason ?? "Not configured yet."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .opacity(disabled ? 0.65 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
            } else if let only = group.providers.first {
                let status = MediaProviderHelpers.providerStatus(only)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(only.label).font(.callout.weight(.medium))
                        Text(only.available ? (only.description ?? "Ready.") : (only.unavailableReason ?? "Not configured yet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    SettingsBadge(label: status.label, tone: status.tone)
                }
            }
        }
    }

    private func setDefault(capability: API.MediaCapability, providerId: String) {
        guard let store else { return }
        settingDefault = true
        defaultError = nil
        Task {
            defer { settingDefault = false }
            do {
                let updated = try await store.mutate(
                    API.setMediaDefault(capability: capability, body: API.SetMediaDefaultRequest(providerId: providerId))
                )
                store.setData(updated, for: API.listMediaProviders())
                if capability == .tts {
                    await store.refetch(API.listPersonaVoices())
                }
            } catch {
                defaultError = settingsErrorText(error)
            }
        }
    }
}

private struct MediaProviderCard: View {
    let aux: AuxWindows
    let provider: API.MediaProvider

    @State private var draftSettings: [String: String] = [:]
    @State private var draftSecrets: [String: String] = [:]
    @State private var saving = false
    @State private var clearingSecret = false
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var checkResult: API.MediaProviderCheckResponse?

    private var store: QueryStore? { aux.store }
    private var busy: Bool { saving || clearingSecret || checking }

    var body: some View {
        let effective = MediaProviderHelpers.effectiveSettings(for: provider, draftSettings: draftSettings)
        let visible = MediaProviderHelpers.visibleFields(for: provider, settings: effective)
        let status = MediaProviderHelpers.providerStatus(provider)
        let dirty = MediaProviderHelpers.hasDirtyChanges(
            for: provider,
            draftSettings: draftSettings,
            draftSecrets: draftSecrets
        )

        SettingsCard(provider.label, subtitle: provider.description) {
            HStack(spacing: 6) {
                ForEach(provider.capabilities, id: \.rawValue) { cap in
                    SettingsBadge(label: MediaProviderHelpers.capabilityPillLabel(cap), tone: .neutral)
                }
                SettingsBadge(label: status.label, tone: status.tone)
            }
        } content: {
            if provider.comingSoon {
                Text(provider.unavailableReason ?? "Support for this provider will arrive in a future release.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visible, id: \.key) { field in
                        fieldRow(field, effective: effective)
                    }

                    if let errorMessage {
                        SettingsBanner(tone: .blocked, title: "Couldn't update \(provider.label)", message: errorMessage)
                    }

                    if let checkResult {
                        SettingsBanner(
                            tone: checkResult.ok ? .done : .blocked,
                            title: checkResult.ok ? "Connection verified" : "Connection check failed",
                            message: checkResult.message
                        )
                    }

                    if let statusMessage {
                        SettingsBanner(tone: .done, title: statusMessage)
                    }

                    HStack {
                        Spacer()
                        Button(checking ? "Checking…" : "Test connection") {
                            checkConnection()
                        }
                        .disabled(busy || !provider.available || dirty)

                        Button(saving ? "Saving…" : "Save") {
                            save()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !dirty)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: API.MediaFieldSpec, effective: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .segmented:
                let options = field.options ?? []
                Picker(field.label, selection: settingBinding(for: field.key, effective: effective)) {
                    ForEach(options, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(busy)

            case .select:
                let options = field.options ?? []
                let current = effective[field.key] ?? ""
                Picker(field.label, selection: settingBinding(for: field.key, effective: effective)) {
                    ForEach(options, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                    if !current.isEmpty && !options.contains(where: { $0.value == current }) {
                        Text(current).tag(current)
                    }
                }
                .pickerStyle(.menu)
                .disabled(busy)

            case .secret:
                let isSet = provider.secretsSet[field.key] == true
                let placeholder = isSet
                    ? "•••••••• (configured — enter new key to replace)"
                    : (field.placeholder ?? "Enter key…")
                Text(field.label)
                    .font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    SecureField(placeholder, text: secretBinding(for: field.key))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .disabled(busy)
                    if isSet {
                        Button("Clear") {
                            clearSecret(field.key)
                        }
                        .disabled(busy)
                    }
                }

            default:
                Text(field.label)
                    .font(.callout.weight(.medium))
                TextField(field.placeholder ?? "", text: settingBinding(for: field.key, effective: effective))
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
            }

            if let help = field.help, !help.isEmpty {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingBinding(for key: String, effective: [String: String]) -> Binding<String> {
        Binding(
            get: { effective[key] ?? "" },
            set: { next in
                checkResult = nil
                statusMessage = nil
                errorMessage = nil
                draftSettings[key] = next
            }
        )
    }

    private func secretBinding(for key: String) -> Binding<String> {
        Binding(
            get: { draftSecrets[key] ?? "" },
            set: { next in
                checkResult = nil
                statusMessage = nil
                errorMessage = nil
                draftSecrets[key] = next
            }
        )
    }

    private func save() {
        guard let store else { return }
        saving = true
        errorMessage = nil
        statusMessage = nil
        checkResult = nil
        let body = MediaProviderHelpers.buildProviderPatch(
            for: provider,
            draftSettings: draftSettings,
            draftSecrets: draftSecrets
        )
        Task {
            defer { saving = false }
            do {
                _ = try await store.mutate(API.updateMediaProvider(id: provider.id, body: body))
                await store.refetch(API.listMediaProviders())
                draftSettings = [:]
                draftSecrets = [:]
                statusMessage = "Saved \(provider.label)."
                await store.refetch(API.listPersonaVoices())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func clearSecret(_ field: String) {
        guard let store else { return }
        clearingSecret = true
        errorMessage = nil
        statusMessage = nil
        checkResult = nil
        Task {
            defer { clearingSecret = false }
            do {
                _ = try await store.mutate(API.clearMediaProviderSecret(id: provider.id, field: field))
                await store.refetch(API.listMediaProviders())
                draftSecrets.removeValue(forKey: field)
                statusMessage = "Removed \(provider.label) key."
                await store.refetch(API.listPersonaVoices())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func checkConnection() {
        guard let store else { return }
        checking = true
        errorMessage = nil
        statusMessage = nil
        checkResult = nil
        Task {
            defer { checking = false }
            do {
                checkResult = try await store.mutate(API.checkMediaProvider(id: provider.id))
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
