import SwiftUI
import UniformTypeIdentifiers
import VesperCore

struct SettingsAppearancePane: View {
    let aux: AuxWindows

    @State private var editMode: ColorMode = .dark
    @State private var activeKey: String = "bg"
    @State private var hexInput: String = ""
    @State private var hexError: String?
    @State private var statusMessage: String?
    @State private var showAdvancedColors = false

    private var pref: AppearancePreference {
        aux.app?.settings.settings.effectiveAppearance ?? .macOSDefault
    }

    private func updatePref(_ mutate: (inout AppearancePreference) -> Void) {
        aux.update { s in
            var next = s.effectiveAppearance
            mutate(&next)
            s.appearance = next
        }
    }

    var body: some View {
        let current = pref
        let colors = PaletteTokens.resolvedRawTokens(for: current, mode: editMode)
        let isCustom = current.palette == "custom"
        let overrides = editMode == .dark ? current.custom.dark : current.custom.light
        let warnings = PaletteTokens.contrastWarnings(for: colors)

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Appearance",
                subtitle: "Theme mode, text scaling, and color palettes across native and web screens."
            )

            SettingsCard {
                LabeledContent("Mode") {
                    Picker("Mode", selection: Binding(
                        get: { current.mode },
                        set: { mode in updatePref { $0.mode = mode } }
                    )) {
                        Text("System").tag(AppearanceMode.system)
                        Text("Dark").tag(AppearanceMode.dark)
                        Text("Light").tag(AppearanceMode.light)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                Text("System follows macOS. Palette is independent of mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                LabeledContent("Text size") {
                    HStack(spacing: 8) {
                        Picker("Text size", selection: Binding(
                            get: { current.textSize },
                            set: { size in updatePref { $0.textSize = size } }
                        )) {
                            Text("Small").tag(AppearanceTextSize.small)
                            Text("Default").tag(AppearanceTextSize.default)
                            Text("Large").tag(AppearanceTextSize.large)
                            Text("Larger").tag(AppearanceTextSize.larger)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)

                        HStack(spacing: 4) {
                            Button {
                                updatePref { $0.textSize = $0.textSize.steppedOut() }
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: 16, height: 16)
                            }
                            .disabled(!current.textSize.canStepOut)
                            .help("Zoom Out (⌘-)")

                            Text(current.textSize.percentLabel)
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 38, alignment: .center)

                            Button {
                                updatePref { $0.textSize = $0.textSize.steppedIn() }
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 16, height: 16)
                            }
                            .disabled(!current.textSize.canStepIn)
                            .help("Zoom In (⌘+)")
                        }
                    }
                }
                Text("Scales UI and editor text across Vesper (80%–175%). Use ⌘+, ⌘-, and ⌘0 anywhere. Exported documents keep their own print sizes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Color palette", subtitle: "Select a preset or customize every token for Dark and Light modes.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 10)], spacing: 10) {
                    ForEach(PaletteTokens.presets) { preset in
                        paletteCard(
                            id: preset.id,
                            name: preset.name,
                            description: preset.description,
                            dark: preset.dark,
                            light: preset.light,
                            selected: current.palette == preset.id
                        )
                    }
                    let customDark = PaletteTokens.resolvedRawTokens(
                        for: AppearancePreference(palette: "custom", custom: current.custom),
                        mode: .dark
                    )
                    let customLight = PaletteTokens.resolvedRawTokens(
                        for: AppearancePreference(palette: "custom", custom: current.custom),
                        mode: .light
                    )
                    paletteCard(
                        id: "custom",
                        name: "Custom",
                        description: "Your own colors",
                        dark: customDark,
                        light: customLight,
                        selected: isCustom
                    )
                }

