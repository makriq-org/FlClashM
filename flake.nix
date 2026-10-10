{
  description = "FlClashM Android development environment";

  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/6510408d147d8c5e6d76043e899e9251756f6a75";
  inputs.nixpkgsGo.url =
    "github:NixOS/nixpkgs/6510408d147d8c5e6d76043e899e9251756f6a75";

  outputs = { nixpkgs, nixpkgsGo, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };
      goPkgs = import nixpkgsGo { inherit system; };
      android = pkgs.androidenv.composeAndroidPackages {
        platformVersions = [ "34" "35" "36" "37.0" ];
        buildToolsVersions = [ "35.0.0" "36.0.0" "37.0.0" ];
        cmakeVersions = [ "3.22.1" ];
        includeNDK = true;
        # Runtime binaries keep their reproducible NDK pin; Flutter JNI uses 28.2.
        ndkVersions = [ "28.0.13004108" "28.2.13676358" ];
      };
      androidSdk = android.androidsdk;
      sdkRoot = "${androidSdk}/libexec/android-sdk";
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          flutter
          jdk17
          goPkgs.go_1_27
          bash
          git
          android-tools
          gnumake
          cmake
          ninja
          pkg-config
          clang
          curl
          cacert
          unzip
          zip
          xz
          gnused
          gnugrep
          findutils
          coreutils
          which
        ];

        ANDROID_HOME = sdkRoot;
        ANDROID_SDK_ROOT = sdkRoot;
        ANDROID_NDK = "${sdkRoot}/ndk/28.0.13004108";
        JAVA_HOME = "${pkgs.jdk17.home}";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        GRADLE_OPTS =
          "-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkRoot}/build-tools/37.0.0/aapt2";

        shellHook = ''
          if [[ -d android ]]; then
            local_properties=android/local.properties
            touch "$local_properties"

            set_local_property() {
              local key="$1"
              local value="$2"
              if grep -q "^''${key}=" "$local_properties"; then
                sed -i "s|^''${key}=.*|''${key}=''${value}|" "$local_properties"
              else
                printf '%s=%s\n' "$key" "$value" >> "$local_properties"
              fi
            }

            set_local_property sdk.dir "$ANDROID_SDK_ROOT"
            set_local_property flutter.sdk "${pkgs.flutter}"
            unset -f set_local_property
            unset local_properties
          fi
        '';
      };
    };
}
