import Foundation

/// Registry of all 59 native activity scenes (`56` unique definitions + `3` split aliases),
/// ported 1:1 from `web/app/(app)/chat/_components/activity-scene.tsx` and `web/app/globals.css`.
public enum ActivitySceneCatalog {
    public static let definitions: [ActivitySceneKind: ActivitySceneDefinition] = {
        var map: [ActivitySceneKind: ActivitySceneDefinition] = [:]
        for (k, v) in coreDefinitions { map[k] = v }
        for (k, v) in creationDefinitions { map[k] = v }
        for (k, v) in toolsDefinitions { map[k] = v }
        return map
    }()

    public static func definition(for kind: ActivitySceneKind) -> ActivitySceneDefinition {
        let base = kind.resolvedScene
        return definitions[base] ?? ActivitySceneDefinition(kind: base, nodes: [])
    }

    // MARK: - Shared SVG Geometry Helpers (activity-scene.tsx)

    static func badgeCheck(x: Double, y: Double) -> SceneNode {
        .path(
            d: "M\(fmt(x - 2.4)) \(fmt(y))l1.7 1.7 3.2-3.4",
            style: SceneStyle(
                fill: nil,
                stroke: .surface,
                strokeWidth: 1.6,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    static func doneBadge(x: Double, y: Double) -> [SceneNode] {
        [
            .circle(cx: x, cy: y, r: 5.5, style: .done),
            badgeCheck(x: x, y: y),
        ]
    }

    static func sparklePath(x: Double, y: Double, s: Double) -> String {
        let a = fmt(s * 0.25)
        let b = fmt(s * 0.75)
        let na = fmt(-s * 0.25)
        let nb = fmt(-s * 0.75)
        return "M\(fmt(x)) \(fmt(y - s))l\(a) \(b)l\(b) \(a)l\(nb) \(a)l\(na) \(b)l\(na) \(nb)l\(nb) \(na)l\(b) \(na)z"
    }

    static func folderNodes(x: Double) -> [SceneNode] {
        [
            .rect(x: x + 2, y: 15, width: 12, height: 7, rx: 1.5, style: .paper),
            .rect(x: x, y: 19, width: 30, height: 25, rx: 2.5, style: .paper),
            .path(
                d: "M\(fmt(x + 6)) 28H\(fmt(x + 22)) M\(fmt(x + 6)) 35H\(fmt(x + 16))",
                style: SceneStyle.line.withStrokeWidth(1.5)
            ),
        ]
    }

    static func shelfTile(x: Double, y: Double, thumb: [SceneNode]) -> [SceneNode] {
        [.rect(x: x, y: y, width: 22, height: 19, rx: 2, style: .paper)] + thumb
    }

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.6g", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // MARK: - Shared Animations (globals.css)

    static let sceneLink = MotionAnimation(
        name: "scene-link",
        duration: 4.0,
        easing: .easeInOut,
        fillMode: .both,
        keyframes: [
            .at(0.0, dashOffset: 1),
            .at(0.25, opacity: 1, dashOffset: 0),
            .at(0.8, opacity: 1, dashOffset: 0),
            .at(1.0, opacity: 0, dashOffset: 0),
        ]
    )

    static let sceneNode = MotionAnimation(
        name: "scene-node",
        duration: 2.4,
        easing: .easeInOut,
        keyframes: [
            .at(0.5, scale: 1.25),
        ]
    )

    static let scenePlug = MotionAnimation(
        name: "scene-plug",
        duration: 2.4,
        easing: .easeInOut,
        keyframes: [
            .at(0.0, tx: 0),
            .at(0.5, tx: 14),
            .at(1.0, tx: 0),
        ]
    )

    static let sceneCaret = MotionAnimation(
        name: "scene-caret",
        duration: 0.8,
        easing: .steps(1),
        keyframes: [
            .at(0.5, opacity: 0),
        ]
    )

    static let sceneSpin = MotionAnimation(
        name: "scene-spin",
        duration: 4.0,
        easing: .linear,
        keyframes: [
            .at(1.0, rot: 360),
        ]
    )

    static let sceneSpinReverse = MotionAnimation(
        name: "scene-spin",
        duration: 4.0,
        easing: .linear,
        direction: .reverse,
        keyframes: [
            .at(1.0, rot: 360),
        ]
    )

    static func storyAnim(
        _ name: String,
        easing: MotionEasing = .easeOut,
        delay: Double = 0,
        _ keyframes: [MotionKeyframe]
    ) -> MotionAnimation {
        MotionAnimation(
            name: name,
            duration: 4.8,
            delay: delay,
            easing: easing,
            fillMode: .both,
            keyframes: keyframes
        )
    }
}
