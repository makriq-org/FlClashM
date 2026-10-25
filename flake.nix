{
  description = "FlClashM Android development environment";

  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/6510408d147d8c5e6d76043e899e9251756f6a75";
  inputs.nixpkgsGo.url =
    "github:NixOS/nixpkgs/6510408d147d8c5e6d76043e899e9251756f6a75";
  inputs.rust-overlay = {
    url = "github:oxalica/rust-overlay/5b9f1198b59bcb31c5c3250b332e7d77590e6306";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nixpkgsGo, rust-overlay, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };
      goPkgs = import nixpkgsGo { inherit system; };
      editorRust = pkgs.rust-bin.stable."1.99.0".minimal.override {
        targets = [
          "aarch64-linux-android"
          "armv7-linux-androideabi"
          "x86_64-linux-android"
        ];
      };
      # Native Assets calls `rustup run 1.99.0 cargo` explicitly. Make that
      # version available declaratively without installing into ~/.rustup.
      editorRustupHome = pkgs.runCommand "flclashm-editor-rustup-home" { } ''
        mkdir -p "$out/toolchains"
        ln -s ${editorRust} "$out/toolchains/1.99.0-x86_64-unknown-linux-gnu"
        cat > "$out/settings.toml" <<'EOF'
        version = "12"
        default_toolchain = "1.99.0-x86_64-unknown-linux-gnu"
        profile = "minimal"
        [overrides]
        EOF
      '';
      # Keep the release toolchain pristine: nixpkgs Go patches net/mime with
      # store paths, changing the Android binaries and their pinned digests.
      olcrtcGo = pkgs.stdenvNoCC.mkDerivation {
        pname = "olcrtc-go-official";
        version = "1.27.3";
        src = pkgs.fetchurl {
          url = "https://dl.google.com/go/go1.27.3.linux-amd64.tar.gz";
          hash = "sha256-Ze+8gP3B+izSYxytW0gXd6aOhyXzTon1D8ascU43m0A=";
        };
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          mkdir -p "$out/share/go" "$out/bin"
          cp -r . "$out/share/go/"
          ln -s "$out/share/go/bin/go" "$out/bin/go"
        '';
      };
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
          editorRust
          rustup
          bash
          git
          patch
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
        FLCLASHM_OLCRTC_GO = "${olcrtcGo}/bin/go";
        JAVA_HOME = "${pkgs.jdk17.home}";
        RUSTUP_HOME = "${editorRustupHome}";
        RUSTUP_TOOLCHAIN = "${editorRust}";
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
