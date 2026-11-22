import Foundation

extension ActivitySceneCatalog {
    static let coreDefinitions: [ActivitySceneKind: ActivitySceneDefinition] = [
        .thinking: thinkingScene,
        .nextStep: nextStepScene,
        .wiki: wikiScene,
        .tickets: ticketsScene,
        .ticketLookup: ticketLookupScene,
        .readingCode: readingCodeScene,
        .searchingCode: searchingCodeScene,
        .writingCode: writingCodeScene,
        .tests: testsScene,
        .build: buildScene,
        .install: installScene,
        .terminal: terminalScene,
        .github: githubScene,
        .commit: commitScene,
        .push: pushScene,
        .pullRequest: pullRequestScene,
        .repoHistory: repoHistoryScene,
        .web: webScene,
        .webPage: webPageScene,
        .video: videoScene,
    ]

    // MARK: - thinking
    private static let thinkingScene = ActivitySceneDefinition(
        kind: .thinking,
        nodes: [
            .circle(
                cx: 66, cy: 28, r: 21,
                style: SceneStyle(
                    fill: nil, stroke: .accent, strokeOpacity: 0.3, strokeWidth: 1.5,
                    transformOrigin: .center,
                    animation: MotionAnimation(name: "scene-breathe", duration: 3.2, easing: .easeInOut, keyframes: [
                        .at(0.5, scale: 1.12, opacity: 0.55),
                    ])
                )
            ),
            .circle(
                cx: 66, cy: 28, r: 12.5,
                style: SceneStyle(fill: nil, stroke: .borderStrong, strokeWidth: 1.2, dashArray: [3, 3], opacity: 0.7)
            ),
            .path(d: "M52 31L66 19L80 31Z", style: SceneStyle.lineAccent.withStrokeWidth(1.2).withOpacity(0.35)),
            .circle(
                cx: 52, cy: 31, r: 3.6,
                style: SceneStyle.accent.withOpacity(0.65).withAnimation(
                    MotionAnimation(name: "scene-drift-a", duration: 3.6, easing: .easeInOut, keyframes: [
                        .at(0.5, tx: 5, ty: -5),
                    ])
                )
            ),
            .circle(
                cx: 66, cy: 19, r: 4.6,
                style: SceneStyle.accent.withAnimation(
                    MotionAnimation(name: "scene-drift-b", duration: 4.2, easing: .easeInOut, keyframes: [
                        .at(0.5, tx: -6, ty: 5),
                    ])
                )
            ),
            .circle(
                cx: 80, cy: 31, r: 3.4,
                style: SceneStyle.warm.withOpacity(0.85).withAnimation(
                    MotionAnimation(name: "scene-drift-c", duration: 3.0, easing: .easeInOut, keyframes: [
                        .at(0.5, tx: 4, ty: 6),
                    ])
                )
            ),
        ]
    )

    // MARK: - next-step
    private static let nextStepBranches = [
        "M30 28C52 28 62 12 92 12",
        "M30 28H96",
        "M30 28C52 28 62 44 92 44",
    ]

