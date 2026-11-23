import XCTest
@testable import VesperCore

final class MediaProviderHelpersTests: XCTestCase {
    private func geminiFixture(
        available: Bool = false,
        enabled: Bool = true,
        settings: [String: String] = [:],
        secretsSet: [String: Bool] = [:]
    ) -> API.MediaProvider {
        API.MediaProvider(
            available: available,
            capabilities: [.music, .video, .tts],
            comingSoon: false,
            description: "Lyria 3 music, Gemini Omni video and Gemini TTS persona voices.",
            enabled: enabled,
            fields: [
                API.MediaFieldSpec(
                    default: "gemini_api",
                    key: "backend",
                    kind: .segmented,
                    label: "Backend",
                    options: [
                        API.MediaFieldOption(label: "Gemini API", value: "gemini_api"),
                        API.MediaFieldOption(label: "Vertex AI", value: "vertex_ai"),
                    ]
                ),
                API.MediaFieldSpec(
                    key: "api_key",
                    kind: .secret,
                    label: "API Key",
                    required: true,
                    showWhen: ["backend": "gemini_api"]
                ),
                API.MediaFieldSpec(
                    key: "project",
                    kind: .text,
                    label: "GCP Project ID",
                    required: true,
                    showWhen: ["backend": "vertex_ai"]
                ),
                API.MediaFieldSpec(
                    default: "us-central1",
                    key: "location",
                    kind: .text,
                    label: "GCP Location",
                    required: true,
                    showWhen: ["backend": "vertex_ai"]
                ),
                API.MediaFieldSpec(
                    default: "auto",
                    key: "model",
                    kind: .select,
                    label: "Music Model",
                    options: [
                        API.MediaFieldOption(label: "Lyria 3 (Auto)", value: "auto"),
                        API.MediaFieldOption(label: "Lyria 3.5", value: "lyria-3.5"),
                    ]
                ),
                API.MediaFieldSpec(
                    default: "gemini-omni-1.2-flash",
                    key: "video_model",
                    kind: .select,
                    label: "Video Model",
                    options: [
                        API.MediaFieldOption(label: "Gemini Omni 1.2 Flash", value: "gemini-omni-1.2-flash"),
                        API.MediaFieldOption(label: "Gemini Omni 1.1 Flash", value: "gemini-omni-1.1-flash"),
                    ]
                ),
                API.MediaFieldSpec(
                    default: "gemini-3.8-flash-tts",
                    key: "tts_model",
                    kind: .select,
                    label: "Voice Model",
                    options: [
                        API.MediaFieldOption(label: "Gemini 3.8 Flash TTS", value: "gemini-3.8-flash-tts"),
                        API.MediaFieldOption(label: "Gemini 3.8 Flash-Lite TTS", value: "gemini-3.8-flash-lite-tts"),
                    ]
                ),
            ],
            id: "gemini",
            label: "Gemini (Lyria, Omni & TTS)",
            secretsSet: secretsSet,
            settings: settings,
            unavailableReason: available ? nil : "Add a Gemini API key in Settings → Workspace → Media providers."
        )
    }

    private func mlxFixture() -> API.MediaProvider {
        API.MediaProvider(
            available: false,
            capabilities: [.music],
            comingSoon: true,
            description: "Extensible adapter slot · Not yet installed",
            enabled: false,
            fields: [],
            id: "local-mlx",
            label: "Local MLX (Apple Silicon)",
            secretsSet: [:],
            settings: [:],
            unavailableReason: "Local MLX adapter is not installed yet"
        )
    }

    func testEffectiveSettingsAndConditionalVisibilityToggleByBackend() {
        let provider = geminiFixture()

        let apiSettings = MediaProviderHelpers.effectiveSettings(for: provider)
        XCTAssertEqual(apiSettings["backend"], "gemini_api")
        XCTAssertEqual(apiSettings["location"], "us-central1")
        XCTAssertEqual(apiSettings["model"], "auto")
        XCTAssertEqual(apiSettings["video_model"], "gemini-omni-1.2-flash")
        XCTAssertEqual(apiSettings["tts_model"], "gemini-3.8-flash-tts")

        let apiVisibleKeys = MediaProviderHelpers.visibleFields(for: provider, settings: apiSettings).map(\.key)
        XCTAssertEqual(apiVisibleKeys, ["backend", "api_key", "model", "video_model", "tts_model"])

        let vertexSettings = MediaProviderHelpers.effectiveSettings(
            for: provider,
            draftSettings: ["backend": "vertex_ai", "project": "my-gcp-proj"]
        )
        let vertexVisibleKeys = MediaProviderHelpers.visibleFields(for: provider, settings: vertexSettings).map(\.key)
        XCTAssertEqual(vertexVisibleKeys, ["backend", "project", "location", "model", "video_model", "tts_model"])
    }

