# Voxel

This repo contains two pieces:

- `mobile/`: a Flutter AR app that asks Meshy for a text-to-3D model, downloads
  the refined `glb`, and lets you place that model on a horizontal surface
  inside an AR session
- `server/`: a small Dart proxy that keeps the Meshy API key off the phone and
  runs the full Meshy `preview` then `refine` workflow

The repo root owns the Nix shell and `direnv` setup for both parts.

## Prerequisites

- `nix`
- `direnv`
- an AR-capable physical Android or iOS device
- a Meshy API key exported as `MESHY_API_KEY`

On Linux, the flake also provides the Android SDK, NDK, platform tools, command
line tools, and emulator packages.

## Environment

Allow the repo shell once:

```bash
cd /home/yvesd/Codebases/voxel
direnv allow
```

The root `.envrc` will load the Nix dev shell and then source `.envrc.local` if
it exists. A local secret file is ignored by Git.

Example:

```bash
cp .envrc.local.example .envrc.local
$EDITOR .envrc.local
direnv allow
```

## Start The Meshy Proxy

Install the backend dependencies:

```bash
cd /home/yvesd/Codebases/voxel/server
dart pub get
```

Start the proxy:

```bash
cd /home/yvesd/Codebases/voxel/server
dart run bin/server.dart
```

By default it listens on `http://0.0.0.0:8080`. You can override the port with
`PORT`.

The proxy exposes:

- `POST /api/meshy/generate`
- `GET /api/meshy/generate/:jobId`

It keeps jobs in memory only.

## Run The Flutter App

Install the Flutter dependencies:

```bash
cd /home/yvesd/Codebases/voxel/mobile
flutter pub get
```

Run the app on a physical device, pointing it at the proxy on your computer:

```bash
cd /home/yvesd/Codebases/voxel/mobile
flutter run --dart-define=MESHY_PROXY_BASE_URL=http://<LAN-IP>:8080
```

Replace `<LAN-IP>` with the local network address of the machine running the
proxy, for example `192.168.1.10`.

## App Flow

1. Grant camera access when prompted.
2. Enter a text prompt in the bottom panel.
3. Tap `Generate model`.
4. Wait for the proxy to finish the Meshy preview and refine stages.
5. Once the model is ready, move the phone until a horizontal plane is
   detected.
6. Tap once to place the generated model.
7. Tap `Reset placement` to remove the current anchor and place the same model
   again.
8. Generate a new prompt to replace the current model.

The app keeps one active generated model at a time and does not persist it
across restarts.

## Android Notes

- The Nix shell rewrites `mobile/android/local.properties` so Gradle points at
  the Nix-managed Android SDK, NDK, and CMake toolchains.
- Android builds still require an ARCore-capable physical device for real AR
  validation.
- The emulator is useful only for launch and non-AR UI checks.

Build a debug APK:

```bash
cd /home/yvesd/Codebases/voxel/mobile
flutter build apk --debug
```

## Validation

Backend:

```bash
cd /home/yvesd/Codebases/voxel/server
dart test
```

Flutter app:

```bash
cd /home/yvesd/Codebases/voxel/mobile
flutter analyze
flutter test
flutter build apk --debug
```

## Security Note

Do not commit `MESHY_API_KEY` into tracked files. The proxy is the only place
that should read it. If you have already shared a real key in chat or elsewhere,
rotate it before using this setup beyond local development.
