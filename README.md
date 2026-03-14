# genai

A Flutter AR demo with a repo-local Nix development shell and `direnv`
support. The app opens directly into an AR scene where you can tap a horizontal
surface to place one anchored dot for the current session.

## Prerequisites

- `nix`
- `direnv`
- `flutter` is provided by the flake shell
- on Linux, the flake also provides the Android SDK and emulator packages
- an AR-capable physical Android or iOS device

## Getting started

1. Allow the project environment:

   ```bash
   direnv allow
   ```

2. Fetch Dart and Flutter dependencies:

   ```bash
   flutter pub get
   ```

3. Confirm the toolchain:

   ```bash
   flutter doctor
   ```

4. Run the app on a physical AR-capable device:

   ```bash
   flutter run
   ```

5. Grant camera access when prompted. The AR session stays blocked until the
   app has camera permission.

You can also enter the shell manually with:

```bash
nix develop
```

## Notes

- The AR scene is powered by `ar_flutter_plugin_2` and a local GLTF dot asset.
- Android development is the expected local path on Linux.
- Android requires `minSdk 28` because the AR renderer uses `sceneview_android`.
- Entering the shell rewrites `android/local.properties` to point Gradle at the
  Nix-managed Android SDK, NDK, and CMake toolchains.
- iOS project files are present, but building or running for iOS still requires
  macOS and Xcode.
- The AR scene supports one dot at a time. Use the in-app reset button to place
  it again.
- If you deny camera permission, the app stays in a blocked state until you
  grant access or open system settings.

## AR usage

1. Move the device slowly until a horizontal surface is detected.
2. Tap the surface to place the dot.
3. Walk around it to confirm that it stays in place.
4. Use the reset button to place it again somewhere else.

## Android builds

Build a debug APK:

```bash
flutter build apk --debug
```

Build a release APK:

```bash
flutter build apk --release
```

## Android emulator

Create a local AVD from the SDK image bundled by the flake:

```bash
avdmanager create avd -n pixel-api-36 -k "system-images;android-36;google_apis;x86_64"
```

Start the emulator:

```bash
emulator -avd pixel-api-36
```

Then verify Flutter can see it:

```bash
flutter devices
```
