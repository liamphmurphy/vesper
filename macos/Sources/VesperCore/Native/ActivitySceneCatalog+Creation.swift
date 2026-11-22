import Foundation

extension ActivitySceneCatalog {
    static let creationDefinitions: [ActivitySceneKind: ActivitySceneDefinition] = [
        .image: imageScene,
        .canvas: canvasScene(kind: .canvas, pin: false),
        .canvasComment: canvasScene(kind: .canvasComment, pin: true),
        .design: designScene,
        .runs: runsScene,
        .workflow: workflowScene,
        .connector: connectorScene,
        .secret: secretScene,
        .memory: memoryScene,
        .memorySave: memorySaveScene,
        .playground: playgroundScene,
        .chatHistory: chatHistoryScene,
        .repoSearch: repoSearchScene,
        .repoAttach: repoAttachScene,
        .videoRender: videoRenderScene,
        .audioRender: audioRenderScene,
        .finance: financeScene,
        .financeSort: financeSortScene,
    ]

    // MARK: - image (and alias image-view)
    private static let imageColors: [SceneColorToken] = [
        .borderStrong, .textTertiary, .accent, .accent,
        .textTertiary, .accent, .accent, .stateProgress,
        .borderStrong, .stateDone, .stateDone, .stateDone,
    ]

    private static let imageScene = ActivitySceneDefinition(
        kind: .image,
        rootAnimation: MotionAnimation(name: "scene-focus", duration: 3.2, easing: .easeOut, keyframes: [
            .at(0.0, blur: 3),
            .at(0.7, blur: 0),
            .at(1.0, blur: 0),
        ]),
        nodes: [.rect(x: 30, y: 4, width: 72, height: 48, rx: 5, style: .paper)]
            + imageColors.enumerated().map { i, fill in
                let delay = Double((i * 5) % 12) * 0.08
                let opacity = (i % 4 == 2) ? 0.78 : 1.0
                return .rect(
                    x: 36 + Double(i % 4) * 15.5,
                    y: 9 + Double(i / 4) * 13,
                    width: 13.5,
                    height: 11,
                    rx: 2,
                    style: SceneStyle(
                        fill: fill,
                        opacity: opacity,
                        animation: MotionAnimation(name: "scene-tile", duration: 3.2, delay: delay, easing: .easeOut, fillMode: .both, keyframes: [
                            .at(0.0, opacity: 0.25),
                            .at(0.6, opacity: 1),
                            .at(1.0, opacity: 1),
                        ])
                    )
                )
            }
    )

