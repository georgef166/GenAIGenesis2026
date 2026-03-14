{
  description = "Flutter development shell for the genai app";

  inputs.nixpkgs.url = "nixpkgs";

  outputs = { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          commonPackages = [
            pkgs.flutter
            pkgs.jdk17
          ];
          androidComposition = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [
              "34"
              "35"
              "36"
            ];
            buildToolsVersions = [
              "28.0.3"
              "34.0.0"
              "35.0.0"
              "latest"
            ];
            includeEmulator = true;
            includeSystemImages = true;
            includeNDK = true;
            ndkVersions = [ "28.2.13676358" ];
            includeSources = false;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ "x86_64" ];
            extraLicenses = [
              "android-sdk-preview-license"
              "android-googletv-license"
              "android-sdk-arm-dbt-license"
              "google-gdk-license"
              "intel-android-extra-license"
              "intel-android-sysimage-license"
              "mips-android-sysimage-license"
            ];
          };
          androidSdk = androidComposition.androidsdk;
          platformTools = androidComposition.platform-tools;
        in
        {
          default =
            if pkgs.stdenv.isLinux then
              pkgs.mkShell {
                packages = commonPackages ++ [
                  androidSdk
                  platformTools
                ];

                JAVA_HOME = pkgs.jdk17.home;
                ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
                ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
                ANDROID_NDK_ROOT = "${androidSdk}/libexec/android-sdk/ndk/28.2.13676358";

                shellHook = ''
                  cmake_root=""
                  for dir in "$ANDROID_SDK_ROOT"/cmake/*; do
                    if [ -d "$dir" ]; then
                      cmake_root="$dir"
                      break
                    fi
                  done

                  export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"
                  if [ -n "$cmake_root" ]; then
                    export PATH="$cmake_root/bin:$PATH"
                  fi

                  aapt2_path=""
                  aapt2_candidates=""
                  for candidate in "$ANDROID_SDK_ROOT"/build-tools/*/aapt2; do
                    if [ -x "$candidate" ]; then
                      aapt2_candidates="$aapt2_candidates
$candidate"
                    fi
                  done
                  if [ -n "$aapt2_candidates" ]; then
                    aapt2_path="$(printf '%s\n' "$aapt2_candidates" | sed '/^$/d' | sort -V | tail -n1)"
                  fi

                  if [ -n "$aapt2_path" ]; then
                    export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$aapt2_path''${GRADLE_OPTS:+ $GRADLE_OPTS}"
                  fi

                  {
                    printf 'sdk.dir=%s\n' "$ANDROID_SDK_ROOT"
                    printf 'ndk.dir=%s\n' "$ANDROID_NDK_ROOT"
                    if [ -n "$cmake_root" ]; then
                      printf 'cmake.dir=%s\n' "$cmake_root"
                    fi
                  } > mobile/android/local.properties
                '';
              }
            else
              pkgs.mkShell {
                packages = commonPackages;
              };
        }
      );
    };
}
