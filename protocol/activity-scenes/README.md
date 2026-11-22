# Activity scene fixtures

Shared parity fixtures for the Mac app's native activity scenes (`macos/Sources/VesperCore/Native/ActivityScene*.swift`),
extracted from the web's source of truth:

- `web/lib/chat-ui.ts` (`ChatStatusKind`, 59 total kinds)
- `web/app/(app)/chat/_components/activity-scene.tsx` (`SCENES`, `SCENE_OF`, `HOLD_MS`, `FADE_MS`, `WIND_DOWN_MS`)
- `web/app/globals.css` (all `.scene-*` animation rules and `@keyframes scene-*`)

Regenerate `fixtures.json` with:

```bash
node web/scripts/activity-scene-fixtures.mjs
```

`ActivitySceneTests` (`make -C macos test`) verifies 100% coverage of every `ChatStatusKind`,
split alias mapping, transition timings, and animation durations/easings/directions/fill modes/keyframe stops.