    private static let nextStepScene = ActivitySceneDefinition(
        kind: .nextStep,
        nodes: nextStepBranches.map {
            .path(d: $0, style: SceneStyle.empty.withDash([3, 3]))
        } + [
            .circle(cx: 98, cy: 12, r: 5, style: .empty),
            .circle(cx: 102, cy: 28, r: 5, style: .empty),
            .circle(cx: 98, cy: 44, r: 5, style: .empty),
            .path(
                d: nextStepBranches[0],
                style: SceneStyle.lineAccent.withPathLengthOne().withBaseDashOffset(1).withAnimation(
                    MotionAnimation(name: "scene-ns-probe-a", duration: 4.8, easing: .easeInOut, keyframes: [
                        .at(0.0, dashOffset: 1),
                        .at(0.09, dashOffset: 0.5),
                        .at(0.18, dashOffset: 1),
                        .at(1.0, dashOffset: 1),
                    ])
                )
            ),
            .path(
                d: nextStepBranches[2],
                style: SceneStyle.lineAccent.withPathLengthOne().withBaseDashOffset(1).withAnimation(
                    MotionAnimation(name: "scene-ns-probe-b", duration: 4.8, easing: .easeInOut, keyframes: [
                        .at(0.0, dashOffset: 1),
                        .at(0.16, dashOffset: 1),
                        .at(0.25, dashOffset: 0.5),
                        .at(0.34, dashOffset: 1),
                        .at(1.0, dashOffset: 1),
                    ])
                )
            ),
            .path(
                d: nextStepBranches[1],
                style: SceneStyle.lineAccent.withPathLengthOne().withAnimation(
                    MotionAnimation(name: "scene-ns-commit", duration: 4.8, easing: .easeInOut, keyframes: [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.32, opacity: 1, dashOffset: 1),
                        .at(0.5, opacity: 1, dashOffset: 0),
                        .at(0.84, opacity: 1, dashOffset: 0),
                        .at(0.96, opacity: 0, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .circle(
                cx: 102, cy: 28, r: 5,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-ns-chosen", duration: 4.8, easing: .easeOut, keyframes: [
                        .at(0.0, scale: 0, opacity: 1),
                        .at(0.48, scale: 0, opacity: 1),
                        .at(0.55, scale: 1.2),
                        .at(0.6, scale: 1, opacity: 1),
                        .at(0.84, scale: 1, opacity: 1),
                        .at(0.96, scale: 1, opacity: 0),
                        .at(1.0, scale: 1, opacity: 0),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-ns-from", duration: 4.8, easing: .easeInOut, keyframes: [
                        .at(0.0, opacity: 1),
                        .at(0.3, opacity: 1),
                        .at(0.4, opacity: 0.6),
                        .at(0.5, opacity: 1),
                        .at(1.0, opacity: 1),
                    ])
                ),
                children: doneBadge(x: 22, y: 28)
            ),
        ]
    )

    // MARK: - wiki
    private static let wikiScene = ActivitySceneDefinition(
        kind: .wiki,
        nodes: [
            .rect(x: 20, y: 6, width: 46, height: 44, rx: 3, style: .paper),
            .rect(x: 66, y: 6, width: 46, height: 44, rx: 3, style: .paper),
            .rect(x: 26, y: 13, width: 20, height: 7, rx: 2, style: SceneStyle.accent.withOpacity(0.28)),
            .path(d: "M26 26H58 M26 33H52 M26 40H56", style: SceneStyle.line.withStrokeWidth(1.5)),
            .rect(
                x: 70, y: 19, width: 38, height: 8, rx: 1.5,
                style: SceneStyle.accent.withOpacity(0.28).withAnimation(
                    MotionAnimation(name: "scene-sweep", duration: 2.4, easing: .easeInOut, alternate: true, keyframes: [
                        .at(0.0, ty: -6),
                        .at(1.0, ty: 18),
                    ])
                )
            ),
            .path(d: "M73 14H96", style: SceneStyle.lineAccent.withStrokeWidth(1.6)),
            .path(d: "M73 23H105 M73 31H101 M73 39H94", style: SceneStyle.line.withStrokeWidth(1.5)),
        ]
    )

    // MARK: - tickets
    private static let ticketsScene = ActivitySceneDefinition(
        kind: .tickets,
        nodes: [24.0, 58.0, 92.0].map {
            .rect(x: $0, y: 5, width: 26, height: 46, rx: 3, style: .empty)
        } + [
            .rect(x: 27, y: 36, width: 20, height: 10, rx: 2, style: .paper),
            .rect(x: 61, y: 36, width: 20, height: 10, rx: 2, style: .paper),
            .rect(x: 95, y: 26, width: 20, height: 10, rx: 2, style: .paper),
            .rect(
                x: 27, y: 12, width: 20, height: 10, rx: 2,
                style: SceneStyle.accent.withAnimation(
                    MotionAnimation(name: "scene-card", duration: 3.6, easing: .easeInOut, fillMode: .both, keyframes: [
                        .at(0.0, identityTransform: true, opacity: 0),
                        .at(0.06, identityTransform: true, opacity: 1),
                        .at(0.15, identityTransform: true, opacity: 1),
                        .at(0.35, tx: 34),
                        .at(0.55, tx: 34),
                        .at(0.75, tx: 68, opacity: 1),
                        .at(0.9, tx: 68, opacity: 1),
                        .at(1.0, tx: 68, opacity: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - ticket-lookup
    private static let ticketLookupScene = ActivitySceneDefinition(
        kind: .ticketLookup,
        nodes: [
            .path(
                d: "M120 28H40",
                style: SceneStyle.lineAccent.withStrokeOpacity(0.35).withPathLengthOne().withAnimation(sceneLink)
            ),
            .circle(
                cx: 22, cy: 28, r: 10,
                style: SceneStyle(
                    fill: .accent, fillOpacity: 0.18, stroke: .accent, strokeWidth: 1.5,
                    transformOrigin: .center,
                    animation: sceneNode.delayed(by: 0.7)
                )
            ),
            .circle(cx: 22, cy: 28, r: 3.5, style: .accent),
        ] + [(7.0, false, 0.0), (22.0, false, 0.55), (37.0, true, 1.1)].map { y, epic, wait in
            let pull = MotionAnimation(
                name: "scene-pull",
                duration: 3.6,
                delay: wait,
                easing: .motionEase,
                fillMode: .both,
                keyframes: [
                    .at(0.0, tx: 64, opacity: 0),
                    .at(0.1, opacity: 1),
                    .at(0.32, identityTransform: true, opacity: 1),
                    .at(0.86, identityTransform: true, opacity: 1),
                    .at(1.0, identityTransform: true, opacity: 0),
                ]
            )
            let badge: SceneNode = if epic {
                .path(d: "M47 \(fmt(y + 6))l2.5-2.5 2.5 2.5-2.5 2.5z", style: SceneStyle(fill: .surfaceRaised))
            } else {
                .path(d: "M47 \(fmt(y + 6))H52", style: SceneStyle.line.withStroke(.accent, width: 1.5))
            }
            let titleLine = SceneNode.path(
                d: "M56 \(fmt(y + 6))H\(epic ? 70 : 72)",
                style: epic
                    ? SceneStyle.line.withStroke(.surfaceRaised, width: 1.5)
                    : SceneStyle.line.withStrokeWidth(1.5)
            )
            return .group(
                style: SceneStyle.none.withAnimation(pull),
                children: [
                    .rect(
                        x: 42, y: y, width: 34, height: 12, rx: 2.5,
                        style: (epic ? SceneStyle.accent : .paper).withOpacity(epic ? 0.85 : 1)
                    ),
                    badge,
                    titleLine,
                ]
            )
        }
    )

    // MARK: - reading-code
    private static let readingCodeScene = ActivitySceneDefinition(
        kind: .readingCode,
        nodes: [
            .rect(x: 18, y: 4, width: 96, height: 48, rx: 4, style: .paper),
            .path(d: "M30 8V48", style: SceneStyle.line.withStrokeWidth(1).withOpacity(0.35)),
            .path(d: "M23 13H26 M23 22H26 M23 31H26 M23 40H26", style: SceneStyle.line.withStrokeWidth(1.4).withOpacity(0.45)),
            .path(d: "M35 13H68", style: SceneStyle.lineAccent.withStrokeWidth(1.8)),
            .path(d: "M41 22H104 M41 31H86 M35 40H96", style: SceneStyle.line.withStrokeWidth(1.7)),
            .rect(
                x: 33, y: 22, width: 75, height: 9, rx: 2,
                style: SceneStyle.accent.withOpacity(0.25).withAnimation(
                    MotionAnimation(name: "scene-scan", duration: 2.2, easing: .linear, keyframes: [
                        .at(0.0, ty: -13, opacity: 0),
                        .at(0.12, opacity: 0.25),
                        .at(0.88, opacity: 0.25),
                        .at(1.0, ty: 17, opacity: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - searching-code
    private static let searchingCodeScene = ActivitySceneDefinition(
        kind: .searchingCode,
        nodes: [
            .rect(x: 18, y: 4, width: 96, height: 48, rx: 4, style: .paper),
            .path(d: "M28 14H66 M34 24H98 M34 34H84 M28 44H74", style: SceneStyle.line.withStrokeWidth(1.6)),
            .rect(
                x: 48, y: 19.5, width: 32, height: 9, rx: 2,
                style: SceneStyle.accent.withOpacity(0.32).withOrigin(.center).withAnimation(
                    storyAnim("scene-sc-hit", [
                        .at(0.0, sx: 0.4, opacity: 0),
                        .at(0.4, sx: 0.4, opacity: 0),
                        .at(0.48, identityTransform: true, opacity: 0.32),
                        .at(0.88, identityTransform: true, opacity: 0.32),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .path(
                d: "M52 24H76",
                style: SceneStyle.lineAccent.withStrokeWidth(1.8).withOrigin(.center).withAnimation(
                    storyAnim("scene-sc-match", [
                        .at(0.0, opacity: 0),
                        .at(0.4, opacity: 0),
                        .at(0.48, opacity: 1),
                        .at(0.88, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-sc-lens", easing: .easeInOut, [
                        .at(0.0, tx: -24, ty: -10),
                        .at(0.1, tx: -24, ty: -10),
                        .at(0.26, tx: 18, ty: 10),
                        .at(0.44, identityTransform: true),
                        .at(0.84, identityTransform: true),
                        .at(1.0, tx: -24, ty: -10),
                    ])
                ),
                children: [
                    .circle(cx: 64, cy: 24, r: 8.5, style: SceneStyle(fill: .surface, fillOpacity: 0.35, stroke: .accent, strokeWidth: 2)),
                    .path(d: "M70 30l6 6", style: .lineAccent),
                ]
            ),
        ]
    )

    // MARK: - writing-code (and alias writing-reply)
    private static let writingCodeScene = ActivitySceneDefinition(
        kind: .writingCode,
        nodes: [
            .rect(x: 18, y: 4, width: 96, height: 48, rx: 4, style: .paper),
            .path(d: "M18 13H114", style: SceneStyle.line.withStrokeWidth(1).withOpacity(0.45)),
        ] + [24.0, 29.0, 34.0].map {
            .circle(cx: $0, cy: 8.5, r: 1.3, style: .muted)
        } + [
            .path(
                d: "M26 20H78",
                style: SceneStyle.lineAccent.withStrokeWidth(1.8).withOrigin(.leftCenter).withAnimation(
                    MotionAnimation(name: "scene-type-1", duration: 4.0, easing: .linear, keyframes: [
                        .at(0.0, sx: 0),
                        .at(0.2, sx: 1),
                        .at(1.0, sx: 1),
                    ])
                )
            ),
            .path(
                d: "M34 28H102",
                style: SceneStyle.line.withStrokeWidth(1.8).withOrigin(.leftCenter).withAnimation(
                    MotionAnimation(name: "scene-type-2", duration: 4.0, easing: .linear, keyframes: [
                        .at(0.0, sx: 0),
                        .at(0.2, sx: 0),
                        .at(0.4, sx: 1),
                        .at(1.0, sx: 1),
                    ])
                )
            ),
            .path(
                d: "M34 36H84",
                style: SceneStyle.lineDone.withStrokeWidth(1.8).withOrigin(.leftCenter).withAnimation(
                    MotionAnimation(name: "scene-type-3", duration: 4.0, easing: .linear, keyframes: [
                        .at(0.0, sx: 0),
                        .at(0.4, sx: 0),
                        .at(0.6, sx: 1),
                        .at(1.0, sx: 1),
                    ])
                )
            ),
            .path(
                d: "M34 44H66",
                style: SceneStyle.lineDone.withStrokeWidth(1.8).withOrigin(.leftCenter).withAnimation(
                    MotionAnimation(name: "scene-type-4", duration: 4.0, easing: .linear, keyframes: [
                        .at(0.0, sx: 0),
                        .at(0.6, sx: 0),
                        .at(0.75, sx: 1),
                        .at(1.0, sx: 1),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-caret-path", duration: 4.0, easing: .linear, keyframes: [
                        .at(0.0, tx: -42, ty: -24),
                        .at(0.2, tx: 10, ty: -24),
                        .at(0.2001, tx: -34, ty: -16),
                        .at(0.4, tx: 34, ty: -16),
                        .at(0.4001, tx: -34, ty: -8),
                        .at(0.6, tx: 16, ty: -8),
                        .at(0.6001, tx: -34, ty: 0),
                        .at(0.75, tx: 0, ty: 0),
                        .at(1.0, tx: 0, ty: 0),
                    ])
                ),
                children: [
                    .rect(
                        x: 68, y: 40.5, width: 1.8, height: 7, rx: 0.5,
                        style: SceneStyle(fill: .text, animation: sceneCaret)
                    ),
                ]
            ),
        ]
    )

    // MARK: - tests
    private static let testsScene = ActivitySceneDefinition(
        kind: .tests,
        nodes: [.rect(x: 20, y: 4, width: 92, height: 48, rx: 4, style: .paper)]
            + [(14.0, 88.0, 0), (26.0, 98.0, 1), (38.0, 82.0, 2)].flatMap { y, end, i -> [SceneNode] in
                let start = 0.06 + Double(i) * 0.2
                let peak = 0.12 + Double(i) * 0.2
                let settle = 0.16 + Double(i) * 0.2
                let anim = storyAnim("scene-ts-\(i)", [
                    .at(0.0, scale: 0),
                    .at(start, scale: 0),
                    .at(peak, scale: 1.25),
                    .at(settle, scale: 1),
                    .at(0.88, scale: 1),
                    .at(1.0, scale: 0),
                ])
                return [
                    .circle(cx: 31, cy: y, r: 4.5, style: SceneStyle.empty.withStrokeWidth(1.3)),
                    .group(
                        style: SceneStyle.none.withOrigin(.center).withAnimation(anim),
                        children: [
                            .circle(cx: 31, cy: y, r: 4.5, style: .done),
                            .path(
                                d: "M29 \(fmt(y))l1.4 1.4 2.7-2.8",
                                style: SceneStyle(fill: nil, stroke: .surface, strokeWidth: 1.4, lineCap: .round, lineJoin: .round)
                            ),
                        ]
                    ),
                    .path(d: "M41 \(fmt(y))H\(fmt(end))", style: SceneStyle.line.withStrokeWidth(1.6)),
                ]
            } + [
                .path(d: "M28 46.5H104", style: SceneStyle.line.withStrokeWidth(2).withOpacity(0.25)),
                .path(
                    d: "M28 46.5H104",
                    style: SceneStyle.lineDone.withStrokeWidth(2).withOrigin(.leftCenter).withAnimation(
                        storyAnim("scene-ts-bar", easing: .linear, [
                            .at(0.0, sx: 0),
                            .at(0.06, sx: 0),
                            .at(0.56, sx: 1, opacity: 1),
                            .at(0.88, sx: 1, opacity: 1),
                            .at(1.0, sx: 1, opacity: 0),
                        ])
                    )
                ),
            ]
    )

    // MARK: - build
    private static let buildScene = ActivitySceneDefinition(
        kind: .build,
        nodes: [
            .path(d: "M32 52H100", style: .line),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-row-1", duration: 4.0, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, ty: -14, opacity: 0),
                        .at(0.12, identityTransform: true, opacity: 1),
                        .at(0.85, identityTransform: true, opacity: 1),
                        .at(1.0, identityTransform: true, opacity: 0),
                    ])
                ),
                children: [40.0, 58.0, 76.0].map { .rect(x: $0, y: 39, width: 16, height: 11, rx: 2.5, style: .paper) }
            ),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-row-2", duration: 4.0, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, ty: -14, opacity: 0),
                        .at(0.25, ty: -14, opacity: 0),
                        .at(0.37, identityTransform: true, opacity: 1),
                        .at(0.85, identityTransform: true, opacity: 1),
                        .at(1.0, identityTransform: true, opacity: 0),
                    ])
                ),
                children: [49.0, 67.0].map { .rect(x: $0, y: 26, width: 16, height: 11, rx: 2.5, style: .paper) }
            ),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-row-3", duration: 4.0, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, ty: -14, opacity: 0),
                        .at(0.5, ty: -14, opacity: 0),
                        .at(0.62, identityTransform: true, opacity: 1),
                        .at(0.85, identityTransform: true, opacity: 1),
                        .at(1.0, identityTransform: true, opacity: 0),
                    ])
                ),
                children: [.rect(x: 58, y: 13, width: 16, height: 11, rx: 2.5, style: .accent)]
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-bld-ok", duration: 4.0, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, scale: 0),
                        .at(0.6, scale: 0),
                        .at(0.67, scale: 1.25),
                        .at(0.72, scale: 1, opacity: 1),
                        .at(0.86, scale: 1, opacity: 1),
                        .at(1.0, scale: 0, opacity: 0),
                    ])
                ),
                children: doneBadge(x: 88, y: 16)
            ),
        ]
    )

    // MARK: - install
    private static let installScene = ActivitySceneDefinition(
        kind: .install,
        nodes: [(52.0, 0.0), (62.0, 0.8), (72.0, 1.6)].map { x, wait in
            .rect(
                x: x, y: 6, width: 9, height: 9, rx: 1.5,
                style: SceneStyle.accent.withAnimation(
                    MotionAnimation(name: "scene-drop", duration: 2.4, delay: wait, easing: .easeIn, fillMode: .both, keyframes: [
                        .at(0.0, ty: -8, opacity: 0),
                        .at(0.15, opacity: 1),
                        .at(0.55, opacity: 1),
                        .at(0.65, ty: 22, opacity: 0),
                        .at(1.0, ty: 22, opacity: 0),
                    ])
                )
            )
        } + [
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-bump", duration: 0.8, easing: .easeOut, keyframes: [
                        .at(0.0, identityTransform: true),
                        .at(0.6, identityTransform: true),
                        .at(0.68, ty: 2),
                        .at(0.8, identityTransform: true),
                        .at(1.0, identityTransform: true),
                    ])
                ),
                children: [
                    .rect(x: 46, y: 30, width: 40, height: 22, rx: 2, style: .paper),
                    .path(d: "M46 30L38 24 M86 30L94 24 M60 41H72", style: .line),
                ]
            ),
        ]
    )

    // MARK: - terminal
    private static let terminalScene = ActivitySceneDefinition(
        kind: .terminal,
        nodes: [
            .rect(x: 28, y: 4, width: 76, height: 48, rx: 4, style: .paper),
            .viewport(x: 36, y: 8, width: 60, height: 30, children: [
                .path(
                    d: "M0 5H42 M0 15H54 M0 25H30 M0 35H42 M0 45H54 M0 55H30",
                    style: SceneStyle.line.withAnimation(
                        MotionAnimation(name: "scene-scroll-3", duration: 3.0, easing: .steps(3), keyframes: [
                            .at(1.0, ty: -30),
                        ])
                    )
                ),
            ]),
            .path(d: "M36 40l3 3-3 3", style: .lineAccent),
            .rect(x: 44, y: 39, width: 5, height: 8, style: SceneStyle.accent.withAnimation(sceneCaret)),
        ]
    )

    // MARK: - github
    private static let githubScene = ActivitySceneDefinition(
        kind: .github,
        nodes: [
            .path(d: "M8 44H124", style: .line),
            .path(d: "M24 44C40 44 40 14 56 14H88C104 14 104 44 120 44", style: .lineDone),
            .circle(cx: 24, cy: 44, r: 3.5, style: .muted),
            .circle(cx: 56, cy: 14, r: 3.5, style: .done),
            .circle(cx: 120, cy: 44, r: 4, style: SceneStyle(fill: .surface, stroke: .accent, strokeWidth: 1.5)),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-commit", duration: 3.2, easing: .linear, keyframes: [
                        .at(0.0, tx: -48, ty: 30, opacity: 0),
                        .at(0.04, opacity: 1),
                        .at(0.08, tx: -38.5, ty: 25.3),
                        .at(0.14, tx: -32, ty: 15),
                        .at(0.20, tx: -25.5, ty: 4.7),
                        .at(0.28, tx: -16, ty: 0),
                        .at(0.64, tx: 16, ty: 0),
                        .at(0.72, tx: 25.5, ty: 4.7),
                        .at(0.78, tx: 32, ty: 15),
                        .at(0.84, tx: 38.5, ty: 25.3),
                        .at(0.92, tx: 48, ty: 30, opacity: 1),
                        .at(1.0, tx: 48, ty: 30, opacity: 0),
                    ])
                ),
                children: [
                    .circle(cx: 72, cy: 14, r: 7, style: SceneStyle.done.withOpacity(0.25)),
                    .circle(cx: 72, cy: 14, r: 3, style: .done),
                ]
            ),
        ]
    )

    // MARK: - commit
    private static let commitScene = ActivitySceneDefinition(
        kind: .commit,
        nodes: [
            .path(d: "M12 40H120", style: .line),
            .circle(cx: 28, cy: 40, r: 3.5, style: .muted),
            .circle(cx: 64, cy: 40, r: 3.5, style: .muted),
        ] + [(12.0, 0.0), (0.0, 0.15), (-12.0, 0.3)].map { x, wait in
            .rect(
                x: 96 - x, y: 8, width: 8, height: 10, rx: 1.5,
                style: SceneStyle.paper.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-chip", duration: 3.2, delay: wait, easing: .easeInOut, fillMode: .both, keyframes: [
                        .at(0.0, ty: -4, opacity: 0),
                        .at(0.12, identityTransform: true, opacity: 1),
                        .at(0.35, identityTransform: true, opacity: 1),
                        .at(0.65, tx: x, ty: 27, scale: 0.3, opacity: 0),
                        .at(1.0, tx: x, ty: 27, scale: 0.3, opacity: 0),
                    ])
                )
            )
        } + [
            .circle(
                cx: 100, cy: 40, r: 5,
                style: SceneStyle.done.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-stamp", duration: 3.2, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, scale: 0),
                        .at(0.68, scale: 0),
                        .at(0.78, scale: 1.5),
                        .at(0.86, scale: 1),
                        .at(1.0, scale: 1),
                    ])
                )
            ),
        ]
    )

    // MARK: - push
    private static let pushScene = ActivitySceneDefinition(
        kind: .push,
        nodes: [
            .path(d: "M20 44L88 22", style: .line),
            .circle(cx: 20, cy: 44, r: 4, style: .muted),
            .path(
                d: "M92 28a8 8 0 0 1 0-16 11 11 0 0 1 21-2 9 9 0 0 1 3 18z",
                style: SceneStyle.lineAccent.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-arrive", duration: 2.4, easing: .easeOut, keyframes: [
                        .at(0.0, identityTransform: true),
                        .at(0.68, identityTransform: true),
                        .at(0.8, scale: 1.1),
                        .at(1.0, identityTransform: true),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-push", duration: 2.4, easing: .easeIn, fillMode: .both, keyframes: [
                        .at(0.0, tx: -68, ty: 22, opacity: 0),
                        .at(0.08, opacity: 1),
                        .at(0.7, identityTransform: true, opacity: 1),
                        .at(0.78, tx: 3, ty: -1, opacity: 0),
                        .at(1.0, tx: 3, ty: -1, opacity: 0),
                    ])
                ),
                children: [
                    .circle(cx: 88, cy: 22, r: 7, style: SceneStyle.done.withOpacity(0.25)),
                    .circle(cx: 88, cy: 22, r: 3, style: .done),
                ]
            ),
        ]
    )

    // MARK: - pull-request
    private static let pullRequestScene = ActivitySceneDefinition(
        kind: .pullRequest,
        nodes: [
            .path(d: "M10 44H122", style: .line),
            .path(
                d: "M22 44C36 44 36 14 52 14H70C86 14 86 44 100 44",
                style: SceneStyle.lineDone.withPathLengthOne().withAnimation(sceneLink)
            ),
            .circle(cx: 22, cy: 44, r: 3.5, style: .muted),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-pop", duration: 4.0, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, scale: 0),
                        .at(0.25, scale: 0),
                        .at(0.35, scale: 1.25),
                        .at(0.42, scale: 1, opacity: 1),
                        .at(0.85, scale: 1, opacity: 1),
                        .at(1.0, scale: 1, opacity: 0),
                    ])
                ),
                children: [
                    .circle(cx: 100, cy: 44, r: 8, style: .done),
                    .path(
                        d: "M96.5 44l2.5 2.5 4.5-5",
                        style: SceneStyle(fill: nil, stroke: .surface, strokeWidth: 2, lineCap: .round, lineJoin: .round)
                    ),
                ]
            ),
        ]
    )

    // MARK: - repo-history
    private static let repoHistoryScene = ActivitySceneDefinition(
        kind: .repoHistory,
        nodes: [
            .path(d: "M30 6V50", style: .line),
        ] + [10.0, 22.0, 34.0, 46.0].map {
            .circle(cx: 30, cy: $0, r: 3, style: .muted)
        } + [
            .path(d: "M42 10H104 M42 22H88 M42 34H110 M42 46H78", style: .line),
            .rect(
                x: 22, y: 4, width: 94, height: 12, rx: 2,
                style: SceneStyle.accent.withOpacity(0.25).withAnimation(
                    MotionAnimation(name: "scene-log", duration: 4.0, easing: .easeInOut, fillMode: .both, keyframes: [
                        .at(0.0, ty: 36, opacity: 0),
                        .at(0.05, ty: 36, opacity: 0.25),
                        .at(0.18, ty: 36, opacity: 0.25),
                        .at(0.25, ty: 24),
                        .at(0.43, ty: 24),
                        .at(0.5, ty: 12),
                        .at(0.68, ty: 12),
                        .at(0.75, identityTransform: true, opacity: 0.25),
                        .at(0.93, identityTransform: true, opacity: 0.25),
                        .at(1.0, identityTransform: true, opacity: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - web
    private static let webScene = ActivitySceneDefinition(
        kind: .web,
        nodes: [
            .circle(cx: 66, cy: 28, r: 16, style: SceneStyle(fill: nil, stroke: .textTertiary, strokeWidth: 1.5)),
            .ellipse(cx: 66, cy: 28, rx: 7, ry: 16, style: SceneStyle(fill: nil, stroke: .textTertiary, strokeWidth: 1.5)),
            .path(d: "M50 28H82 M53 19H79 M53 37H79", style: SceneStyle(fill: nil, stroke: .textTertiary, strokeWidth: 1.5)),
            .group(
                style: SceneStyle.none.withOrigin(.point(x: 66, y: 28)).withAnimation(sceneSpin),
                children: [
                    .group(
                        style: SceneStyle.none.withOrigin(.point(x: 79, y: 19)).withAnimation(sceneSpinReverse),
                        children: [
                            .circle(cx: 79, cy: 19, r: 6.5, style: SceneStyle(fill: .surface, stroke: .accent, strokeWidth: 2)),
                            .path(d: "M83.6 23.6l5.4 5.4", style: .lineAccent),
                        ]
                    ),
                ]
            ),
        ]
    )

    // MARK: - web-page
    private static let webPageScene = ActivitySceneDefinition(
        kind: .webPage,
        nodes: [
            .rect(x: 22, y: 4, width: 88, height: 48, rx: 4, style: .paper),
            .path(d: "M22 14H110", style: SceneStyle.line.withStrokeWidth(1).withOpacity(0.45)),
        ] + [28.0, 33.0, 38.0].map {
            .circle(cx: $0, cy: 9, r: 1.4, style: .muted)
        } + [
            .rect(x: 45, y: 6.8, width: 44, height: 4.4, rx: 2, style: SceneStyle.empty.withStrokeWidth(1).withOpacity(0.6)),
            .viewport(x: 28, y: 17, width: 76, height: 31, children: [
                .group(
                    style: SceneStyle.none.withAnimation(
                        MotionAnimation(name: "scene-wp-scroll", duration: 4.2, easing: .linear, keyframes: [
                            .at(1.0, ty: -34),
                        ])
                    ),
                    children: [
                        .rect(x: 0, y: 2, width: 26, height: 13, rx: 2, style: SceneStyle.accent.withOpacity(0.24)),
                        .path(d: "M32 5H68", style: SceneStyle.lineAccent.withStrokeWidth(1.6)),
                        .path(d: "M32 11H62 M0 21H70 M0 28H54", style: SceneStyle.line.withStrokeWidth(1.5)),
                        .rect(x: 0, y: 36, width: 26, height: 13, rx: 2, style: SceneStyle.accent.withOpacity(0.24)),
                        .path(d: "M32 39H68", style: SceneStyle.lineAccent.withStrokeWidth(1.6)),
                        .path(d: "M32 45H62 M0 55H70 M0 62H54", style: SceneStyle.line.withStrokeWidth(1.5)),
                    ]
                ),
            ]),
            .rect(
                x: 26, y: 24, width: 80, height: 7, rx: 1.5,
                style: SceneStyle.accent.withOpacity(0.18).withAnimation(
                    MotionAnimation(name: "scene-wp-scan", duration: 2.4, easing: .easeInOut, alternate: true, keyframes: [
                        .at(0.0, ty: -4),
                        .at(1.0, ty: 14),
                    ])
                )
            ),
        ]
    )

    // MARK: - video
    private static let videoScene = ActivitySceneDefinition(
        kind: .video,
        nodes: [
            .rect(x: 40, y: 3, width: 52, height: 31, rx: 4, style: .paper),
            .path(d: "M61 11v15l12-7.5z", style: SceneStyle.accent.withOrigin(.center).withAnimation(sceneNode)),
            .viewport(x: 34, y: 38, width: 64, height: 16, children: [
                .path(
                    d: "M6 4H58 M14 12H50 M6 20H58 M14 28H50",
                    style: SceneStyle.line.withAnimation(
                        MotionAnimation(name: "scene-scroll-2", duration: 3.0, easing: .steps(2), keyframes: [
                            .at(1.0, ty: -16),
                        ])
                    )
                ),
            ]),
        ]
    )
}