    // MARK: - canvas & canvas-comment
    private static func canvasScene(kind: ActivitySceneKind, pin: Bool) -> ActivitySceneDefinition {
        var nodes: [SceneNode] = [
            .rect(x: 30, y: 4, width: 72, height: 48, rx: 3, style: .paper),
        ]
        for (i, d) in ["M42 14H70V32H42Z", "M84 22a8 8 0 1 0 .01 0", "M42 42H90"].enumerated() {
            nodes.append(
                .path(d: d, style: SceneStyle.lineAccent.withPathLengthOne().withAnimation(sceneLink.delayed(by: Double(i) * 0.35)))
            )
        }
        if pin {
            nodes.append(
                .group(
                    style: SceneStyle.none.withOrigin(.center).withAnimation(
                        MotionAnimation(name: "scene-pin", duration: 4.0, easing: .easeOut, fillMode: .both, keyframes: [
                            .at(0.0, ty: -10, opacity: 0),
                            .at(0.4, ty: -10, opacity: 0),
                            .at(0.52, identityTransform: true, opacity: 1),
                            .at(0.58, ty: -2),
                            .at(0.64, identityTransform: true, opacity: 1),
                            .at(0.9, identityTransform: true, opacity: 1),
                            .at(1.0, identityTransform: true, opacity: 0),
                        ])
                    ),
                    children: [
                        .path(d: "M92 20c-4-5-6-7-6-10a6 6 0 0 1 12 0c0 3-2 5-6 10z", style: .warm),
                    ]
                )
            )
        }
        nodes.append(
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-cursor", duration: 4.0, easing: .easeInOut, keyframes: [
                        .at(0.0, tx: -28, ty: -18),
                        .at(0.3, identityTransform: true),
                        .at(0.6, tx: 14, ty: -2),
                        .at(0.85, tx: 20, ty: 10),
                        .at(1.0, tx: -28, ty: -18),
                    ])
                ),
                children: [
                    .path(d: "M70 32v9l2.6-2.4 3.6-.2z", style: SceneStyle(fill: .text)),
                ]
            )
        )
        return ActivitySceneDefinition(kind: kind, nodes: nodes)
    }

    // MARK: - design (and alias design-view)
    private static let designScene = ActivitySceneDefinition(
        kind: .design,
        nodes: [
            .rect(x: 26, y: 4, width: 32, height: 48, rx: 4, style: .paper),
            .path(
                d: "M30 4H54a4 4 0 0 1 4 4V48a4 4 0 0 1-4 4H30a4 4 0 0 1-4-4V8a4 4 0 0 1 4-4z",
                style: SceneStyle.lineAccent.withStrokeWidth(1.5).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-sketch", easing: .easeInOut, [
                        .at(0.0, opacity: 1, dashOffset: 1),
                        .at(0.02, opacity: 1, dashOffset: 1),
                        .at(0.2, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .path(
                d: "M32 12H46",
                style: SceneStyle.line.withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-dz-a0", [
                        .at(0.0, sx: 0),
                        .at(0.12, sx: 0),
                        .at(0.18, sx: 1, opacity: 1),
                        .at(0.88, sx: 1, opacity: 1),
                        .at(1.0, sx: 1, opacity: 0),
                    ])
                )
            ),
            .path(
                d: "M32 19H52M32 25H48",
                style: SceneStyle.line.withStrokeWidth(1.5).withOpacity(0.6).withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-dz-a1", [
                        .at(0.0, sx: 0),
                        .at(0.16, sx: 0),
                        .at(0.22, sx: 1, opacity: 0.6),
                        .at(0.88, sx: 1, opacity: 0.6),
                        .at(1.0, sx: 1, opacity: 0),
                    ])
                )
            ),
            .rect(
                x: 32, y: 40, width: 20, height: 7, rx: 2,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-btn", [
                        .at(0.0, scale: 0),
                        .at(0.22, scale: 0),
                        .at(0.26, scale: 1.25),
                        .at(0.29, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
            .path(
                d: "M52 43.5C68 43.5 68 20 83 20",
                style: SceneStyle.lineAccent.withStrokeWidth(1.6).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-wire", easing: .easeInOut, [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.3, opacity: 0, dashOffset: 1),
                        .at(0.31, opacity: 1),
                        .at(0.46, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .path(
                d: "M81 16.5l4 3.5-4 3.5z",
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-head", [
                        .at(0.0, scale: 0),
                        .at(0.45, scale: 0),
                        .at(0.48, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
            .rect(
                x: 86, y: 4, width: 32, height: 48, rx: 4,
                style: SceneStyle.paper.withStroke(.accent, width: 1.5).withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-frame", [
                        .at(0.0, scale: 0.85, opacity: 0),
                        .at(0.44, scale: 0.85, opacity: 0),
                        .at(0.52, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .path(
                d: "M92 12H106",
                style: SceneStyle.lineAccent.withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-dz-b0", [
                        .at(0.0, sx: 0),
                        .at(0.52, sx: 0),
                        .at(0.58, sx: 1, opacity: 1),
                        .at(0.88, sx: 1, opacity: 1),
                        .at(1.0, sx: 1, opacity: 0),
                    ])
                )
            ),
            .path(
                d: "M92 19H112M92 25H104",
                style: SceneStyle.line.withStrokeWidth(1.5).withOpacity(0.6).withOrigin(.leftCenter).withAnimation(
                    storyAnim("scene-dz-b1", [
                        .at(0.0, sx: 0),
                        .at(0.56, sx: 0),
                        .at(0.62, sx: 1, opacity: 0.6),
                        .at(0.88, sx: 1, opacity: 0.6),
                        .at(1.0, sx: 1, opacity: 0),
                    ])
                )
            ),
            .rect(
                x: 92, y: 40, width: 20, height: 7, rx: 2,
                style: SceneStyle.accent.withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-b2", [
                        .at(0.0, scale: 0),
                        .at(0.62, scale: 0),
                        .at(0.66, scale: 1.25),
                        .at(0.69, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
            .path(
                d: sparklePath(x: 122, y: 12, s: 6),
                style: SceneStyle.warm.withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-spark", [
                        .at(0.0, scale: 0),
                        .at(0.7, scale: 0),
                        .at(0.75, scale: 1.3),
                        .at(0.78, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-dz-cur", easing: .easeInOut, [
                        .at(0.0, tx: -60, ty: 2, opacity: 0),
                        .at(0.24, tx: -60, ty: 2, opacity: 0),
                        .at(0.28, tx: -60, ty: 2, opacity: 1),
                        .at(0.48, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, identityTransform: true, opacity: 0),
                    ])
                ),
                children: [.path(d: "M104 36v9l2.6-2.4 3.6-.2z", style: SceneStyle(fill: .text))]
            ),
        ]
    )

    // MARK: - runs
    private static let baseRunBarAnim = MotionAnimation(
        name: "scene-bar",
        duration: 3.0,
        easing: .easeInOut,
        alternate: true,
        keyframes: [
            .at(0.0, sx: 0.15),
            .at(1.0, sx: 1),
        ]
    )

    private static let runsScene = ActivitySceneDefinition(
        kind: .runs,
        nodes: [
            (6.0, 0.8, 2.6, SceneColorToken.accent),
            (22.0, 0.5, 3.7, SceneColorToken.stateDone),
            (38.0, 0.68, 3.1, SceneColorToken.stateProgress),
        ].map { y, rest, seconds, stroke in
            .group(children: [
                .rect(x: 18, y: y, width: 96, height: 12, rx: 3, style: .paper),
                .circle(cx: 26, cy: y + 6, r: 2.4, style: SceneStyle(fill: stroke)),
                .path(d: "M34 \(fmt(y + 6))H106", style: SceneStyle.line.withStrokeWidth(2.2).withOpacity(0.25)),
                .path(
                    d: "M34 \(fmt(y + 6))H106",
                    style: SceneStyle.line
                        .withStroke(stroke, width: 2.2)
                        .withBaseTransform(MotionTransform(sx: rest, sy: 1))
                        .withOrigin(.leftCenter)
                        .withAnimation(baseRunBarAnim.withDuration(seconds))
                ),
            ])
        }
    )

    // MARK: - workflow
    private static let workflowScene = ActivitySceneDefinition(
        kind: .workflow,
        nodes: [
            .path(
                d: "M30 28C42 28 44 14 56 14 M30 28C42 28 44 42 56 42 M74 14C86 14 88 28 98 28 M74 42C86 42 88 28 98 28",
                style: .line
            ),
        ] + [(12.0, 22.0, 0.0), (56.0, 8.0, 0.5), (56.0, 36.0, 0.5), (98.0, 22.0, 1.0)].map { x, y, wait in
            .rect(
                x: x, y: y, width: 18, height: 12, rx: 3,
                style: SceneStyle.accent.withAnimation(
                    MotionAnimation(name: "scene-light", duration: 3.2, delay: wait, easing: .easeInOut, fillMode: .both, keyframes: [
                        .at(0.0, fill: .borderStrong),
                        .at(0.15, fill: .accent),
                        .at(0.6, fill: .accent),
                        .at(0.8, fill: .borderStrong),
                        .at(1.0, fill: .borderStrong),
                    ])
                )
            )
        }
    )

    // MARK: - connector
    private static let connectorScene = ActivitySceneDefinition(
        kind: .connector,
        nodes: [
            .rect(x: 24, y: 19, width: 26, height: 18, rx: 4, style: SceneStyle.accent.withOrigin(.center).withAnimation(scenePlug)),
            .path(d: "M8 28H24M50 23H60M50 33H60", style: SceneStyle.lineAccent.withAnimation(scenePlug)),
            .rect(x: 82, y: 17, width: 26, height: 22, rx: 4, style: SceneStyle.warm.withFillOpacity(0.85)),
            .path(d: "M108 28H124", style: .lineAccent),
            .path(d: "M64 23H82M64 33H82", style: SceneStyle.lineAccent.withStrokeOpacity(0.5).withPathLengthOne().withAnimation(sceneLink)),
            .circle(cx: 73, cy: 10, r: 2.5, style: SceneStyle.warm.withOrigin(.center).withAnimation(sceneNode)),
            .circle(cx: 66, cy: 47, r: 2, style: SceneStyle.accent.withOrigin(.center).withAnimation(sceneNode.delayed(by: 0.5))),
            .circle(cx: 80, cy: 47, r: 2, style: SceneStyle.warm.withOrigin(.center).withAnimation(sceneNode.delayed(by: 1.0))),
        ]
    )

    // MARK: - secret
    private static let secretScene = ActivitySceneDefinition(
        kind: .secret,
        nodes: [
            .group(
                style: SceneStyle.none.withAnimation(scenePlug),
                children: [
                    .circle(cx: 28, cy: 29, r: 7.5, style: SceneStyle.warm.withFillOpacity(0.88)),
                    .circle(cx: 28, cy: 29, r: 2.5, style: SceneStyle(fill: .surface)),
                    .path(d: "M36 29H58M49 29V35M55 29V34", style: .lineAccent),
                ]
            ),
            .path(d: "M62 29H82", style: SceneStyle.lineAccent.withStrokeOpacity(0.45).withPathLengthOne().withAnimation(sceneLink)),
            .path(
                d: "M89 23V17a7 7 0 0 1 14 0v6",
                style: SceneStyle.lineAccent.withAnimation(
                    MotionAnimation(name: "scene-sec-shackle", duration: 2.4, easing: .easeInOut, keyframes: [
                        .at(0.0, identityTransform: true),
                        .at(0.35, identityTransform: true),
                        .at(0.55, ty: -3),
                        .at(0.75, ty: -3),
                        .at(1.0, identityTransform: true),
                    ])
                )
            ),
            .rect(x: 84, y: 23, width: 24, height: 20, rx: 3.5, style: SceneStyle.paper.withStroke(.accent, width: 1.5)),
            .circle(cx: 96, cy: 33, r: 2.6, style: SceneStyle.warm.withOrigin(.center).withAnimation(sceneNode.delayed(by: 0.4))),
        ]
    )

    // MARK: - memory
    private static let memoryScene = ActivitySceneDefinition(
        kind: .memory,
        nodes: ["M30 44L54 16", "M54 16L84 32", "M84 32L106 10", "M54 16L72 50", "M72 50L84 32"].enumerated().map { i, d in
            .path(d: d, style: SceneStyle.lineAccent.withStrokeOpacity(0.6).withPathLengthOne().withAnimation(sceneLink.delayed(by: Double(i) * 0.35)))
        } + [
            .circle(cx: 30, cy: 44, r: 3.5, style: SceneStyle.accent.withOrigin(.center).withAnimation(sceneNode)),
            .circle(cx: 54, cy: 16, r: 4.5, style: SceneStyle.accent.withOrigin(.center).withAnimation(sceneNode.delayed(by: 0.3))),
            .circle(cx: 84, cy: 32, r: 4, style: SceneStyle.accent.withOrigin(.center).withAnimation(sceneNode.delayed(by: 0.6))),
            .circle(cx: 106, cy: 10, r: 5, style: SceneStyle.warm.withOrigin(.center).withAnimation(sceneNode.delayed(by: 0.9))),
            .circle(cx: 72, cy: 50, r: 3, style: SceneStyle.accent.withOrigin(.center).withAnimation(sceneNode.delayed(by: 1.2))),
        ]
    )

    // MARK: - memory-save
    private static let memorySaveScene = ActivitySceneDefinition(
        kind: .memorySave,
        nodes: [
            .path(d: "M26 42L48 18L72 36L50 48Z", style: SceneStyle.line.withStrokeWidth(1.4).withOpacity(0.45)),
            .circle(cx: 26, cy: 42, r: 3.2, style: SceneStyle.accent.withOpacity(0.7)),
            .circle(cx: 48, cy: 18, r: 4, style: SceneStyle.accent.withOpacity(0.85)),
            .circle(cx: 72, cy: 36, r: 3.8, style: SceneStyle.accent.withOpacity(0.75)),
            .circle(cx: 50, cy: 48, r: 2.8, style: SceneStyle.accent.withOpacity(0.6)),
            .path(
                d: "M48 18L98 18",
                style: SceneStyle.lineAccent.withStrokeWidth(1.6).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-ms-link0", easing: .easeInOut, [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.22, opacity: 0, dashOffset: 1),
                        .at(0.24, opacity: 1),
                        .at(0.42, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .path(
                d: "M72 36L98 18",
                style: SceneStyle.lineAccent.withStrokeWidth(1.6).withPathLengthOne().withOrigin(.center).withAnimation(
                    storyAnim("scene-ms-link1", easing: .easeInOut, [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.3, opacity: 0, dashOffset: 1),
                        .at(0.32, opacity: 1),
                        .at(0.5, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .circle(
                cx: 98, cy: 18, r: 6,
                style: SceneStyle.warm.withOrigin(.center).withAnimation(
                    storyAnim("scene-ms-node", [
                        .at(0.0, tx: 12, ty: -12, scale: 0.3, opacity: 0),
                        .at(0.04, tx: 12, ty: -12, scale: 0.3, opacity: 0),
                        .at(0.18, scale: 1.2, opacity: 1),
                        .at(0.24, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .path(
                d: sparklePath(x: 112, y: 10, s: 5),
                style: SceneStyle.warm.withOrigin(.center).withAnimation(
                    storyAnim("scene-ms-spark", [
                        .at(0.0, scale: 0),
                        .at(0.52, scale: 0),
                        .at(0.58, scale: 1.3),
                        .at(0.62, scale: 1),
                        .at(0.88, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - playground
    private static let pg1Anim = MotionAnimation(name: "scene-pg-1", duration: 4.8, easing: .easeOut, fillMode: .both, keyframes: [
        .at(0.0, ty: -8, opacity: 0),
        .at(0.1, identityTransform: true, opacity: 1),
        .at(0.88, identityTransform: true, opacity: 1),
        .at(1.0, opacity: 0),
    ])
    private static let pg2Anim = MotionAnimation(name: "scene-pg-2", duration: 4.8, easing: .easeOut, fillMode: .both, keyframes: [
        .at(0.0, ty: -8, opacity: 0),
        .at(0.12, ty: -8, opacity: 0),
        .at(0.22, identityTransform: true, opacity: 1),
        .at(0.88, identityTransform: true, opacity: 1),
        .at(1.0, opacity: 0),
    ])
    private static let pg3Anim = MotionAnimation(name: "scene-pg-3", duration: 4.8, easing: .easeOut, fillMode: .both, keyframes: [
        .at(0.0, ty: -8, opacity: 0),
        .at(0.24, ty: -8, opacity: 0),
        .at(0.34, identityTransform: true, opacity: 1),
        .at(0.88, identityTransform: true, opacity: 1),
        .at(1.0, opacity: 0),
    ])

    private static let playgroundScene = ActivitySceneDefinition(
        kind: .playground,
        nodes: [
            .rect(x: 14, y: 40, width: 32, height: 11, rx: 5.5, style: SceneStyle.paper.withAnimation(pg1Anim)),
            .path(d: "M21 45.5H39", style: SceneStyle.line.withStrokeWidth(1.5).withAnimation(pg1Anim)),
            .rect(x: 14, y: 27, width: 32, height: 11, rx: 2.5, style: SceneStyle.paper.withAnimation(pg2Anim)),
            .path(d: "M24 32.5l3 3 6-6", style: SceneStyle.lineDone.withStrokeWidth(1.5).withAnimation(pg2Anim)),
            .rect(x: 14, y: 14, width: 32, height: 11, rx: 2.5, style: SceneStyle.paper.withAnimation(pg3Anim)),
            .path(d: "M27 16.5v6l5-3z", style: SceneStyle.accent.withAnimation(pg3Anim)),
            .path(
                d: "M48 19.5C58 19.5 58 28 68 28",
                style: SceneStyle.lineAccent.withPathLengthOne().withAnimation(
                    MotionAnimation(name: "scene-pg-link", duration: 4.8, easing: .easeInOut, fillMode: .both, keyframes: [
                        .at(0.0, opacity: 0, dashOffset: 1),
                        .at(0.36, opacity: 0, dashOffset: 1),
                        .at(0.38, opacity: 1),
                        .at(0.5, opacity: 1, dashOffset: 0),
                        .at(0.88, opacity: 1, dashOffset: 0),
                        .at(1.0, opacity: 0, dashOffset: 0),
                    ])
                )
            ),
            .rect(x: 70, y: 6, width: 50, height: 44, rx: 4, style: .paper),
            .path(d: "M71 15H119", style: SceneStyle.line.withStrokeWidth(1).withStrokeOpacity(0.5)),
        ] + [75.0, 79.0, 83.0].map {
            .circle(cx: $0, cy: 10.5, r: 1.3, style: .muted)
        } + [
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-pg-page", duration: 4.8, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, ty: 3, opacity: 0),
                        .at(0.5, ty: 3, opacity: 0),
                        .at(0.6, identityTransform: true, opacity: 1),
                        .at(0.88, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                ),
                children: [
                    .path(d: "M76 22H108 M76 29H100", style: SceneStyle.line.withStrokeWidth(1.5)),
                    .rect(x: 76, y: 36, width: 20, height: 7, rx: 2, style: .accent),
                ]
            ),
            .circle(
                cx: 114, cy: 10.5, r: 2.4,
                style: SceneStyle(
                    fill: nil, stroke: .stateDone, strokeOpacity: 0.4, strokeWidth: 1,
                    transformOrigin: .center,
                    animation: MotionAnimation(name: "scene-pg-ring", duration: 4.8, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, scale: 1, opacity: 0),
                        .at(0.64, scale: 1, opacity: 0),
                        .at(0.67, opacity: 1),
                        .at(0.86, scale: 2.8, opacity: 0),
                        .at(1.0, scale: 2.8, opacity: 0),
                    ])
                )
            ),
            .circle(
                cx: 114, cy: 10.5, r: 2.4,
                style: SceneStyle.done.withOrigin(.center).withAnimation(
                    MotionAnimation(name: "scene-pg-live", duration: 4.8, easing: .easeOut, fillMode: .both, keyframes: [
                        .at(0.0, scale: 0),
                        .at(0.62, scale: 0),
                        .at(0.68, scale: 1.4),
                        .at(0.74, scale: 1, opacity: 1),
                        .at(0.88, scale: 1, opacity: 1),
                        .at(1.0, scale: 1, opacity: 0),
                    ])
                )
            ),
        ]
    )

    // MARK: - chat-history
    private static let chatHistoryScene = ActivitySceneDefinition(
        kind: .chatHistory,
        nodes: [
            (22.0, 4.0, 48.0, "M30 16l-4 5 9-5", 0),
            (62.0, 21.0, 48.0, "M102 33l4 5-9-5", 1),
            (22.0, 38.0, 40.0, "", 2),
        ].map { x, y, w, tail, i in
            var kids: [SceneNode] = []
            if !tail.isEmpty { kids.append(.path(d: tail, style: .paper)) }
            kids.append(.rect(x: x, y: y, width: w, height: 13, rx: 6.5, style: .paper))
            kids.append(
                .rect(
                    x: x, y: y, width: w, height: 13, rx: 6.5,
                    style: SceneStyle.accent.withOpacity(0).withAnimation(
                        MotionAnimation(name: "scene-history-hit", duration: 3.96, delay: Double(i) * 1.32, easing: .easeInOut, fillMode: .both, keyframes: [
                            .at(0.0, opacity: 0),
                            .at(0.06, opacity: 0.3),
                            .at(0.18, opacity: 0.3),
                            .at(0.3, opacity: 0),
                            .at(1.0, opacity: 0),
                        ])
                    )
                )
            )
            kids.append(.path(d: "M\(fmt(x + 7)) \(fmt(y + 6.5))H\(fmt(x + w - 12))", style: SceneStyle.line.withStrokeWidth(1.5)))
            return .group(children: kids)
        } + [
            .group(
                style: SceneStyle.none.withAnimation(
                    MotionAnimation(name: "scene-history-lens", duration: 3.96, easing: .easeInOut, keyframes: [
                        .at(0.0, identityTransform: true),
                        .at(0.18, identityTransform: true),
                        .at(0.33, tx: 40, ty: 17),
                        .at(0.51, tx: 40, ty: 17),
                        .at(0.66, tx: -4, ty: 34),
                        .at(0.84, tx: -4, ty: 34),
                        .at(1.0, identityTransform: true),
                    ])
                ),
                children: [
                    .circle(cx: 46, cy: 10.5, r: 7, style: SceneStyle(fill: .surface, fillOpacity: 0.4, stroke: .accent, strokeWidth: 2)),
                    .path(d: "M51 15.5l5 5", style: .lineAccent),
                ]
            ),
        ]
    )

    // MARK: - repo-search
    private static let repoSearchScene = ActivitySceneDefinition(
        kind: .repoSearch,
        nodes: [6.0, 22.0, 38.0].map {
            .rect(x: 20, y: $0, width: 84, height: 12, rx: 2.5, style: .paper)
        } + [
            .rect(
                x: 20, y: 22, width: 84, height: 12, rx: 2.5,
                style: SceneStyle.accent.withOpacity(0.3).withOrigin(.center).withAnimation(
                    storyAnim("scene-rs-hit", [
                        .at(0.0, opacity: 0),
                        .at(0.24, opacity: 0),
                        .at(0.3, opacity: 0.3),
                        .at(0.9, opacity: 0.3),
                        .at(1.0, opacity: 0),
                    ])
                )
            ),
            .path(d: "M27 8.5h5v7h-5z M27 24.5h5v7h-5z M27 40.5h5v7h-5z", style: SceneStyle.lineAccent.withStrokeWidth(1.3).withLineJoin(.round)),
            .path(d: "M38 12H86 M38 28H74 M38 44H80", style: SceneStyle.line.withStrokeWidth(1.5)),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-rs-check", [
                        .at(0.0, scale: 0),
                        .at(0.28, scale: 0),
                        .at(0.33, scale: 1.3),
                        .at(0.36, scale: 1),
                        .at(0.9, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: doneBadge(x: 114, y: 28)
            ),
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-rs-lens", easing: .easeInOut, [
                        .at(0.0, identityTransform: true),
                        .at(0.1, identityTransform: true),
                        .at(0.22, ty: 16),
                        .at(0.58, ty: 16),
                        .at(0.7, ty: 32),
                        .at(0.84, ty: 32),
                        .at(1.0, identityTransform: true),
                    ])
                ),
                children: [
                    .circle(cx: 80, cy: 12, r: 6, style: SceneStyle(fill: .surface, fillOpacity: 0.4, stroke: .accent, strokeWidth: 2)),
                    .path(d: "M84.4 16.4l4.4 4.4", style: .lineAccent),
                ]
            ),
        ]
    )

    // MARK: - repo-attach
    private static let repoAttachScene = ActivitySceneDefinition(
        kind: .repoAttach,
        nodes: [
            .rect(x: 14, y: 12, width: 30, height: 32, rx: 3, style: .paper),
            .rect(x: 22, y: 19, width: 14, height: 17, rx: 1.5, style: SceneStyle(fill: nil, stroke: .accent, strokeWidth: 1.5)),
            .path(d: "M25.5 19v17", style: SceneStyle.lineAccent.withStrokeWidth(1.5)),
            .path(d: "M48 28H80", style: SceneStyle.line.withStrokeWidth(1.5).withDash([2, 3]).withOpacity(0.5)),
        ] + [0.0, 0.35, 0.7].map { wait in
            .rect(
                x: 46, y: 24, width: 6, height: 8, rx: 1.2,
                style: SceneStyle.accent.withOpacity(0).withOrigin(.center).withAnimation(
                    storyAnim("scene-ra-chip", easing: .easeInOut, delay: wait, [
                        .at(0.0, identityTransform: true, opacity: 0),
                        .at(0.04, opacity: 1),
                        .at(0.26, tx: 30, opacity: 1),
                        .at(0.3, tx: 30, opacity: 0),
                        .at(1.0, tx: 30, opacity: 0),
                    ])
                )
            )
        } + [
            .path(d: "M84 14h11l3 4h20v30H84z", style: SceneStyle.paper.withLineJoin(.round)),
        ] + [("M90 27H112", 0.34), ("M90 34H106", 0.40), ("M90 41H110", 0.46)].enumerated().map { i, item in
            .path(
                d: item.0,
                style: SceneStyle.line.withStrokeWidth(1.5).withOrigin(.center).withAnimation(
                    storyAnim("scene-ra-f\(i)", [
                        .at(0.0, tx: -4, opacity: 0),
                        .at(item.1, tx: -4, opacity: 0),
                        .at(item.1 + 0.06, identityTransform: true, opacity: 1),
                        .at(0.9, identityTransform: true, opacity: 1),
                        .at(1.0, opacity: 0),
                    ])
                )
            )
        } + [
            .group(
                style: SceneStyle.none.withOrigin(.center).withAnimation(
                    storyAnim("scene-ra-badge", [
                        .at(0.0, scale: 0),
                        .at(0.56, scale: 0),
                        .at(0.61, scale: 1.3),
                        .at(0.64, scale: 1),
                        .at(0.9, scale: 1),
                        .at(1.0, scale: 0),
                    ])
                ),
                children: doneBadge(x: 118, y: 16)
            ),
        ]
    )

    // MARK: - video-render
    private static let videoRenderScene = ActivitySceneDefinition(
        kind: .videoRender,
        nodes: [.rect(x: 16, y: 3, width: 100, height: 36, rx: 3, style: .paper)]
            + (0..<12).map { i in
                let x = 20.0 + Double(i) * 8.0
                return .group(children: [
                    .rect(x: x, y: 5, width: 4, height: 2.5, rx: 0.6, style: SceneStyle(fill: .borderStrong)),
                    .rect(x: x, y: 34.5, width: 4, height: 2.5, rx: 0.6, style: SceneStyle(fill: .borderStrong)),
                ])
            }
            + [0.9, 0.6, 0.8, 0.5, 0.7, 0.95].enumerated().map { i, o in
                let x = 21.0 + Double(i) * 15.5
                let s = 0.04 + Double(i) * 0.08
                let e = 0.08 + Double(i) * 0.08
                return .group(children: [
                    .rect(x: x, y: 10, width: 13.5, height: 22, rx: 1.5, style: .empty),
                    .rect(
                        x: x, y: 10, width: 13.5, height: 22, rx: 1.5,
                        style: SceneStyle.accent.withOpacity(o).withOrigin(.center).withAnimation(
                            storyAnim("scene-vr-c\(i)", [
                                .at(0.0, sy: 0.3, opacity: 0),
                                .at(s, sy: 0.3, opacity: 0),
                                .at(e, identityTransform: true, opacity: o),
                                .at(0.86, identityTransform: true, opacity: o),
                                .at(0.94, opacity: 0),
                                .at(1.0, opacity: 0),
                            ])
                        )
                    ),
                ])
            }
            + [
                .path(d: "M16 48H116", style: SceneStyle.line.withOpacity(0.3)),
                .path(
                    d: "M16 48H116",
                    style: SceneStyle.lineAccent.withOrigin(.leftCenter).withAnimation(
                        storyAnim("scene-vr-bar", easing: .linear, [
                            .at(0.0, sx: 0),
                            .at(0.04, sx: 0),
                            .at(0.5, sx: 1),
                            .at(0.9, sx: 1),
                            .at(1.0, sx: 1, opacity: 0),
                        ])
                    )
                ),
                .group(
                    style: SceneStyle.none.withOrigin(.center).withAnimation(
                        storyAnim("scene-vr-badge", [
                            .at(0.0, scale: 0),
                            .at(0.54, scale: 0),
                            .at(0.59, scale: 1.3),
                            .at(0.62, scale: 1),
                            .at(0.9, scale: 1),
                            .at(1.0, scale: 0),
                        ])
                    ),
                    children: [
                        .circle(cx: 66, cy: 21, r: 8.5, style: .done),
                        .path(d: "M63.5 16.5v9l7-4.5z", style: SceneStyle(fill: .surface)),
                    ]
                ),
            ]
    )

    // MARK: - audio-render
    private static let audioRenderScene = ActivitySceneDefinition(
        kind: .audioRender,
        nodes: [.rect(x: 16, y: 3, width: 100, height: 36, rx: 3, style: .paper)]
            + [0.35, 0.6, 0.9, 0.5, 0.75, 1.0, 0.55, 0.8, 0.4, 0.65].enumerated().map { i, h in
                let b = i % 5
                let s = 0.04 + Double(b) * 0.1
                let e = 0.10 + Double(b) * 0.1
                let x = 23.0 + Double(i) * 9.0
                let y = 21.0 - h * 14.0
                let height = h * 28.0
                return .group(children: [
                    .rect(x: x, y: y, width: 4.5, height: height, rx: 2, style: .empty),
                    .rect(
                        x: x, y: y, width: 4.5, height: height, rx: 2,
                        style: SceneStyle.accent.withOrigin(.center).withAnimation(
                            storyAnim("scene-au-b\(b)", [
                                .at(0.0, sy: 0.2, opacity: 0),
                                .at(s, sy: 0.2, opacity: 0),
                                .at(e, identityTransform: true, opacity: 1),
                                .at(0.86, identityTransform: true, opacity: 1),
                                .at(0.94, opacity: 0),
                                .at(1.0, opacity: 0),
                            ])
                        )
                    ),
                ])
            }
            + [
                .path(d: "M16 48H116", style: SceneStyle.line.withOpacity(0.3)),
                .path(
                    d: "M16 48H116",
                    style: SceneStyle.lineAccent.withOrigin(.leftCenter).withAnimation(
                        storyAnim("scene-au-bar", easing: .linear, [
                            .at(0.0, sx: 0),
                            .at(0.04, sx: 0),
                            .at(0.54, sx: 1),
                            .at(0.9, sx: 1),
                            .at(1.0, sx: 1, opacity: 0),
                        ])
                    )
                ),
                .group(
                    style: SceneStyle.none.withOrigin(.center).withAnimation(
                        storyAnim("scene-au-badge", [
                            .at(0.0, scale: 0),
                            .at(0.58, scale: 0),
                            .at(0.63, scale: 1.3),
                            .at(0.66, scale: 1),
                            .at(0.9, scale: 1),
                            .at(1.0, scale: 0),
                        ])
                    ),
                    children: [
                        .circle(cx: 104, cy: 12, r: 7.5, style: .done),
                        .path(d: "M101.8 8.5v7l5.6-3.5z", style: SceneStyle(fill: .surface)),
                    ]
                ),
            ]
    )

    // MARK: - finance
    private static let financeScene = ActivitySceneDefinition(
        kind: .finance,
        nodes: [.path(d: "M22 49H102", style: .line)]
            + [16.0, 26.0, 20.0, 34.0].enumerated().map { i, h in
                let op = [0.45, 0.6, 0.75, 1.0][i]
                let s = 0.04 + Double(i) * 0.08
                let e = 0.18 + Double(i) * 0.08
                return .rect(
                    x: 28 + Double(i) * 18, y: 48 - h, width: 12, height: h, rx: 2,
                    style: SceneStyle.accent.withOpacity(op).withOrigin(.centerBottom).withAnimation(
                        storyAnim("scene-fin-b\(i)", [
                            .at(0.0, sy: 0),
                            .at(s, sy: 0),
                            .at(e, sy: 1, opacity: 1),
                            .at(0.88, sy: 1, opacity: 1),
                            .at(1.0, opacity: 0),
                        ])
                    )
                )
            }
            + [
                .path(
                    d: "M34 28L52 18L70 24L88 10",
                    style: SceneStyle.lineDone.withLineJoin(.round).withPathLengthOne().withOrigin(.center).withAnimation(
                        storyAnim("scene-fin-line", easing: .easeInOut, [
                            .at(0.0, opacity: 1, dashOffset: 1),
                            .at(0.4, opacity: 1, dashOffset: 1),
                            .at(0.62, opacity: 1, dashOffset: 0),
                            .at(0.88, opacity: 1, dashOffset: 0),
                            .at(1.0, opacity: 0, dashOffset: 0),
                        ])
                    )
                ),
                .group(
                    style: SceneStyle.none.withOrigin(.center).withAnimation(
                        storyAnim("scene-fin-coin", [
                            .at(0.0, scale: 0),
                            .at(0.64, scale: 0),
                            .at(0.69, scale: 1.3),
                            .at(0.72, scale: 1),
                            .at(0.88, scale: 1),
                            .at(1.0, scale: 0),
                        ])
                    ),
                    children: [
                        .circle(cx: 112, cy: 14, r: 8, style: .warm),
                        .text(x: 112, y: 17.5, string: "$", fontSize: 10, fontWeight: 700, anchor: .middle, fill: .surface),
                    ]
                ),
            ]
    )

    // MARK: - finance-sort
    private static let financeSortScene = ActivitySceneDefinition(
        kind: .financeSort,
        nodes: [8.0, 22.0, 36.0].map { y in
            .group(children: [
                .rect(x: 12, y: y, width: 46, height: 10, rx: 2, style: .paper),
                .path(d: "M16 \(fmt(y + 5))H30", style: SceneStyle.line.withStrokeWidth(1.5)),
            ])
        } + [(SceneColorToken.accent, 72.0), (.stateDone, 92.0), (.stateProgress, 112.0)].map { stroke, x in
            .path(
                d: "M\(fmt(x)) 32v16h16V32",
                style: SceneStyle(fill: nil, stroke: stroke, strokeWidth: 2, lineCap: .round, lineJoin: .round)
            )
        } + [
            (SceneColorToken.accent, 10.0, 33.0, 31.0),
            (.stateDone, 24.0, 53.0, 17.0),
            (.stateProgress, 38.0, 73.0, 3.0),
        ].enumerated().map { i, spec in
            .rect(
                x: 40, y: spec.1, width: 14, height: 6, rx: 1.5,
                style: SceneStyle(
                    fill: spec.0,
                    transformOrigin: .center,
                    animation: storyAnim("scene-fs-chip", easing: .easeInOut, delay: Double(i) * 0.6, [
                        .at(0.0, identityTransform: true, opacity: 1),
                        .at(0.08, identityTransform: true, opacity: 1),
                        .at(0.3, tx: spec.2 * 0.55, ty: -5),
                        .at(0.52, tx: spec.2, ty: spec.3, opacity: 1),
                        .at(0.72, tx: spec.2, ty: spec.3, opacity: 1),
                        .at(0.82, tx: spec.2, ty: spec.3, opacity: 0),
                        .at(1.0, tx: spec.2, ty: spec.3, opacity: 0),
                    ])
                )
            )
        }
    )
}
