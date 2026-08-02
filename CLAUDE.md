# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout

Two independent Dart packages, a Python service folder, and a Nix flake at the root:

- `mobile/` — Flutter AR app (`package:genai`). Four AR/AI experiences behind one home screen.
- `server/` — Dart `shelf` proxy (`package:genai_server`) that drives the self-hosted text-to-3D backend and streams its assets to the phone.
- `inference/` — the generation service that runs on the A100 box, deployed by `rsync` (`inference/deploy.sh`). Not part of either Dart package; see `inference/README.md`.
- `flake.nix` / `.envrc` — dev shell (Flutter, JDK 17, and on Linux the Android SDK/NDK/CMake). Its `shellHook` **rewrites `mobile/android/local.properties` on every shell entry** — don't hand-edit that file.

`README.md` predates the current app; it documents only the Meshy flow, not the Saturn V, diagram, or LangFlow features.

## Commands

Server:

```bash
cd server
dart pub get
ssh -N -L 8770:127.0.0.1:8770 -L 8771:127.0.0.1:8771 donatoy@142.55.34.202 &
GENAI_BACKEND_URL=http://127.0.0.1:8770 \
GENAI_OBJECT_BACKEND_URL=http://127.0.0.1:8771 \
PORT=8099 dart run bin/server.dart
dart test
dart test test/meshy_proxy_app_test.dart -n 'rejects an empty prompt'   # single test
```

Mobile:

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter test test/widget_test.dart --plain-name 'overlay shows reset action'   # single test
flutter build apk --debug
flutter run \
  --dart-define=MESHY_PROXY_BASE_URL=http://<LAN-IP>:8080 \
  --dart-define=LANGFLOW_APP_TOKEN=<token>
```

`flutter test` only exercises pure-Dart logic and non-AR widgets. Anything touching `ARView` needs a physical ARCore/ARKit device — the emulator is good only for launch and non-AR UI.

## Build-time configuration

All app-side config is `String.fromEnvironment`, i.e. **baked in at compile time**. Changing a value means rebuilding and reinstalling; there is no runtime settings screen.

| Define | Read in | Default |
|---|---|---|
| `MESHY_PROXY_BASE_URL` | `src/meshy_proxy_client.dart` | `http://nixos:8080` (machine-specific — usually wrong) |
| `LANGFLOW_BASE_URL` / `LANGFLOW_FLOW_ID` | `screens/research_screen.dart` | a DataStax-hosted flow |
| `LANGFLOW_APP_TOKEN` (or lowercase `langflow_app_token`) | same | empty → the screen shows a "missing token" error instead of calling out |

`GENAI_BACKEND_URL` is the required world backend (`serve_pano.py`, normally
`http://127.0.0.1:8770`). `GENAI_OBJECT_BACKEND_URL` is the optional
Hunyuan3D-2.1 backend (normally `http://127.0.0.1:8771`); object requests return
503 when it is absent while world requests keep working. Both are server-side
only and must never reach the app: the phone cannot route to them.

## Architecture

### Feature pages

`lib/main.dart` is only a themed home screen that pushes one of four self-contained pages:

- `src/ar_meshy_page.dart` — prompt (+ a photo, for worlds) → proxy → place the generated GLB.
- `src/ar_rocket_page.dart` — Saturn V with a scripted launch sequence (countdown audio, engine flame sprites, cloud layer, timed ascent).
- `src/ar_diagram_page.dart` — Saturn V with floating label cards and pointer lines.
- `screens/research_screen.dart` — LangFlow topic → six kid-friendly facts.

The three AR pages each own a full copy of the same lifecycle, deliberately duplicated rather than shared: camera permission via `permission_handler` → `ARView` callback wires the four plugin managers (`ARSessionManager`, `ARObjectManager`, `ARAnchorManager`, `ARLocationManager`) → plane-detection callback → tap runs a hit test → `ARPlaneAnchor` + `ARNode`. Each drives a page-local `enum` state machine (`ARPlacementState` / `ARSessionState`) that feeds a status overlay widget. Changing placement behaviour in one page does **not** change the others; fix all three when the change is cross-cutting.

