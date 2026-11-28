import SwiftUI
import VesperCore

/// /native-debug/scenes, behind `NativeDebug`: previews all 59 `ActivitySceneKind` scenes,
/// tests hold/crossfade/wind-down transitions, and exercises the natively drawn `PersonaCharacterView`
/// (`active: true` animating alongside still `active: false` frames). Not a product screen.
struct ScenesDebugScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var selectedKind: ActivitySceneKind = .thinking
    @State private var isStopping = false
    @State private var useDioramaStage = true
    @State private var characterState: CharacterState = .idle
    @State private var characterColor = "#A3A6FF"

    private let columns = [
        GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 12),
    ]

    private static let colorSwatches: [(label: String, hex: String)] = [
        ("Atlas", "#A3A6FF"),
        ("Quill", "#3FC1B0"),
        ("Sentry", "#F48A98"),
        ("Nova", "#F0BF4C"),
    ]

    private static let quickKinds: [ActivitySceneKind] = [
        .thinking, .readingCode, .writingCode, .tests, .playground, .subagent, .image, .nextStep,
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    transitionLabCard
                    personaCharacterCard
                    scenesGridSection
                }
                .padding(24)
                .frame(maxWidth: 1080, alignment: .leading)
            }
            .onChange(of: context.find.current) { _, row in
                if let row { withAnimation { proxy.scrollTo(row, anchor: .center) } }
            }
        }
        .task {
            context.find.texts = ActivitySceneKind.allCases.map(\.rawValue)
            context.chrome = NativeChrome(
                title: "Activity Scenes",
                subtitle: "\(ActivitySceneKind.allCases.count) scenes · \(context.match.path)"
            )
        }
    }

    // MARK: - Transition & Wind-Down Lab

    private var transitionLabCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    transitionLabHeaderText
                    Spacer()
                    stoppingToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    transitionLabHeaderText
                    stoppingToggle
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    labStagePreview
                    transitionLabDetails
                }
                VStack(alignment: .leading, spacing: 12) {
                    labStagePreview
                    transitionLabDetails
                }
            }
        }
        .padding(16)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }

    @ViewBuilder
    private var labStagePreview: some View {
        let tint = Color(cssHex: characterColor) ?? theme.palette.accent
        if useDioramaStage {
            ActivitySceneView(
                kind: selectedKind,
                stopping: isStopping,
                width: 136,
                height: 76,
                stageStyle: .diorama(tint: tint, ambientPulse: !isStopping)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.3), lineWidth: 1))
        } else {
            ActivitySceneView(kind: selectedKind, stopping: isStopping)
        }
    }

    private var transitionLabHeaderText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Stage transitions & wind-down").vesperText(.heading, theme)
            Text("60fps diorama stage, 800ms hold, rapid-click transient skip, 240ms crossfade + scale settle, 600ms wind-down")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
    }

    private var stoppingToggle: some View {
        HStack(spacing: 14) {
            Toggle("Diorama stage", isOn: $useDioramaStage)
                .toggleStyle(.switch)
            Toggle("Stopping (600ms wind-down)", isOn: $isStopping)
                .toggleStyle(.switch)
        }
    }

    private var transitionLabDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(selectedKind.rawValue)
                    .font(.system(size: theme.pointSize(.mono), weight: .semibold, design: .monospaced))
                if let target = ActivitySceneKind.splitAliases[selectedKind] {
                    TonePill(label: "alias → \(target.rawValue)", tone: "neutral")
                }
            }

            FlowKindChips(kinds: Self.quickKinds, selected: selectedKind) { kind in
                selectedKind = kind
            }
        }
    }

    // MARK: - Persona Character Showcase

    private var personaCharacterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Native PersonaCharacterView").vesperText(.heading, theme)
                Text("Left: animated at display refresh (`active: true`). Right: still frames drawn natively (`active: false`).")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    liveCharacterPreview
                    characterControls
                    Spacer()
                    stillFramesPreview
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        liveCharacterPreview
                        stillFramesPreview
                    }
                    characterControls
                }
            }
        }
        .padding(16)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }

    private var liveCharacterPreview: some View {
        VStack(spacing: 6) {
            PersonaCharacterView(
                svg: Self.sampleCharacterSVG,
                color: characterColor,
                state: characterState,
                size: 56,
                active: true,
                framed: true
            )
            Text("Animated")
                .vesperText(.micro, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
    }

    private var characterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CharacterState.previewStates, id: \.state) { item in
                        Button(item.label) { characterState = item.state }
                            .buttonStyle(.vesper(characterState == item.state ? .primary : .outline))
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.colorSwatches, id: \.hex) { swatch in
                        Button {
                            characterColor = swatch.hex
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(cssHex: swatch.hex) ?? .gray)
                                    .frame(width: 10, height: 10)
                                Text(swatch.label)
                            }
                        }
                        .buttonStyle(.vesper(characterColor == swatch.hex ? .primary : .outline))
                    }
                }
            }
        }
    }

    private var stillFramesPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Still frames (active: false)")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.secondaryText)
            HStack(spacing: 10) {
                ForEach([(CGFloat(20), CharacterState.idle), (24, .coding), (32, .creating), (44, .needsYou)], id: \.0) { sz, st in
                    VStack(spacing: 4) {
                        PersonaCharacterView(
                            svg: Self.sampleCharacterSVG,
                            color: characterColor,
                            state: st,
                            size: sz,
                            active: false,
                            framed: true
                        )
                        Text("\(Int(sz))pt")
                            .vesperText(.micro, theme)
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                }
            }
        }
    }

    // MARK: - All 59 Scenes Grid

    private var scenesGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All \(ActivitySceneKind.allCases.count) activity scenes")
                .vesperText(.heading, theme)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(ActivitySceneKind.allCases.enumerated()), id: \.element) { index, kind in
                    let isSelected = selectedKind == kind
                    let isFindMatch = context.find.matches(kind.rawValue)
                    let isCurrentFind = context.find.current == index
                    Button {
                        selectedKind = kind
                    } label: {
                        VStack(spacing: 8) {
                            ActivitySceneView(kind: kind, stopping: isStopping)
                            VStack(spacing: 2) {
                                Text(kind.rawValue)
                                    .font(.system(size: theme.pointSize(.small), weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                if let alias = ActivitySceneKind.splitAliases[kind] {
                                    Text("→ \(alias.rawValue)")
                                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                        .foregroundStyle(theme.palette.tertiaryText)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(
                            isCurrentFind
                                ? theme.palette.selected
                                : isFindMatch
                                    ? theme.palette.accent.opacity(0.12)
                                    : theme.palette.surface,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(isSelected ? theme.palette.accent : theme.palette.border, lineWidth: isSelected ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
            }
        }
    }

    private struct FlowKindChips: View {
        let kinds: [ActivitySceneKind]
        let selected: ActivitySceneKind
        let onSelect: (ActivitySceneKind) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(kinds, id: \.self) { kind in
                        Button(kind.rawValue) { onSelect(kind) }
                            .buttonStyle(.vesper(selected == kind ? .primary : .outline))
                    }
                }
            }
        }
    }

    private static let sampleCharacterSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <ellipse data-part="shadow" data-motion="shadow" cx="32" cy="56" rx="14" ry="3" fill="currentColor" opacity="0.22"/>
      <g data-part="body" data-motion-idle="breathe" data-motion-thinking="tilt" data-motion-reading="nod" data-motion-coding="type" data-motion-creating="bounce" data-motion-needs-you="wave" data-pivot="32 38">
        <rect x="16" y="20" width="32" height="28" rx="10" fill="currentColor"/>
        <circle cx="23" cy="20" r="5" fill="currentColor"/>
        <circle cx="41" cy="20" r="5" fill="currentColor"/>
        <g data-part="eyes" data-motion="blink" data-motion-reading="glance" data-pivot="32 32">
          <rect x="24" y="29" width="4" height="6" rx="2" fill="#17151F"/>
          <rect x="36" y="29" width="4" height="6" rx="2" fill="#17151F"/>
        </g>
        <path d="M28 39q4 3 8 0" fill="none" stroke="#17151F" stroke-width="2" stroke-linecap="round"/>
      </g>
      <circle data-part="spark" data-show="creating" data-motion="spark" data-pivot="50 14" cx="50" cy="14" r="3" fill="#F0BF4C"/>
      <circle data-part="alert" data-show="needs-you" data-motion="pulse" data-pivot="50 14" cx="50" cy="14" r="4" fill="#F59E5B"/>
    </svg>
    """
}