    func testActiveProviderAndCapabilityGroupsCoverMusicVideoAndTTS() {
        let unready = API.MediaProvidersResponse(defaults: [:], providers: [geminiFixture(available: false), mlxFixture()])
        XCTAssertNil(MediaProviderHelpers.activeProvider(for: .music, in: unready))
        XCTAssertNil(MediaProviderHelpers.activeProvider(for: .video, in: unready))
        XCTAssertNil(MediaProviderHelpers.activeProvider(for: .tts, in: unready))

        let ready = API.MediaProvidersResponse(
            defaults: ["music": "local-mlx", "video": "gemini"],
            providers: [geminiFixture(available: true), mlxFixture()]
        )
        // Falls back to ready Gemini when explicit default points to a coming-soon provider.
        XCTAssertEqual(MediaProviderHelpers.activeProvider(for: .music, in: ready)?.id, "gemini")
        XCTAssertEqual(MediaProviderHelpers.activeProvider(for: .video, in: ready)?.id, "gemini")
        XCTAssertEqual(MediaProviderHelpers.activeProvider(for: .tts, in: ready)?.id, "gemini")

        let groups = MediaProviderHelpers.capabilityGroups(in: ready)
        XCTAssertEqual(groups.map(\.capability), [.music, .video, .tts])
        XCTAssertEqual(groups[0].providers.map(\.id), ["gemini", "local-mlx"])
        XCTAssertEqual(groups[1].providers.map(\.id), ["gemini"])
        XCTAssertEqual(groups[2].providers.map(\.id), ["gemini"])
    }

    func testStatusDirtyDetectionAndPatchOmitEmptySecrets() {
        let base = geminiFixture(available: false)
        XCTAssertEqual(MediaProviderHelpers.providerStatus(base), MediaProviderStatus(tone: .human, label: "Not configured"))
        XCTAssertEqual(MediaProviderHelpers.providerStatus(geminiFixture(available: true)), MediaProviderStatus(tone: .done, label: "Connected"))
        XCTAssertEqual(MediaProviderHelpers.providerStatus(mlxFixture()), MediaProviderStatus(tone: .neutral, label: "Coming soon"))
        XCTAssertEqual(MediaProviderHelpers.providerStatus(geminiFixture(available: false, enabled: false)), MediaProviderStatus(tone: .neutral, label: "Disabled"))

        // Reverting a draft back to its default/saved value is not dirty.
        XCTAssertFalse(MediaProviderHelpers.hasDirtyChanges(for: base, draftSettings: ["video_model": "gemini-omni-1.2-flash"], draftSecrets: ["api_key": "   "]))
        XCTAssertTrue(MediaProviderHelpers.hasDirtyChanges(for: base, draftSettings: ["video_model": "gemini-omni-1.1-flash"], draftSecrets: [:]))
        XCTAssertTrue(MediaProviderHelpers.hasDirtyChanges(for: base, draftSettings: [:], draftSecrets: ["api_key": "AIza-123"]))

        let noSecretPatch = MediaProviderHelpers.buildProviderPatch(
            for: base,
            draftSettings: ["video_model": "gemini-omni-1.1-flash", "tts_model": "gemini-3.8-flash-lite-tts"],
            draftSecrets: ["api_key": "   "]
        )
        XCTAssertNil(noSecretPatch.secrets)
        XCTAssertEqual(noSecretPatch.settings?["video_model"], "gemini-omni-1.1-flash")
        XCTAssertEqual(noSecretPatch.settings?["tts_model"], "gemini-3.8-flash-lite-tts")
        XCTAssertEqual(noSecretPatch.settings?["model"], "auto")

        let withSecretPatch = MediaProviderHelpers.buildProviderPatch(
            for: base,
            draftSettings: [:],
            draftSecrets: ["api_key": " AIza-test-123 "]
        )
        XCTAssertEqual(withSecretPatch.secrets, ["api_key": "AIza-test-123"])
    }

    func testImageCapabilityLabelsAndUnifiedImageEngineChoices() {
        XCTAssertEqual(MediaProviderHelpers.capabilityLabel(.image), "Image")
        XCTAssertEqual(MediaProviderHelpers.capabilityPillLabel(.image), "Image")

        let opts: [API.ImageEngineSettings.OptionsItem] = [
            .init(available: false, engine: .codex, label: "Codex", model: nil, reason: "isn't available"),
            .init(available: true, engine: .antigravity, label: "Antigravity", model: "antigravity-main", reason: nil),
            .init(available: true, engine: .gemini, label: "Gemini API", model: "gemini-3-pro-image", reason: nil),
        ]
        let choices = WorkspaceSetupHelpers.imageEngineChoices(opts)
        XCTAssertEqual(choices.map(\.value), [.auto, .codex, .antigravity, .gemini])
        XCTAssertEqual(choices[0].detail, "Use the first connected: Antigravity, then Gemini API.")
        XCTAssertEqual(choices[3].detail, "Connected · gemini-3-pro-image")

        XCTAssertEqual(
            WorkspaceSetupHelpers.activeImageEngineSummary(.init(engine: .auto, options: opts)),
            "Using Auto (Antigravity)"
        )
        XCTAssertEqual(
            WorkspaceSetupHelpers.activeImageEngineSummary(.init(engine: .gemini, options: opts)),
            "Using Gemini API"
        )
        XCTAssertEqual(
            WorkspaceSetupHelpers.activeImageEngineSummary(.init(engine: .codex, options: opts)),
            "Codex (not configured)"
        )
    }
}