The app is **landscape-locked** (`SystemChrome.setPreferredOrientations` in `main()` plus `android:screenOrientation="landscape"` in the manifest). The plugin's camera-orientation patches assume this; see `PATCHES.md` patches 1 and 3. Every AR page's `AppBar` sets `automaticallyImplyLeading: false` because `_TopRightBackShell` in `main.dart` draws its own Back button.

### The two scale traps

**iOS.** The vendored plugin's iOS side multiplies every GLTF child node by 0.01. All three AR pages compensate with `_iosPluginModelScaleCompensation = 100.0` applied only when `Platform.isIOS`. Any new `NodeType.localGLTF2` node needs the same treatment or it will be invisible on iOS and correctly sized on Android.

**Android.** Patch 7 changed the semantics: the plugin now normalizes every model to 1 m at load and applies the full transform matrix, so **a node scale of S means S metres of the model's largest dimension**, identical at spawn and on every update. Upstream instead read `matrix[0]` as `scaleToUnits` and dropped position and rotation entirely. Page constants were retuned for this (`_generatedModelScale = 0.14` → a 14 cm object; the diagram page's rocket is `Vector3.all(1.2)`). iOS is unaffected — it applies the raw matrix.

### Hand gestures

`ar_diagram_page.dart` can drive the placed diagram with hand gestures. ARCore owns the camera exclusively, so detection runs **inside the plugin** on the live AR frame — MediaPipe Hand Landmarker on Android (`tasks-vision`, bundled `hand_landmarker.task`, coordinates mapped through `Frame.transformCoordinates2d`), Apple Vision on iOS 14+. The channel contract is `setHandTracking {enabled} -> bool` and an `onHandGesture` frame at ~15 Hz (`PATCHES.md` patch 6). `src/hand_gesture_interpreter.dart` turns those frames into `GestureCommand`s (a hysteresis state machine, idle → dragging → zooming) and `src/gesture_transform_math.dart` converts a normalized screen delta into an anchor-local one. Both feed `_applyDragDelta` / `_diagramScale` → `_applyDiagramTransform`, which re-derives all 13 sibling node transforms so cards and pointer lines move with the rocket.

**Touch is the fallback and is always live.** A `GestureDetector` (a single scale recognizer covers one-finger drag and two-finger pinch) sits over the AR view once placed and calls the *same* `_applyDragDelta` / `_diagramScale` code, so a device where `setHandTracking` returns false still moves and zooms — a real risk, since the historical MediaPipe protobuf fault (`field platorm_ for s1.D not found`) is unmitigated. A chip at the bottom of the screen names the active mode. Scope is drag + zoom only; all three pages keep `handlePans: false, handleRotation: false`, and **must** — patch 4 warns that `handlePans: true` enables native touch-drag and `isPositionEditable`, which fight the programmatic transforms both input paths rely on.

### Generation pipeline

`phone --LAN--> laptop proxy :8080 --SSH tunnel over VPN--> A100 :8770`.

App (`MeshyProxyClient`) → proxy (`MeshyProxyApp`) → either `TencentHttpApi`
(world) or `Hunyuan3dHttpApi` (object). `POST /api/meshy/generate` takes
`{prompt, kind, imageBase64, steps?}`, returns `202` with a job id, then runs one
task in the background: create → poll → expose `glbUrl`. `steps` is clamped to
10–60 and forwarded only for worlds; the app offers measured presets Fast=12
and Quality=40. The app polls `GET /api/meshy/generate/:jobId` every 3s. Jobs
live in an in-memory `Map` — restarting the proxy loses them. `MeshyApi` is an
interface so tests inject a fake; `MeshyProxyApp.waitForJob` exists for tests to
await the background future.

**Both models require a photo.** HY-Pano outpaints it into a world and uses the
prompt for steering; Hunyuan3D-2.1 turns it into a textured object and uses the
prompt only as the history label. The photo travels as base64 inside the JSON
body rather than multipart — deliberate, because both Dart hops use raw
`dart:io HttpClient`. The proxy caps decoded uploads at **8 MB**, checking
length before decoding; the image is passed into `_runJob` rather than stored
on the process-lifetime `MeshyJob`. `ar_meshy_page.dart` resamples to a 1536 px
long edge at JPEG q85. Camera and gallery are both offered.