                HStack(spacing: 8) {
                    if !isCustom {
                        Button("Customize this palette") {
                            updatePref { p in
                                let base = p.palette == "custom" ? p.custom.base : p.palette
                                p.palette = "custom"
                                p.custom = CustomPaletteOverrides(base: base, dark: [:], light: [:])
                            }
                        }
                    }
                    Button("Export palette…") { exportPalette(current) }
                    Button("Import palette…") { importPalette(current) }
                    Button("Reset palette") {
                        updatePref { p in
                            let keepSize = p.textSize
                            let keepMode = p.mode
                            p = .macOSDefault
                            p.textSize = keepSize
                            p.mode = keepMode
                        }
                        statusMessage = "Palette reset to macOS default."
                    }
                    Spacer()
                }
                .padding(.top, 4)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isCustom {
                SettingsCard("Customize palette") {
                    HStack {
                        Picker("Base palette", selection: Binding(
                            get: { current.custom.base },
                            set: { base in updatePref { $0.custom.base = base } }
                        )) {
                            ForEach(PaletteTokens.presets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .frame(width: 240)

                        Spacer()

                        Picker("Variant", selection: $editMode) {
                            Text("Dark colors").tag(ColorMode.dark)
                            Text("Light colors").tag(ColorMode.light)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    previewCard(colors: colors)

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(PaletteTokens.editorGroups, id: \.label) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.label).font(.subheadline.weight(.medium))
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 6)], spacing: 6) {
                                        ForEach(group.keys, id: \.self) { key in
                                            tokenButton(key: key, hex: colors[key] ?? "#000000", customized: overrides[key] != nil)
                                        }
                                    }
                                }
                            }
                            DisclosureGroup("Advanced color overrides", isExpanded: $showAdvancedColors) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 6)], spacing: 6) {
                                    ForEach(PaletteTokens.advancedColorKeys, id: \.self) { key in
                                        tokenButton(key: key, hex: colors[key] ?? "#000000", customized: overrides[key] != nil)
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(PaletteTokens.tokenTitle(activeKey))
                                .font(.headline)
                            Text(activeKey)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            ColorPicker(
                                "Color",
                                selection: Binding(
                                    get: { Color(cssHex: colors[activeKey]) ?? .accentColor },
                                    set: { picked in
                                        if let hex = hexString(from: picked) {
                                            setOverride(key: activeKey, hex: hex)
                                            hexInput = hex
                                            hexError = nil
                                        }
                                    }
                                ),
                                supportsOpacity: false
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hex (#rrggbb)").font(.caption).foregroundStyle(.secondary)
                                TextField("#000000", text: $hexInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout.monospaced())
                                    .onChange(of: hexInput) { _, val in
                                        let normalized = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                        if PaletteTokens.isOpaqueHex(normalized) {
                                            hexError = nil
                                            setOverride(key: activeKey, hex: normalized)
                                        } else {
                                            hexError = "Enter #rrggbb (e.g. #7864d9)."
                                        }
                                    }
                                if let hexError {
                                    Text(hexError).font(.caption).foregroundStyle(.red)
                                }
                            }

                            Button("Reset this color") {
                                updatePref { p in
                                    if editMode == .dark { p.custom.dark.removeValue(forKey: activeKey) }
                                    else { p.custom.light.removeValue(forKey: activeKey) }
                                }
                            }
                            .disabled(overrides[activeKey] == nil)

                            Button("Reset \(editMode == .dark ? "dark" : "light") colors") {
                                updatePref { p in
                                    if editMode == .dark { p.custom.dark.removeAll() }
                                    else { p.custom.light.removeAll() }
                                }
                            }
                            .disabled(overrides.isEmpty)
                        }
                        .padding(12)
                        .frame(width: 210, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }

                    if warnings.isEmpty {
                        SettingsBanner(tone: .done, title: "Text contrast passes 4.5:1 on the preview surfaces.")
                    } else {
                        SettingsBanner(
                            tone: .human,
                            title: "\(warnings.count) text combinations fall below 4.5:1 contrast",
                            message: warnings.prefix(8).map { "\($0.name): \(String(format: "%.2f", $0.ratio)):1" }.joined(separator: "\n")
                        )
                    }
                }
                .onAppear { syncHexField(colors) }
                .onChange(of: activeKey) { _, _ in syncHexField(colors) }
                .onChange(of: editMode) { _, _ in syncHexField(PaletteTokens.resolvedRawTokens(for: pref, mode: editMode)) }
            }
        }
    }

    private func syncHexField(_ colors: [String: String]) {
        hexInput = String((colors[activeKey] ?? "#000000").prefix(7)).lowercased()
        hexError = nil
    }

    private func setOverride(key: String, hex: String) {
        updatePref { p in
            if editMode == .dark { p.custom.dark[key] = hex }
            else { p.custom.light[key] = hex }
        }
    }

    private func paletteCard(
        id: String,
        name: String,
        description: String,
        dark: [String: String],
        light: [String: String],
        selected: Bool
    ) -> some View {
        Button {
            updatePref { $0.palette = id }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(name).font(.callout.weight(.medium))
                    Spacer()
                }
                HStack(spacing: 0) {
                    ForEach([dark["bg"], light["bg"], dark["accent"], dark["state-done"], dark["state-human"]].indices, id: \.self) { idx in
                        let hex = [dark["bg"], light["bg"], dark["accent"], dark["state-done"], dark["state-human"]][idx]
                        Rectangle()
                            .fill(Color(cssHex: hex) ?? .gray)
                            .frame(height: 18)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    private func tokenButton(key: String, hex: String, customized: Bool) -> some View {
        let active = activeKey == key
        return Button {
            activeKey = key
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(cssHex: hex) ?? .clear)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                Text(PaletteTokens.tokenTitle(key))
                    .font(.caption)
                    .lineLimit(1)
                if customized {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func previewCard(colors c: [String: String]) -> some View {
        let bg = Color(cssHex: c["bg"]) ?? .black
        let fg = Color(cssHex: c["text"]) ?? .white
        let sec = Color(cssHex: c["text-secondary"]) ?? .gray
        let border = Color(cssHex: c["border"]) ?? .gray
        let accent = Color(cssHex: c["accent"]) ?? .accentColor
        let onAccent = Color(cssHex: c["text-on-accent"]) ?? .white
        let surface = Color(cssHex: c["surface"]) ?? bg

        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your workspace, your colors").font(.headline).foregroundStyle(fg)
                Text("Text, buttons, status colors, and charts.").font(.caption).foregroundStyle(sec)
                HStack(spacing: 8) {
                    Text("Primary button")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accent, in: RoundedRectangle(cornerRadius: 6))
                    Text("Secondary")
                        .font(.caption)
                        .foregroundStyle(fg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(cssHex: c["btn-secondary-bg"]) ?? surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(cssHex: c["btn-secondary-border"]) ?? border, lineWidth: 0.75))
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(1...8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(cssHex: c["viz-\(i)"]) ?? accent)
                        .frame(width: 12, height: CGFloat(16 + ((i * 11) % 34)))
                }
            }
            .padding(10)
            .background(surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 0.5))
        }
        .padding(14)
        .background(bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 0.75))
    }

    private func exportPalette(_ pref: AppearancePreference) {
        statusMessage = nil
        do {
            let data = try pref.exportPaletteJSON()
            if let url = try SettingsFilePanels.saveData(data, defaultName: "vesper-palette.json", contentType: .json, title: "Export Palette JSON") {
                statusMessage = "Exported \(url.lastPathComponent)."
            }
        } catch {
            statusMessage = settingsErrorText(error)
        }
    }

    private func importPalette(_ current: AppearancePreference) {
        statusMessage = nil
        guard let url = SettingsFilePanels.pickOpenURL(contentTypes: [.json], title: "Import Palette JSON") else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try AppearancePreference.importPaletteJSON(data, preserving: current)
            updatePref { $0 = imported }
            statusMessage = "Palette imported from \(url.lastPathComponent)."
        } catch {
            statusMessage = settingsErrorText(error)
        }
    }
}
