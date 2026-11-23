import Foundation

extension ActivitySceneCatalog {
    static let toolsDefinitions: [ActivitySceneKind: ActivitySceneDefinition] = [
        .persona: personaScene,
        .schedule: scheduleScene,
        .learning: learningScene,
        .research: researchScene,
        .space: spaceScene,
        .savedLinks: savedLinksScene,
        .projects: projectsScene,
        .library: libraryScene,
        .inbox: inboxScene,
        .chart: chartScene,
        .diagram: diagramScene,
        .app: appScene,
        .customApp: customAppScene,
        .database: databaseScene,
        .http: httpScene,
        .pdf: pdfScene,
        .subagent: subagentScene,
        .choices: choicesScene,
    ]

    // MARK: - persona
    private static let personaScene = ActivitySceneDefinition(
        kind: .persona,
        nodes: [
            .rect(x: 44, y: 4, width: 44, height: 48, rx: 6, style: .paper),
            .path(
                d: "M66 13a8 8 0 1 1-.01 0",
                style: SceneStyle.lineAccent.withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-pe-head", [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.02, opacity: 1, dashOffset: 1),
                        .at(0.3, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .path(
                d: "M52 47c0-9 6-14 14-14s14 5 14 14",
                style: SceneStyle.lineAccent.withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-pe-body", [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.26, opacity: 1, dashOffset: 1),
                        .at(0.56, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .path(
                d: sparklePath(x: 100, y: 14, s: 6),
                style: SceneStyle.warm.withOrigin(.center).withAnimation(
                    storyAnim("scene-pe-s0", [
                        .at(0.0, scale: 0),
                        .at(0.58, scale: 0),
                        .at(0.63, scale: 1.3),
                        .at(0.66, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
            .path(
                d: sparklePath(x: 32, y: 40, s: 4.5),
                style: SceneStyle.warm.withOrigin(.center).withAnimation(
                    storyAnim("scene-pe-s1", [
                        .at(0.0, scale: 0),
                        .at(0.66, scale: 0),
                        .at(0.71, scale: 1.3),
                        .at(0.74, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - schedule
    private static let scheduleScene = ActivitySceneDefinition(
        kind: .schedule,
        nodes: [
            .circle(cx: 38, cy: 28, r: 19, style: .paper),
            .path(d: "M38 12v3 M38 41v3 M22 28h3 M51 28h3", style: SceneStyle.line.withStrokeWidth(1.5)),
            .path(d: "M38 28l-6 4", style: .line),
            .path(d: "M38 28V16", style: SceneStyle.lineAccent.withOrigin(.point(x: 38, y: 28)).withAnimation(sceneSpin)),
            .circle(cx: 38, cy: 28, r: 2, style: .accent),
            .rect(x: 68, y: 8, width: 50, height: 42, rx: 3, style: .paper),
            .rect(x: 68, y: 8, width: 50, height: 8, rx: 3, style: .accent),
            .rect(x: 68, y: 12, width: 50, height: 4, style: .accent),
        ] + [25.0, 34.0, 43.0].flatMap { y in
            [77.0, 88.0, 99.0, 110.0].map { x in
                .circle(cx: x, cy: y, r: 2.4, style: SceneStyle.muted.withOpacity(0.45))
            }
        } + [25.0, 34.0, 43.0].enumerated().map { i, y in
            let s = 0.1 + Double(i) * 0.22
            let p = 0.15 + Double(i) * 0.22
            let e = 0.18 + Double(i) * 0.22
            return .circle(
                cx: 88, cy: y, r: 3.4,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-sch-d\(i)", [
                        .at(0.0, scale: 0),
                        .at(s, scale: 0),
                        .at(p, scale: 1.3),
                        .at(e, scale: 1),
                        .at(0.9, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            )
        }
    )

    // MARK: - learning
    private static let learningPath = "M18 44C34 44 34 16 52 16S70 44 88 44S104 16 114 16"

    private static let learningScene = ActivitySceneDefinition(
        kind: .learning,
        nodes: [
            .path(d: learningPath, style: SceneStyle.line.withOpacity(0.35)),
            .path(
                d: learningPath,
                style: SceneStyle.lineDone.withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-lm-path", easing: .linear, [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.02, opacity: 1, dashOffset: 1),
                        .at(0.7, opacity: 1, dashOffset: 0),
                        .at(0.9, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
        ] + [(18.0, 44.0, 0.02), (52.0, 16.0, 0.25), (88.0, 44.0, 0.48)].enumerated().map { i, item in
            let (x, y, s) = item
            return .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-lm-n\(i)", [
                        .at(0.0, scale: 0),
                        .at(s, scale: 0),
                        .at(s + 0.05, scale: 1.3),
                        .at(s + 0.08, scale: 1),
                        .at(0.9, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: doneBadge(x: x, y: y)
            )
        } + [
            .group(
                style: SceneStyle.none.withOrigin(.leftBottom).withAnimation(
                    storyAnim("scene-lm-n3", [
                        .at(0.0, scale: 0),
                        .at(0.7, scale: 0),
                        .at(0.75, scale: 1.3),
                        .at(0.78, scale: 1),
                        .at(0.9, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: [
                    .path(d: "M114 24V5", style: SceneStyle.lineAccent.withStrokeWidth(1.5)),
                    .path(d: "M114 5.5h11l-3 3.5 3 3.5h-11z", style: .warm),
                ]
            ),
        ]
    )

    // MARK: - research
    private static let researchScene = ActivitySceneDefinition(
        kind: .research,
        nodes: [.rect(x: 18, y: 4, width: 62, height: 48, rx: 3, style: .paper)]
            + ["M26 14H70", "M26 23H64", "M26 32H72", "M26 41H54"].enumerated().map { i, d in
                let s = 0.02 + Double(i) * 0.2
                let e = 0.18 + Double(i) * 0.2
                return .path(
                    d: d,
                    style: (i > 0 ? SceneStyle.line : .lineAccent).withOrigin(.leftCenter).withAnimation(
                        storyAnim("scene-rt-\(i)", easing: .linear, [
                            .at(0.0, sx: 0),
                            .at(s, sx: 0),
                            .at(e, identityTransform: true, opacity: 1),
                            .at(0.88, identityTransform: true, opacity: 1),
                            .at(1.0, opacity: 0),
                        ])
                    )
                )
            }
            + [8.0, 23.0, 38.0].map { y in
                .group(children: [
                    .rect(x: 92, y: y, width: 28, height: 10, rx: 2, style: .paper),
                    .path(d: "M97 \(fmt(y + 5))H113", style: SceneStyle.line.withStrokeWidth(1.5)),
                ])
            }
            + [(73.0, 12.0), (67.0, 21.0), (75.0, 30.0)].enumerated().map { i, pt in
                let ls = 0.18 + Double(i) * 0.2
                let ss = 0.22 + Double(i) * 0.2
                return .group(children: [
                    .path(
                        d: "M91 \(13 + 15 * i)L\(fmt(pt.0 + 3)) \(fmt(pt.1))",
                        style: SceneStyle.lineAccent.withStrokeWidth(1.2).withStrokeOpacity(0.6).withPathLengthOne().withOrigin(.center).withAnimation(
                            storyAnim("scene-rl-\(i)", [
                                .at(0.0, opacity: 1, dashOffset: 1),
                                .at(ls, opacity: 1, dashOffset: 1),
                                .at(ls + 0.06, opacity: 1, dashOffset: 0),
                                .at(0.88, opacity: 1, dashOffset: 0),
                                .at(1.0, opacity: 0, dashOffset: 0),
                            ])
                        )
                    ),
                    .circle(
                        cx: pt.0, cy: pt.1, r: 2,
                        style: SceneStyle.accent.withOrigin(.center).withAnimation(
                            storyAnim("scene-rsup-\(i)", [
                                .at(0.0, scale: 0),
                                .at(ss, scale: 0),
                                .at(ss + 0.05, scale: 1.3),
                                .at(ss + 0.08, scale: 1),
                                .at(0.88, scale: 1),
                                .at(1.0, scale: 0),
                            ])
                        )
                    ),
                ])
            }
    )

    // MARK: - space
    private static let spaceScene = ActivitySceneDefinition(
        kind: .space,
        nodes: [
            .path(
                d: "M30 12H102V50H30Z",
                style: SceneStyle.lineAccent.withLineJoin(.round).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-sp-o", easing: .easeInOut, [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.02, opacity: 1, dashOffset: 1),
                        .at(0.3, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .rect(
                x: 30, y: 4, width: 26, height: 8, rx: 2,
                style: SceneStyle.accent.withOrigin(.leftBottom).withAnimation(
                    storyAnim("scene-sp-tab", [
                        .at(0.0, sx: 0),
                        .at(0.3, sx: 0),
                        .at(0.38, sx: 1),
                        .at(0.88, sx: 1),
                        .at(1.0, sx: 1, opacity: 0),
                    ])
                )
            ),
        ] + [40.0, 59.0, 78.0].enumerated().map { i, x in
            let s = 0.38 + Double(i) * 0.08
            let e = 0.46 + Double(i) * 0.08
            return .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-sp-i\(i)", [
                        .at(0.0, ty: -14, opacity: 0),
                        .at(s, ty: -14, opacity: 0),
                        .at(e, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: [
                    .rect(x: x, y: 26, width: 14, height: 16, rx: 2, style: .paper),
                    .path(d: "M\(fmt(x + 4)) 31H\(fmt(x + 10))", style: SceneStyle.line.withStrokeWidth(1.5)),
                ]
            )
        }
    )

    // MARK: - saved-links
    private static let savedLinksScene = ActivitySceneDefinition(
        kind: .savedLinks,
        nodes: [
            .rect(x: 52, y: 14, width: 50, height: 36, rx: 3, style: .paper),
            .rect(x: 46, y: 10, width: 50, height: 36, rx: 3, style: .paper),
            .rect(x: 40, y: 6, width: 50, height: 36, rx: 3, style: .paper),
            .rect(x: 44, y: 10, width: 16, height: 12, rx: 1.5, style: SceneStyle.accent.withOpacity(0.3)),
            .path(d: "M64 13H76 M64 19H72", style: SceneStyle.line.withStrokeWidth(1.5)),
            .path(d: "M44 29H82 M44 35H70", style: SceneStyle.line.withStrokeWidth(1.5).withOpacity(0.6)),
            .path(
                d: "M78 6V20l4-3 4 3V6z",
                style: SceneStyle.warm.withOrigin(.center).withAnimation(
                    storyAnim("scene-sl-r", [
                        .at(0.0, ty: -12, opacity: 0),
                        .at(0.06, ty: -12, opacity: 0),
                        .at(0.24, identityTransform: true, opacity: 1),
                        .at(0.86, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - projects
    private static let projectsScene = ActivitySceneDefinition(
        kind: .projects,
        nodes: [
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-pj-f0", [
                        .at(0.0, ty: -8, opacity: 0),
                        .at(0.1, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: folderNodes(x: 16)
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-pj-f1", [
                        .at(0.0, ty: -8, opacity: 0),
                        .at(0.08, ty: -8, opacity: 0),
                        .at(0.18, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: [
                    .group(
                        style: SceneStyle.none.withOrigin(.center).withAnimation(
                            storyAnim("scene-pj-lift", easing: .easeInOut, [
                                .at(0.0, identityTransform: true),
                                .at(0.36, identityTransform: true),
                                .at(0.46, ty: -5),
                                .at(0.88, ty: -5),
                                .at(1.0, identityTransform: true),
                            ])
                        ),
                        children: folderNodes(x: 51) + [
                            .rect(
                                x: 53, y: 15, width: 12, height: 7, rx: 1.5,
                                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                                    storyAnim("scene-pj-tab", [
                                        .at(0.0, opacity: 0),
                                        .at(0.4, opacity: 0),
                                        .at(0.48, opacity: 1),
                                        .at(0.88, opacity: 1),
                                        .at(1.0, opacity: 0),
                                    ])
                                )
                            ),
                            .rect(x: 51, y: 19, width: 30, height: 25, rx: 2.5, style: SceneStyle.paper.withFill(nil)),
                            .group(
                                style: SceneStyle.none.withOrigin(.center).withAnimation(
                                    storyAnim("scene-pj-check", [
                                        .at(0.0, scale: 0),
                                        .at(0.54, scale: 0),
                                        .at(0.59, scale: 1.3),
                                        .at(0.62, scale: 1),
                                        .at(0.88, scale: 1),
                                        .at(1.0, scale: 0),
                                    ])
                                ),
                                children: doneBadge(x: 81, y: 19)
                            ),
                        ]
                    ),
                ]
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-pj-f2", [
                        .at(0.0, ty: -8, opacity: 0),
                        .at(0.16, ty: -8, opacity: 0),
                        .at(0.26, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: folderNodes(x: 86)
            ),
        ]
    )

    // MARK: - library
    // Built up piece by piece: as one `+` chain of implicit-member literals this
    // exceeds the type checker's budget on some toolchains (e.g. CLT Swift 6.2.4).
    private static let libraryScene: ActivitySceneDefinition = {
        var nodes: [SceneNode] = shelfTile(x: 30, y: 6, thumb: [
            .path(d: "M33 22l5-6 4 4 3-3 4 5z", style: SceneStyle.accent.withOpacity(0.55)),
            .circle(cx: 46, cy: 11, r: 2, style: .warm),
        ])
        nodes += shelfTile(x: 56, y: 6, thumb: [
            .path(d: "M60 11H74 M60 15.5H72 M60 20H68", style: SceneStyle.line.withStrokeWidth(1.5)),
        ])
        nodes += shelfTile(x: 82, y: 6, thumb: [
            .path(d: "M86 22v-5h3v5z M91 22v-9h3v9z M96 22v-7h3v7z", style: SceneStyle.accent.withOpacity(0.8)),
        ])
        nodes += shelfTile(x: 30, y: 31, thumb: [
            .rect(x: 33, y: 35, width: 7, height: 5, rx: 1, style: .empty),
            .rect(x: 44, y: 42, width: 7, height: 5, rx: 1, style: .empty),
            .path(d: "M40 37.5C44 37.5 44 44.5 44 44.5", style: SceneStyle.line.withStrokeWidth(1.2)),
        ])
        nodes += [
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-lib-pop", [
                        .at(0.0, identityTransform: true),
                        .at(0.5, identityTransform: true),
                        .at(0.56, scale: 1.14),
                        .at(0.62, scale: 1.08),
                        .at(0.88, scale: 1.08),
                        .at(1.0, identityTransform: true),
                    ])
                ),
                children: shelfTile(x: 56, y: 31, thumb: [
                    .path(d: "M64 35.5v10l8-5z", style: .accent),
                ]) + [
                    .rect(
                        x: 56, y: 31, width: 22, height: 19, rx: 2,
                        style: SceneStyle.accent.withOpacity(0.3).withOrigin(.center).withAnimation(
                            storyAnim("scene-lib-hit", [
                                .at(0.0, opacity: 0),
                                .at(0.46, opacity: 0),
                                .at(0.52, opacity: 0.3),
                                .at(0.88, opacity: 0.3),
                                .at(1.0, opacity: 0),
                            ])
                        )
                    ),
                ]
            ),
        ]
        nodes += shelfTile(x: 82, y: 31, thumb: [
            .path(d: "M85 47l5-6 4 4 3-3 4 5z", style: SceneStyle.muted.withOpacity(0.6)),
        ])
        nodes += [
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-lib-lens", easing: .easeInOut, [
                        .at(0.0, identityTransform: true),
                        .at(0.08, identityTransform: true),
                        .at(0.2, tx: 26),
                        .at(0.32, tx: 26),
                        .at(0.46, tx: 26, ty: 25),
                        .at(0.84, tx: 26, ty: 25),
                        .at(1.0, identityTransform: true),
                    ])
                ),
                children: [
                    .circle(cx: 41, cy: 15.5, r: 6.5, style: SceneStyle(fill: .surface, fillOpacity: 0.4, stroke: .accent, strokeWidth: 2)),
                    .path(d: "M45.6 20.1l4.4 4.4", style: .lineAccent),
                ]
            ),
        ]
        return ActivitySceneDefinition(kind: .library, nodes: nodes)
    }()

    // MARK: - inbox
    private static let inboxScene = ActivitySceneDefinition(
        kind: .inbox,
        nodes: [(SceneColorToken.accent, 5.0, 80.0), (.stateDone, 23.0, 84.0), (.stateProgress, 14.0, 74.0)]
            .sorted { $0.1 < $1.1 }
            .enumerated()
            .map { i, item in
                let (dot, y, end) = item
                let s = Double(i) * 0.14
                let e = 0.12 + Double(i) * 0.14
                return .group(
                    style: SceneStyle.none.withOrigin(.center).withAnimation(
                        storyAnim("scene-ib-c\(i)", [
                            .at(0.0, ty: -10, opacity: 0),
                            .at(s, ty: -10, opacity: 0),
                            .at(e, identityTransform: true, opacity: 1),
                            .at(0.88, identityTransform: true, opacity: 1),
                            .at(1.0, opacity: 0),
                        ])
                    ),
                    children: [
                        .rect(x: 42, y: y, width: 48, height: 8, rx: 2, style: .paper),
                        .circle(cx: 47, cy: y + 4, r: 2, style: SceneStyle(fill: dot)),
                        .path(d: "M52 \(fmt(y + 4))H\(fmt(end))", style: SceneStyle.line.withStrokeWidth(1.5)),
                    ]
                )
            } + [
                .path(d: "M28 34h20l4 6h28l4-6h20v16H28z", style: SceneStyle.paper.withLineJoin(.round)),
                .group(
                    style: SceneStyle.none.withOrigin(.center).withAnimation(
                        storyAnim("scene-ib-n", [
                            .at(0.0, scale: 0),
                            .at(0.46, scale: 0),
                            .at(0.51, scale: 1.35),
                            .at(0.54, scale: 1),
                            .at(0.88, scale: 1),
                            .at(1.0, scale: 0),
                        ])
                    ),
                    children: [
                        .circle(cx: 108, cy: 34, r: 6.5, style: .warm),
                        .text(x: 108, y: 37, string: "3", fontSize: 8.5, fontWeight: 700, anchor: .middle, fill: .surface),
                    ]
                ),
            ]
    )

    // MARK: - chart
    private static let chartScene = ActivitySceneDefinition(
        kind: .chart,
        nodes: [
            .path(d: "M26 18H114 M26 28H114 M26 38H114", style: SceneStyle.line.withStrokeWidth(1).withOpacity(0.3)),
            .path(d: "M26 6V48H114", style: SceneStyle.line.withStrokeWidth(1.5).withLineJoin(.round)),
            .path(
                d: "M32 40L50 30L68 34L86 20L106 12",
                style: SceneStyle.lineAccent.withLineJoin(.round).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-ch-l", easing: .linear, [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.02, opacity: 1, dashOffset: 1),
                        .at(0.6, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
        ] + [(32.0, 40.0, 0.02), (50.0, 30.0, 0.16), (68.0, 34.0, 0.29), (86.0, 20.0, 0.45), (106.0, 12.0, 0.60)].enumerated().map { i, pt in
            .circle(
                cx: pt.0, cy: pt.1, r: 2.8,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-ch-p\(i)", [
                        .at(0.0, scale: 0),
                        .at(pt.2, scale: 0),
                        .at(pt.2 + 0.05, scale: 1.3),
                        .at(pt.2 + 0.08, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            )
        }
    )

    // MARK: - diagram
    private static let diagramScene = ActivitySceneDefinition(
        kind: .diagram,
        nodes: [
            .rect(x: 16, y: 3, width: 32, height: 10, rx: 2, style: .paper),
            .rect(x: 84, y: 3, width: 32, height: 10, rx: 2, style: .paper),
            .path(d: "M24 8H40 M92 8H108", style: SceneStyle.line.withStrokeWidth(1.5)),
            .path(d: "M32 14V53 M100 14V53", style: SceneStyle.line.withStrokeWidth(1.2).withDash([2, 3]).withOpacity(0.6)),
        ] + [("M34 22H96", 0.04), ("M98 33H36", 0.28), ("M34 44H96", 0.52)].enumerated().map { i, item in
            .path(
                d: item.0,
                style: SceneStyle.lineAccent.withStrokeWidth(1.6).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-sq-m\(i)", easing: .easeInOut, [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(item.1, opacity: 1, dashOffset: 1),
                        .at(item.1 + 0.14, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            )
        } + [("M92.5 19l3.5 3-3.5 3", 0.17), ("M39.5 30l-3.5 3 3.5 3", 0.41), ("M92.5 41l3.5 3-3.5 3", 0.65)].enumerated().map { i, item in
            .path(
                d: item.0,
                style: SceneStyle.lineAccent.withStrokeWidth(1.6).withLineJoin(.round).withOrigin(.center).withAnimation(
                    storyAnim("scene-sq-h\(i)", [
                        .at(0.0, opacity: 0),
                        .at(item.1, opacity: 0),
                        .at(item.1 + 0.02, opacity: 1),
                        .at(0.88, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            )
        }
    )

    // MARK: - app
    private static let appScene = ActivitySceneDefinition(
        kind: .app,
        nodes: [
            .rect(x: 26, y: 4, width: 80, height: 48, rx: 4, style: .paper),
            .path(d: "M26 13H106", style: SceneStyle.line.withStrokeWidth(1).withOpacity(0.5)),
        ] + [31.0, 35.0, 39.0].map {
            .circle(cx: $0, cy: 8.5, r: 1.3, style: .muted)
        } + [
            .circle(cx: 66, cy: 27, r: 9, style: SceneStyle(fill: nil, stroke: .borderStrong, strokeWidth: 1.5, dashArray: [2, 2])),
            .circle(
                cx: 66, cy: 27, r: 9,
                style: SceneStyle.accent.withOpacity(0.75).withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-ap-grow", duration: 2.4, easing: .easeInOut, alternate: true, keyframes: [
                        .at(0.0, scale: 0.35),
                        .at(1.0, scale: 1.05),
                    ])
                )
            ),
            .path(d: "M38 44H94", style: SceneStyle.line.withStrokeWidth(1.5).withOpacity(0.4)),
            .path(
                d: "M38 44H94",
                style: SceneStyle.lineAccent.withStrokeWidth(1.5).withOrigin(.leftCenter).withAnimation(
                    MotionAnimation(name: "scene-ap-fill", duration: 2.4, easing: .easeInOut, alternate: true, keyframes: [
                        .at(0.0, sx: 0.15),
                        .at(1.0, identityTransform: true),
                    ])
                )
            ),
            .circle(
                cx: 46, cy: 44, r: 3.5,
                style: SceneStyle(
                    fill: .surface, stroke: .accent, strokeWidth: 2,
                    transformOrigin: .center,
                    animation: MotionAnimation(name: "scene-ap-knob", duration: 2.4, easing: .easeInOut, alternate: true, keyframes: [
                        .at(1.0, tx: 48),
                    ])
                )
            ),
        ]
    )

    // MARK: - custom-app
    private static let customAppScene = ActivitySceneDefinition(
        kind: .customApp,
        nodes: [
            .rect(x: 20, y: 4, width: 92, height: 48, rx: 4, style: .paper),
            .path(d: "M20 13H112", style: SceneStyle.line.withStrokeWidth(1).withOpacity(0.45)),
        ] + [26.0, 31.0, 36.0].map {
            .circle(cx: $0, cy: 8.5, r: 1.3, style: .muted)
        } + [
            .rect(
                x: 25, y: 17, width: 18, height: 30, rx: 2,
                style: SceneStyle.empty.withOrigin(.center).withAnimation(
                    storyAnim("scene-ca-nav", [
                        .at(0.0, tx: -6, opacity: 0),
                        .at(0.04, tx: -6, opacity: 0),
                        .at(0.16, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .rect(
                x: 47, y: 17, width: 28, height: 13, rx: 2,
                style: SceneStyle.accent.withOpacity(0.28).withOrigin(.center).withAnimation(
                    storyAnim("scene-ca-a", [
                        .at(0.0, scale: 0.8, opacity: 0),
                        .at(0.16, scale: 0.8, opacity: 0),
                        .at(0.28, identityTransform: true, opacity: 0.28),
                        .at(0.88, identityTransform: true, opacity: 0.28),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .rect(
                x: 79, y: 17, width: 28, height: 13, rx: 2,
                style: SceneStyle.empty.withOrigin(.center).withAnimation(
                    storyAnim("scene-ca-b", [
                        .at(0.0, scale: 0.8, opacity: 0),
                        .at(0.26, scale: 0.8, opacity: 0),
                        .at(0.38, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .rect(
                x: 47, y: 34, width: 60, height: 13, rx: 2,
                style: SceneStyle.empty.withOrigin(.center).withAnimation(caCAnim)
            ),
            .path(
                d: "M52 40.5H82",
                style: SceneStyle.lineAccent.withStrokeWidth(1.5).withOrigin(.center).withAnimation(caCAnim)
            ),
            .circle(
                cx: 105, cy: 8.5, r: 2.3,
                style: SceneStyle.done.withOrigin(.center).withAnimation(
                    storyAnim("scene-ca-live", [
                        .at(0.0, scale: 0),
                        .at(0.54, scale: 0),
                        .at(0.6, scale: 1.4),
                        .at(0.64, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
        ]
    )

    private static let caCAnim = storyAnim("scene-ca-c", [
        .at(0.0, ty: 6, opacity: 0),
        .at(0.38, ty: 6, opacity: 0),
        .at(0.5, identityTransform: true, opacity: 1),
        .at(0.88, identityTransform: true, opacity: 1),
        .at(1.0, opacity: 0),
    ])

    // MARK: - database
    private static let databaseScene = ActivitySceneDefinition(
        kind: .database,
        nodes: [
            .group(children: [
                .path(d: "M16 15v26c0 3.3 8 6 18 6s18-2.7 18-6V15z", style: .paper),
                .ellipse(cx: 34, cy: 15, rx: 18, ry: 5.5, style: .paper),
                .path(d: "M16 24c0 3 8 5.5 18 5.5S52 27 52 24 M16 33c0 3 8 5.5 18 5.5S52 36 52 33", style: SceneStyle.line.withStrokeWidth(1.3).withOpacity(0.55)),
                .ellipse(
                    cx: 34, cy: 24, rx: 15, ry: 3.5,
                    style: SceneStyle.accent.withOpacity(0.35).withOrigin(.center).withAnimation(
                        storyAnim("scene-db-scan", easing: .easeInOut, [
                            .at(0.0, ty: -9, opacity: 0),
                            .at(0.1, opacity: 0.4),
                            .at(0.34, ty: 9, opacity: 0.4),
                            .at(0.44, identityTransform: true, opacity: 0.35),
                            .at(0.88, identityTransform: true, opacity: 0.35),
                            .at(1.0, opacity: 0),
                        ])
                    )
                ),
            ]),
            .path(
                d: "M54 28H68",
                style: SceneStyle.lineAccent.withStrokeWidth(1.6).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-db-link", easing: .easeInOut, [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.24, opacity: 0, dashOffset: 1),
                        .at(0.26, opacity: 1),
                        .at(0.4, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .rect(x: 70, y: 9, width: 46, height: 38, rx: 3, style: .paper),
            .path(d: "M75 16H111", style: SceneStyle.lineAccent.withStrokeWidth(1.5).withOpacity(0.65)),
        ] + [(24.0, 108, 0.40), (32.0, 102, 0.48), (40.0, 106, 0.56)].enumerated().map { i, item in
            let (y, end, s) = item
            return .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-db-r\(i)", [
                        .at(0.0, tx: -5, opacity: 0),
                        .at(s, tx: -5, opacity: 0),
                        .at(s + 0.08, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: [
                    .circle(cx: 77, cy: y, r: 1.8, style: i == 0 ? .accent : .done),
                    .path(d: "M83 \(fmt(y))H\(end)", style: SceneStyle.line.withStrokeWidth(1.5)),
                ]
            )
        }
    )

    // MARK: - http
    private static let httpScene = ActivitySceneDefinition(
        kind: .http,
        nodes: [
            .rect(x: 12, y: 14, width: 28, height: 28, rx: 4, style: .paper),
            .path(d: "M18 24H30", style: SceneStyle.lineAccent.withStrokeWidth(1.6)),
            .path(d: "M18 31H34", style: SceneStyle.line.withStrokeWidth(1.5)),
            .path(d: "M43 22H89 M43 34H89", style: SceneStyle.line.withStrokeWidth(1.3).withDash([2, 3]).withOpacity(0.45)),
            .rect(
                x: 44, y: 19, width: 12, height: 6, rx: 3,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-http-req", easing: .easeInOut, [
                        .at(0.0, tx: 0, opacity: 0),
                        .at(0.04, tx: 0, opacity: 0),
                        .at(0.1, opacity: 1),
                        .at(0.32, tx: 34, opacity: 1),
                        .at(0.38, tx: 34, opacity: 0),
                        .at(1.0, tx: 34, opacity: 0),
                    ])
                )
            ),
            .rect(
                x: 76, y: 31, width: 12, height: 6, rx: 3,
                style: SceneStyle.done.withOrigin(.center).withAnimation(
                    storyAnim("scene-http-res", easing: .easeInOut, [
                        .at(0.0, tx: 0, opacity: 0),
                        .at(0.4, tx: 0, opacity: 0),
                        .at(0.46, opacity: 1),
                        .at(0.68, tx: -34, opacity: 1),
                        .at(0.74, tx: -34, opacity: 0),
                        .at(1.0, tx: -34, opacity: 0),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-http-srv", [
                        .at(0.0, identityTransform: true),
                        .at(0.3, identityTransform: true),
                        .at(0.38, scale: 1.06),
                        .at(0.48, identityTransform: true),
                        .at(1.0, identityTransform: true),
                    ])
                ),
                children: [
                    .rect(x: 92, y: 14, width: 28, height: 28, rx: 4, style: .paper),
                    .path(d: "M98 23H114 M98 29H110 M98 35H114", style: SceneStyle.line.withStrokeWidth(1.5)),
                ]
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-http-ok", [
                        .at(0.0, scale: 0),
                        .at(0.66, scale: 0),
                        .at(0.72, scale: 1.3),
                        .at(0.76, scale: 1),
                        .at(0.9, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: doneBadge(x: 118, y: 15)
            ),
        ]
    )

    // MARK: - pdf
    private static let pdfScene = ActivitySceneDefinition(
        kind: .pdf,
        nodes: [
            .path(d: "M38 4h38l12 12v36H38z", style: SceneStyle.paper.withLineJoin(.round)),
            .path(d: "M76 4v12h12", style: SceneStyle.line.withStrokeWidth(1.3).withLineJoin(.round)),
            .path(
                d: "M46 15H68",
                style: SceneStyle.lineAccent.withStrokeWidth(1.8).withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-pdf-l0", [
                        .at(0.0, sx: 0, opacity: 0),
                        .at(0.04, sx: 0, opacity: 0),
                        .at(0.16, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .path(
                d: "M46 23H80 M46 29H74",
                style: SceneStyle.line.withStrokeWidth(1.5).withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-pdf-l1", [
                        .at(0.0, sx: 0, opacity: 0),
                        .at(0.14, sx: 0, opacity: 0),
                        .at(0.28, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .path(
                d: "M46 35H78",
                style: SceneStyle.line.withStrokeWidth(1.5).withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-pdf-l2", [
                        .at(0.0, sx: 0, opacity: 0),
                        .at(0.26, sx: 0, opacity: 0),
                        .at(0.38, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-pdf-tag", [
                        .at(0.0, scale: 1.35, opacity: 0),
                        .at(0.4, scale: 1.35, opacity: 0),
                        .at(0.48, scale: 0.95, opacity: 1),
                        .at(0.54, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: [
                    .rect(x: 45, y: 40, width: 24, height: 9, rx: 2, style: .warm),
                    .text(x: 57, y: 47, string: "PDF", fontSize: 6.5, fontWeight: 700, anchor: .middle, fill: .surface),
                ]
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-pdf-done", [
                        .at(0.0, scale: 0),
                        .at(0.56, scale: 0),
                        .at(0.62, scale: 1.3),
                        .at(0.66, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: doneBadge(x: 88, y: 46)
            ),
        ]
    )

    // MARK: - subagent
    private static let subagentScene = ActivitySceneDefinition(
        kind: .subagent,
        nodes: [
            .path(d: "M34 28C56 28 62 15 92 15 M34 28C56 28 62 41 92 41", style: SceneStyle.line.withStrokeWidth(1.3).withDash([2.5, 2.5]).withOpacity(0.45)),
            .path(
                d: "M34 28C56 28 62 15 92 15",
                style: SceneStyle.lineAccent.withStrokeWidth(1.8).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-sa-out0", easing: .easeInOut, [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.04, opacity: 0, dashOffset: 1),
                        .at(0.06, opacity: 1),
                        .at(0.24, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .path(
                d: "M34 28C56 28 62 41 92 41",
                style: SceneStyle.lineAccent.withStrokeWidth(1.8).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-sa-out1", easing: .easeInOut, [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.14, opacity: 0, dashOffset: 1),
                        .at(0.16, opacity: 1),
                        .at(0.34, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .circle(cx: 25, cy: 28, r: 9.5, style: SceneStyle.paper.withStroke(.accent, width: 1.6)),
            .circle(cx: 25, cy: 28, r: 3.6, style: .accent),
        ] + [(15.0, 0.2), (41.0, 0.3)].enumerated().map { i, item in
            let (cy, s) = item
            return .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-sa-h\(i)", [
                        .at(0.0, scale: 0.8, opacity: 0.45),
                        .at(s, scale: 0.8, opacity: 0.45),
                        .at(s + 0.08, scale: 1.12, opacity: 1),
                        .at(s + 0.14, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0.45),
                    ])
                ),
                children: [
                    .circle(cx: 100, cy: cy, r: 7.5, style: SceneStyle.paper.withStroke(.accent, width: 1.5)),
                    .circle(cx: 100, cy: cy, r: 2.6, style: .accent),
                ]
            )
        } + [(12.0, 0.48), (44.0, 0.58)].enumerated().map { i, item in
            let (cy, s) = item
            return .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-sa-ok\(i)", [
                        .at(0.0, scale: 0),
                        .at(s, scale: 0),
                        .at(s + 0.06, scale: 1.3),
                        .at(s + 0.1, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: doneBadge(x: 111, y: cy)
            )
        }
    )

    // MARK: - choices
    private static let choicesScene = ActivitySceneDefinition(
        kind: .choices,
        nodes: [5.0, 22.0, 39.0].map {
            .rect(x: 30, y: $0, width: 72, height: 12, rx: 6, style: .paper)
        } + [
            .rect(
                x: 30, y: 22, width: 72, height: 12, rx: 6,
                style: SceneStyle.accent.withFillOpacity(0.22).withOrigin(.center).withAnimation(
                    storyAnim("scene-cho-hl", easing: .easeInOut, [
                        .at(0.0, ty: -17, opacity: 1),
                        .at(0.14, ty: -17, opacity: 1),
                        .at(0.24, identityTransform: true),
                        .at(0.38, identityTransform: true),
                        .at(0.48, ty: 17),
                        .at(0.58, ty: 17),
                        .at(0.68, identityTransform: true, opacity: 1),
                        .at(0.94, identityTransform: true, opacity: 1),
                        .at(1.0, identityTransform: true, opacity: 0),
                    ])
                )
            ),
        ] + [11.0, 28.0, 45.0].map {
            .circle(cx: 38, cy: $0, r: 3, style: .empty)
        } + [
            .path(d: "M46 11H86 M46 28H92 M46 45H80", style: SceneStyle.line.withStrokeWidth(1.5)),
            .circle(
                cx: 38, cy: 28, r: 1.8,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-cho-dot", [
                        .at(0.0, scale: 0),
                        .at(0.76, scale: 0),
                        .at(0.81, scale: 1.3),
                        .at(0.84, scale: 1),
                        .at(0.94, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-cho-cur", easing: .easeInOut, [
                        .at(0.0, tx: 16, ty: 16, opacity: 0),
                        .at(0.56, tx: 16, ty: 16, opacity: 0),
                        .at(0.7, identityTransform: true, opacity: 1),
                        .at(0.74, scale: 0.8),
                        .at(0.78, identityTransform: true, opacity: 1),
                        .at(0.94, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: [.path(d: "M94 30v9l2.6-2.4 3.6-.2z", style: SceneStyle(fill: .text))]
            ),
        ]
    )
}