Hunyuan3D returns the completed GLB as base64 JSON. `Hunyuan3dHttpApi` validates
the GLB header and declared length, writes it once under the system temp
directory, and stores only its file URI on the job. The existing asset route
streams that file to the phone, so neither the base64 nor decoded bytes stay in
the job map.

Accepting a job — and loading a recent model — collapses the bottom prompt
panel to a `MeshyPromptPill` so it stops covering the AR view; a generation
error re-opens it, success leaves it collapsed because the next act is tapping
a plane. The pill is rendered by the *same* condition that hides the panel and
never from inside it: this page's deleted `_showPlacementUi` flag hid its own
re-open control and left the screen unreachable, which is why placement itself
still hides nothing (`_handlePlaneOrPointTap`).

World placement is not implemented yet: a finished world shows its `panoramaUrl` flat and full-screen with a dismiss button, and nothing is cached or anchored. The inverted sky sphere is the next milestone.

**The phone cannot reach the backend**, so `GET /api/meshy/asset/:jobId/:name` (`model.glb`, `sky.glb`, `panorama.jpg`) opens the upstream URL and returns the `HttpClientResponse` as the shelf body — it is already a `Stream<List<int>>`, so nothing buffers on the laptop. `_getGenerationJob` rewrites every outgoing `glbUrl`/`panoramaUrl` onto that route using `request.requestedUri`, i.e. the Host header the phone actually dialled, so no LAN IP is configured anywhere. A URL handed to the client is **always** a proxy URL.

The `Meshy*` type names are historical and deliberately kept: the two
`MeshyJobStatus` enums (server and client) are hand-mirrored and the client
parses by `.byName`, so renaming a value on one side silently breaks the other.
`MeshyJobStatus.refining` now represents Hunyuan's real `texturing` phase;
`refineTaskId` remains permanently `null` because there is still only one
upstream task.

### Model history

`src/meshy_model_history.dart` streams finished GLBs into the app documents directory with a `history.json` index, capped at 20 entries. Eviction is by `createdAt`, not use — `markUsed` writes `lastUsedAt` but `_sortRecords` never reads it. Placement source selection is platform-dependent: iOS takes the cached `fileSystemAppFolderGLB` with the remote URL as a fallback, Android takes the remote `NodeType.webGLB` URL with the cached file as the fallback (`fallbackAfterPlacementFailure`).

Two things here are load-bearing and easy to undo by accident: the download uses `response.pipe(...)` rather than collecting bytes (buffering cost ~18x the file size in RSS and OOM'd on multi-megabyte payloads), and `cacheCompletedJob` validates the job id against `^[A-Za-z0-9_-]+$` because it comes from proxy JSON and is interpolated into both a filesystem path and an HTTP route.

### LangFlow

`services/langflow_service.dart` tries two URL shapes (`/lf/{flowId}/api/v1/run` then `/api/v1/run/{flowId}`) because hosted and self-hosted deployments differ, unwraps a five-level-deep `outputs[0].outputs[0].results.message.text`, strips markdown code fences from the model output, and parses the inner JSON into `ResearchResult` (`topic` + `fact1`…`fact6`).

### Assets

`mobile/third_party/ar_flutter_plugin_2/` is a vendored fork of pub.dev `ar_flutter_plugin_2` 0.0.3, checked into git and referenced as a path dependency — edits there affect the build directly. Its `PATCHES.md` documents all seven local patches and is the only record of them; read it before touching the plugin or re-syncing upstream. `mobile/analysis_options.yaml` excludes `third_party/**`, so upstream's lint warnings stay out of `flutter analyze`. There is exactly one vendored copy — the older `mobile/plugins/` path is gone.

AR label cards under `assets/models/flashcards/` are pre-baked textured GLTF quads (one per rocket section); there is no runtime text-to-texture rendering. `rocket_parts.dart` holds the educational copy as a `const` list.

Android `minSdk` is 28 and the manifest declares `android.hardware.camera.ar` as required.
