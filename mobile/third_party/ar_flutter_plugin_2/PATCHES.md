# Local patches to `ar_flutter_plugin_2`

Forked from **pub.dev `ar_flutter_plugin_2` 0.0.3** (upstream:
<https://github.com/hlefe/ar_flutter_plugin_2>).

Vendored rather than consumed from pub because the camera-orientation fix below
has to change plugin-internal Kotlin. `examples/`, `docs/`, the architecture
SVGs, and `cloudAnchorSetup.md` were deleted from the copy; nothing else was
removed. `mobile/analysis_options.yaml` excludes `third_party/**`, so upstream's
existing lint warnings do not show up in `flutter analyze`.

## Patch 1 — AR camera feed rendered 90° rotated (the actual cause)

**File:** `lib/widgets/ar_view.dart`, `AndroidARView.build`

Upstream returns a plain `AndroidView`, which puts the platform view in a
Flutter **virtual display**. Device logs confirm this and show the mismatch
directly:

```
I/PlatformViewsController: Hosting view in a virtual display for platform view: 0
android.app.Presentation.show:326            <- ARSceneView lives in a Presentation
MainActivity  ... mDisplayShape={... rotation=1 ...}   <- real display: landscape
VRI[]@357a4b9 ... mDisplayShape={... rotation=0 ...}   <- virtual display: always 0
```

The virtual display always reports rotation 0, while the landscape-locked
activity is rotation 1. ARCore derives the camera's display geometry from the
display the view is attached to, so the feed comes out 90° off — and no amount
of fixing the *context* helps while the view is parented into a virtual display.

The fix switches to **hybrid composition** (`PlatformViewLink` +
`PlatformViewsService.initExpensiveAndroidView`), which attaches the real
`ARSceneView` to the activity's own window hierarchy so it sees the activity's
true rotation. `initExpensiveAndroidView` is the right variant here because
`ARSceneView` is `SurfaceView`-backed.

## Patch 2 — `MissingPluginException` on every AR session start

**File:** `android/.../ArView.kt`, `onObjectMethodCall`

`ARObjectManager.onInitialize()` calls `init` on the `arobjects_<id>` channel,
but the handler had no `"init"` branch, so it fell through to
`result.notImplemented()` and every session start threw:

```
Unhandled Exception: MissingPluginException(No implementation found for method init on channel arobjects_0)
```

Added `"init" -> result.success(null)`.

## Patch 3 — ARSceneView constructed with a non-activity context

**File:** `android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArView.kt`, in `init { }`

```diff
 sceneView = ARSceneView(
-    context = viewContext,
+    context = activity,
     sharedLifecycle = lifecycle,
```

**Why.** SceneView (`io.github.sceneview:arsceneview:2.2.1`) derives the display —
and therefore the camera's display rotation — from the context it is constructed
with. Upstream passes `viewContext`, the plugin's context, even though `ArView`
already receives an `activity` constructor parameter (which it otherwise never
uses). A non-activity context reports the display in the device's *natural*
orientation rather than the activity's, so in an activity locked to landscape
(`AndroidManifest.xml` `android:screenOrientation="landscape"`, which Voxel is)
the camera feed renders 90° off.

The plugin also never calls `Session.setDisplayGeometry(...)` anywhere, so
nothing corrects the geometry afterwards. Combined with `android:configChanges`
including `orientation|screenSize`, the activity never restarts, so there is no
second chance to pick up the right rotation.

With Patch 1 in place the view is now genuinely in the activity's hierarchy, so
passing the activity is also the consistent choice.

**If rotation is still wrong on some device**, the remaining lever is explicit
display geometry: register a `DisplayManager.DisplayListener` in `ArView` and
call `session.setDisplayGeometry(display.rotation, width, height)` from the
frame-update path, using the activity's display and `rootLayout`'s dimensions.
The plugin never calls `setDisplayGeometry` anywhere today.

## Patch 4 — Dart-side node transforms silently dropped on Android

**File:** `android/.../ArView.kt`, `handleTransformNode`

The handler was wrapped in `if (handlePans || handleRotation)`, so with both
flags false (the app's configuration) every `transformationChanged` message —
i.e. every Dart-side `node.transform`/`position`/`scale`/`rotation` setter —
was silently ignored, and the `MethodChannel.Result` was never completed
(leaked). iOS applies `transformationChanged` unconditionally. Removed the
gate (kept as a `run { }` block for minimal diff). Side effect: flashcard
billboard rotation on the diagram page actually works on Android now.

Note the gate must **not** be worked around by passing `handlePans: true` from
the app: that would also set `isPositionEditable = true` on every model node
and enable native touch-drag, which conflicts with programmatic control.

## Patch 5 — `getCameraPose`/`getAnchorPose` incompatible with the Dart API

**File:** `android/.../ArView.kt`, `handleGetCameraPose` / `handleGetAnchorPose`

Both returned a `Map {position, rotation}` while the Dart side
(`ARSessionManager.getCameraPose`/`getPose`) expects a 16-element column-major
matrix list (`MatrixConverter`, matching iOS `serializeMatrix`), so both calls
always threw and returned null on Android. Also `getAnchorPose` only looked at
cloud anchors (`cloudAnchorId`), never the local anchors Dart names.

Fixed by adding `serializePose(Pose)` (via ARCore's column-major
`Pose.toMatrix`), resolving anchors through `anchorNodesMap[name]` first with
the cloud-anchor lookup as fallback, and serving the camera pose from a
`lastCameraPose` cached in the existing `onFrame` block instead of calling
`session.update()` a second time per render tick.

## Patch 6 — Feature: camera-based hand tracking (`setHandTracking` / `onHandGesture`)

**Files:**
- `android/.../HandTracker.kt` (new), `android/.../ArView.kt`,
  `android/build.gradle`, `android/src/main/assets/hand_landmarker.task` (new)
- `ios/Classes/HandTracker.swift` (new), `ios/Classes/IosARView.swift`
- `lib/managers/ar_session_manager.dart`,
  `lib/models/hand_gesture_frame.dart` (new)

The AR session owns the camera exclusively, so app-level hand tracking (e.g.
the `camera` plugin + MLKit) is impossible; detection has to run inside the
plugin on the AR frames. Channel contract on `arsession_<id>`:

- Dart → native: `setHandTracking {enabled: bool} → bool` (false =
  unsupported: iOS < 14 or model load failure). Lazily initializes the
  tracker; disable/dispose releases it.
- Native → Dart while enabled (~15 Hz, empty `hands` still sent each tick):
  `onHandGesture {timestampMs: int, hands: [{pinchRatio, cx, cy, confidence,
  landmarks}]}` where `pinchRatio = dist(thumbTip, indexTip) / dist(wrist,
  middleMCP)` (~0.2 pinched, ~1.0 open), `cx/cy` are the pinch midpoint in
  view-normalized coordinates (0..1, origin top-left) with rotation and
  aspect-fill crop already applied natively, and `landmarks` is all 21 hand
  landmarks (`[[x, y] × 21]`, MediaPipe index order, view-normalized;
  unresolved joints are `[-1, -1]`) for debug overlays.

**Android:** MediaPipe Hand Landmarker (`com.google.mediapipe:tasks-vision:0.10.14`,
LIVE_STREAM mode, 2 hands) on `frame.acquireCameraImage()`; the image→view
affine is captured per frame from `Frame.transformCoordinates2d(IMAGE_NORMALIZED
→ VIEW_NORMALIZED)`, which sidesteps the landscape-rotation issues covered by
Patches 1/3. The bundled `hand_landmarker.task` model (~7.5 MB, float16) came
from the MediaPipe model zoo:
`https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task`

**iOS:** Vision `VNDetectHumanHandPoseRequest` (iOS 14+, gated with
`#available`; `setHandTracking` returns false below that) on
`frame.capturedImage`, mapped through `ARFrame.displayTransform`.

## Patch 7 — node transforms ignored at creation; scale semantics unified

**File:** `android/.../ArView.kt`, `buildModelNode` / `applyTransformationList` /
`handleTransformNode`

Upstream constructed every `ModelNode` with
`scaleToUnits = transformation.first()` — i.e. it read `matrix[0]` (the Dart
scale.x) and normalized the model's **largest dimension to that many meters**,
discarding the node's position and rotation entirely. Consequences: the Saturn
V spawned ~1-3 cm tall on the diagram page, flashcards/pointer lines all sat at
the anchor origin, and the first `transformationChanged` update (which applies
raw matrix scale) would blow a model up to raw-asset units — wildly
inconsistent with its spawn size.

Fix: every model is normalized to 1 m at load (`scaleToUnits = 1.0f`), the
resulting per-node normalization factor is recorded in `nodeUnitScales`, and
`applyTransformationList` applies the full matrix (position, rotation, scale ×
factor) both at build time and from `handleTransformNode`. **Android scale
semantics are now: scale value = rendered size in meters of the model's
largest dimension**, stable across spawn and updates. (iOS is unchanged: raw
matrix applied natively with the plugin's 0.01 GLTF factor.) App-side scale
constants were retuned for this in `ar_diagram_page.dart`; the rocket
(`0.1` → 10 cm) and Meshy (`0.14` → 14 cm) pages keep their previous effective
sizes because for those the old `scaleToUnits` behavior coincided with the new
semantics.

## Re-syncing with upstream

If you take a newer upstream release, re-apply these patches by hand.
Diff against a pristine copy from the pub cache
(`~/.pub-cache/hosted/pub.dev/ar_flutter_plugin_2-<version>/`) to confirm nothing
else has drifted.
