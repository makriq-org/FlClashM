// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart';
import 'package:crypto/crypto.dart';

enum Target {
  windows,
  linux,
  android,
  macos,
}

extension TargetExt on Target {
  String get os {
    if (this == Target.macos) {
      return "darwin";
    }
    return name;
  }

  bool get same {
    if (this == Target.android) {
      return true;
    }
    if (Platform.isWindows && this == Target.windows) {
      return true;
    }
    if (Platform.isLinux && this == Target.linux) {
      return true;
    }
    if (Platform.isMacOS && this == Target.macos) {
      return true;
    }
    return false;
  }

  String get dynamicLibExtensionName {
    final String extensionName;
    switch (this) {
      case Target.android || Target.linux:
        extensionName = ".so";
        break;
      case Target.windows:
        extensionName = ".dll";
        break;
      case Target.macos:
        extensionName = ".dylib";
        break;
    }
    return extensionName;
  }

  String get executableExtensionName {
    final String extensionName;
    switch (this) {
      case Target.windows:
        extensionName = ".exe";
        break;
      default:
        extensionName = "";
        break;
    }
    return extensionName;
  }
}

enum Mode { core, lib }

enum Arch { amd64, arm64, arm }

class BuildItem {
  Target target;
  Arch? arch;
  String? archName;

  BuildItem({
    required this.target,
    this.arch,
    this.archName,
  });

  @override
  String toString() =>
      'BuildLibItem{target: $target, arch: $arch, archName: $archName}';
}

class Build {
  static List<BuildItem> get buildItems => [
        BuildItem(
          target: Target.macos,
          arch: Arch.arm64,
        ),
        BuildItem(
          target: Target.macos,
          arch: Arch.amd64,
        ),
        BuildItem(
          target: Target.linux,
          arch: Arch.arm64,
        ),
        BuildItem(
          target: Target.linux,
          arch: Arch.amd64,
        ),
        BuildItem(
          target: Target.windows,
          arch: Arch.amd64,
        ),
        BuildItem(
          target: Target.windows,
          arch: Arch.arm64,
        ),
        BuildItem(
          target: Target.android,
          arch: Arch.arm,
          archName: 'armeabi-v7a',
        ),
        BuildItem(
          target: Target.android,
          arch: Arch.arm64,
          archName: 'arm64-v8a',
        ),
        BuildItem(
          target: Target.android,
          arch: Arch.amd64,
          archName: 'x86_64',
        ),
      ];

  static String get appName => "FlClashX";

  static String get coreName => "FlClashCore";

  static String get libName => "libclash";

  static String get outDir => join(current, libName);

  static String get _coreDir => join(current, "core");

  static String get _servicesDir => join(current, "services", "helper");

  static String get distPath => join(current, "dist");

  static String _getCc(BuildItem buildItem) {
    final environment = Platform.environment;
    if (buildItem.target == Target.android) {
      final ndk = environment["ANDROID_NDK"];
      assert(ndk != null);
      final prebuiltDir =
          Directory(join(ndk!, "toolchains", "llvm", "prebuilt"));
      final prebuiltDirList = prebuiltDir.listSync();
      final map = {
        "armeabi-v7a": "armv7a-linux-androideabi21-clang",
        "arm64-v8a": "aarch64-linux-android21-clang",
        "x86": "i686-linux-android21-clang",
        "x86_64": "x86_64-linux-android21-clang"
      };
      return join(
        prebuiltDirList.first.path,
        "bin",
        map[buildItem.archName],
      );
    }
    return "gcc";
  }

  static String tagsFor(Target target) =>
      target == Target.android ? "with_gvisor,cmfa" : "with_gvisor";

  static Future<void> exec(
    List<String> executable, {
    String? name,
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = true,
  }) async {
    if (name != null) print("run $name");
    final process = await Process.start(
      executable[0],
      executable.sublist(1),
      environment: environment,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
    );
    process.stdout.listen((data) {
      print(utf8.decode(data, allowMalformed: true));
    });
    process.stderr.listen((data) {
      print(utf8.decode(data, allowMalformed: true));
    });
    final exitCode = await process.exitCode;
    if (exitCode != 0 && name != null) throw "$name error";
  }

  static Future<String> calcSha256(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw "File not exists";
    }
    final stream = file.openRead();
    return sha256.convert(await stream.reduce((a, b) => a + b)).toString();
  }

  /// Reads mihomo version from [core/go.mod] (single source of truth).
  static Future<String> extractCoreVersion() async {
    final goMod = File(join("core", "go.mod"));
    if (!await goMod.exists()) {
      throw "core/go.mod file not found";
    }
    final content = await goMod.readAsString();
    final match = RegExp(r'github\.com/metacubex/mihomo\s+(v[\d.]+)').firstMatch(content);
    if (match == null) {
      throw "Could not extract mihomo version from core/go.mod";
    }
    return match.group(1)!;
  }

  /// Writes [lib/core_version.dart] so Flutter can show the same version without dart-define.
  static Future<void> syncCoreVersionDartFile() async {
    final v = await extractCoreVersion();
    final out = File(join(current, "lib", "core_version.dart"));
    await out.writeAsString(
      "// GENERATED by setup.dart from core/constant/version.go — do not edit by hand\n"
      "// ignore_for_file: constant_identifier_names\n"
      "\n"
      "/// Embedded mihomo version (see core/constant/version.go).\n"
      "const String kCoreVersionFromSource = '$v';\n",
    );
  }

  static Future<List<String>> buildCore({
    required Mode mode,
    required Target target,
    required String coreVersion,
    Arch? arch,
  }) async {
    final isLib = mode == Mode.lib;

    final items = buildItems.where(
      (element) =>
          element.target == target &&
          (arch == null ? true : element.arch == arch),
    ).toList();

    final List<String> corePaths = [];

    final targetOutFilePath = join(outDir, target.name);
    final targetOutFile = File(targetOutFilePath);
    if (await targetOutFile.exists()) {
      await targetOutFile.delete(recursive: true);
      await Directory(targetOutFilePath).create(recursive: true);
    }

    for (final item in items) {
      final outFilePath = join(targetOutFilePath, item.archName);
      final file = File(outFilePath);
      if (file.existsSync()) {
        file.deleteSync(recursive: true);
      }

      final fileName = isLib
          ? "$libName${item.target.dynamicLibExtensionName}"
          : "$coreName${item.target.executableExtensionName}";
      final realOutPath = join(outFilePath, fileName);
      corePaths.add(realOutPath);

      final Map<String, String> env = {};
      env["GOOS"] = item.target.os;
      if (item.arch != null) {
        env["GOARCH"] = item.arch!.name;
      }
      if (isLib) {
        env["CGO_ENABLED"] = "1";
        env["CC"] = _getCc(item);
        env["CFLAGS"] = "-O3 -Werror";
      } else {
        env["CGO_ENABLED"] = "0";
      }

      final execLines = [
        "go",
        "build",
        "-ldflags=-w -s -X github.com/metacubex/mihomo/constant.Version=$coreVersion",
        "-tags=${tagsFor(target)}",
        if (isLib) "-buildmode=c-shared",
        "-o",
        realOutPath,
      ];
      await exec(
        execLines,
        name: "build core",
        environment: env,
        workingDirectory: _coreDir,
      );
      if (isLib && item.archName != null) {
        await adjustLibOut(
          targetOutFilePath: targetOutFilePath,
          outFilePath: outFilePath,
          archName: item.archName!,
        );
      }
    }

    return corePaths;
  }

  static Future<void> adjustLibOut({
    required String targetOutFilePath,
    required String outFilePath,
    required String archName,
  }) async {
    final includesPath = join(targetOutFilePath, "includes");
    final realOutPath = join(includesPath, archName);
    await Directory(realOutPath).create(recursive: true);
    final targetOutFiles = Directory(outFilePath).listSync();
    final coreFiles = Directory(_coreDir).listSync();
    for (final file in [...targetOutFiles, ...coreFiles]) {
      if (!file.path.endsWith('.h')) {
        continue;
      }
      final targetFilePath = join(realOutPath, basename(file.path));
      final realFile = File(file.path);
      await realFile.copy(targetFilePath);
      if (coreFiles.contains(file)) {
        continue;
      }
      await realFile.delete();
    }
  }

  static buildHelper(Target target, String token, {Arch? arch}) async {
    final List<String> buildArgs = [
      "cargo",
      "build",
      "--release",
      "--features",
      "windows-service",
    ];
    
    // Add target for cross-compilation
    if (arch == Arch.arm64 && target == Target.windows) {
      buildArgs.addAll(["--target", "aarch64-pc-windows-msvc"]);
    }
    
    await exec(
      buildArgs,
      environment: {
        "TOKEN": token,
      },
      name: "build helper",
      workingDirectory: _servicesDir,
    );
    
    // Determine output path based on architecture
    final String releasePath;
    if (arch == Arch.arm64 && target == Target.windows) {
      releasePath = join(_servicesDir, "target", "aarch64-pc-windows-msvc", "release");
    } else {
      releasePath = join(_servicesDir, "target", "release");
    }
    
    final outPath = join(
      releasePath,
      "helper${target.executableExtensionName}",
    );
    final targetPath = join(
      outDir,
      target.name,
      "FlClashHelperService${target.executableExtensionName}",
    );
    await File(outPath).copy(targetPath);
  }

  static List<String> getExecutable(String command) => command.split(" ");

  static String readVersion() {
    final pubspec = File(join(current, "pubspec.yaml")).readAsStringSync();
    final match = RegExp(r'version:\s*(.+)').firstMatch(pubspec);
    return match?.group(1)?.split('+').first ?? "0.0.0";
  }

  static copyFile(String sourceFilePath, String destinationFilePath) {
    final sourceFile = File(sourceFilePath);
    if (!sourceFile.existsSync()) {
      throw "SourceFilePath not exists";
    }
    final destinationFile = File(destinationFilePath);
    final destinationDirectory = destinationFile.parent;
    if (!destinationDirectory.existsSync()) {
      destinationDirectory.createSync(recursive: true);
    }
    try {
      sourceFile.copySync(destinationFilePath);
      print("File copied successfully!");
    } catch (e) {
      print("Failed to copy file: $e");
    }
  }
}

class BuildCommand extends Command {
  Target target;

  BuildCommand({
    required this.target,
  }) {
    if (target == Target.android || target == Target.linux) {
      argParser.addOption(
        "arch",
        valueHelp: arches.map((e) => e.name).join(','),
        help: 'The $name build desc',
      );
    } else {
      argParser.addOption(
        "arch",
        help: 'The $name build archName',
      );
    }
    argParser.addOption(
      "out",
      valueHelp: [
        if (target.same) "app",
        "core",
      ].join(','),
      help: 'The $name build arch',
    );
    argParser.addOption(
      "env",
      valueHelp: [
        "pre",
        "stable",
      ].join(','),
      help: 'The $name build env',
    );
    if (target == Target.windows) {
      argParser.addFlag(
        "msix",
        help: "Build MSIX package for Microsoft Store",
        defaultsTo: false,
      );
    }
  }

  @override
  String get description => "build $name application";

  @override
  String get name => target.name;

  List<Arch> get arches => Build.buildItems
      .where((element) => element.target == target && element.arch != null)
      .map((e) => e.arch!)
      .toList();

  _getLinuxDependencies(Arch arch) async {
    await Build.exec(
      Build.getExecutable("sudo apt update -y"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y ninja-build libgtk-3-dev"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y libayatana-appindicator3-dev"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt-get install -y libkeybinder-3.0-dev"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y locate"),
    );
    if (arch == Arch.amd64) {
      await Build.exec(
        Build.getExecutable("sudo apt install -y rpm patchelf"),
      );
      await Build.exec(
        Build.getExecutable("sudo apt install -y libfuse2"),
      );

      final downloadName = arch == Arch.amd64 ? "x86_64" : "aarch64";
      await Build.exec(
        Build.getExecutable(
          "wget -O appimagetool https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$downloadName.AppImage",
        ),
      );
      await Build.exec(
        Build.getExecutable(
          "chmod +x appimagetool",
        ),
      );
      await Build.exec(
        Build.getExecutable(
          "sudo mv appimagetool /usr/local/bin/",
        ),
      );
    }
  }

  _getMacosDependencies() async {
    await Build.exec(
      Build.getExecutable("npm install -g create-dmg"),
    );
  }

  _buildMacosApp({
    required Arch arch,
    required String env,
    required String coreVersion,
  }) async {
    await Build.exec(
      name: "flutter build macos",
      [
        "flutter",
        "build",
        "macos",
        "--release",
        "--dart-define=APP_ENV=$env",
        "--dart-define=CORE_VERSION=$coreVersion",
      ],
    );

    final pubspecFile = File(join(current, "pubspec.yaml"));
    final pubspecContent = pubspecFile.readAsStringSync();
    final versionMatch = RegExp(r'version:\s*(.+)').firstMatch(pubspecContent);
    final version = versionMatch?.group(1)?.split('+').first ?? "0.0.0";

    final appName = Build.appName;
    final appPath = join(current, "build", "macos", "Build", "Products",
        "Release", "$appName.app");

    final distDir = Directory(Build.distPath);
    if (!distDir.existsSync()) {
      distDir.createSync(recursive: true);
    }

    print("Creating DMG with create-dmg...");

    await Build.exec(
      name: "create-dmg",
      [
        "create-dmg",
        "--overwrite",
        "--dmg-title",
        appName,
        appPath,
        Build.distPath,
      ],
    );

    final createdDmgName = "$appName $version.dmg";
    final createdDmgPath = join(Build.distPath, createdDmgName);
    final targetDmgName = "$appName-macos-${arch.name}.dmg";
    final targetDmgPath = join(Build.distPath, targetDmgName);

    final createdDmg = File(createdDmgPath);
    if (createdDmg.existsSync()) {
      final targetDmg = File(targetDmgPath);
      if (targetDmg.existsSync()) {
        targetDmg.deleteSync();
      }

      createdDmg.renameSync(targetDmgPath);
      print("✅ DMG created: $targetDmgPath");
    } else {
      throw "DMG file not created: $createdDmgPath";
    }
  }

  _buildWindowsApp({
    required Arch arch,
    required String env,
    required String coreVersion,
    required String token,
    bool msix = false,
  }) async {
    await Build.exec(
      name: "flutter build windows",
      [
        "flutter", "build", "windows", "--release",
        "--dart-define=APP_ENV=$env",
        "--dart-define=CORE_SHA256=$token",
        "--dart-define=CORE_VERSION=$coreVersion",
      ],
    );

    final winArch = arch == Arch.arm64 ? "arm64" : "x64";
    final buildDir = join(current, "build", "windows", winArch, "runner", "Release");

    final version = Build.readVersion();
    final distDir = Directory(Build.distPath);
    if (!distDir.existsSync()) distDir.createSync(recursive: true);

    final archName = arch.name;
    final zipName = "${Build.appName}-windows-$archName.zip";
    final zipPath = join(Build.distPath, zipName);
    await Build.exec(
      name: "create zip",
      ["powershell", "Compress-Archive", "-Path", "$buildDir\\*", "-DestinationPath", zipPath, "-Force"],
    );
    print("✅ ZIP created: $zipPath");

    final issTemplate = File(join(current, "windows", "packaging", "exe", "inno_setup.iss"));
    if (issTemplate.existsSync()) {
      final issContent = issTemplate.readAsStringSync()
          .replaceAll("{{APP_ID}}", "728B3532-C74B-4870-9068-BE70FE12A3E6")
          .replaceAll("{{APP_VERSION}}", version)
          .replaceAll("{{DISPLAY_NAME}}", Build.appName)
          .replaceAll("{{PUBLISHER_NAME}}", "pluralplay")
          .replaceAll("{{PUBLISHER_URL}}", "https://github.com/pluralplay/FlClashX")
          .replaceAll("{{INSTALL_DIR_NAME}}", "{autopf}\\${Build.appName}")
          .replaceAll("{{OUTPUT_BASE_FILENAME}}", "${Build.appName}-windows-$archName-setup")
          .replaceAll("{{SETUP_ICON_FILE}}", join(current, "windows", "runner", "resources", "app_icon.ico"))
          .replaceAll("{{PRIVILEGES_REQUIRED}}", "admin")
          .replaceAll("{{ARCH}}", archName == "amd64" ? "x64compatible" : "arm64")
          .replaceAll("{{SOURCE_DIR}}", buildDir)
          .replaceAll("{{EXECUTABLE_NAME}}", "${Build.appName}.exe");

      var processed = issContent;
      final locales = [
        {"lang": "ru"},
        {"lang": "en"},
      ];
      final langLines = <String>[];
      for (final locale in locales) {
        final lang = locale["lang"]!;
        if (lang == "en") langLines.add('Name: "english"; MessagesFile: "compiler:Default.isl"');
        if (lang == "ru") langLines.add('Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"');
      }
      processed = processed.replaceAll(
        RegExp(r'\{% for locale in LOCALES %\}.*?\{% endfor %\}', dotAll: true),
        langLines.join('\n'),
      );
      processed = processed.replaceAllMapped(
        RegExp(r"\{%\s*if\s+PRIVILEGES_REQUIRED\s*==\s*'admin'\s*%\}(.*?)\{%\s*endif\s*%\}", dotAll: true),
        (m) => m.group(1)!,
      );

      final issOut = File(join(Build.distPath, "setup.iss"));
      issOut.writeAsStringSync(processed);
      await Build.exec(
        name: "inno setup",
        [r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe", issOut.path],
      );
      issOut.deleteSync();
      print("✅ EXE installer created");
    }

    if (msix) {
      await Build.exec(
        name: "create msix",
        ["dart", "run", "msix:create"],
      );
      final winArch2 = arch == Arch.arm64 ? "arm64" : "x64";
      final msixDir = join(current, "build", "windows", winArch2, "runner", "Release");
      final msixFiles = Directory(msixDir).listSync().where((f) => f.path.endsWith(".msix"));
      if (msixFiles.isNotEmpty) {
        final msixOutPath = join(Build.distPath, "${Build.appName}-windows-${arch.name}.msix");
        Build.copyFile(msixFiles.first.path, msixOutPath);
        print("✅ MSIX created: $msixOutPath");
      }
    }
  }

  _buildLinuxApp({
    required Arch arch,
    required String env,
    required String coreVersion,
  }) async {
    final targetMap = {
      Arch.arm64: "linux-arm64",
      Arch.amd64: "linux-x64",
    };
    await Build.exec(
      name: "flutter build linux",
      [
        "flutter", "build", "linux", "--release",
        "--target-platform=${targetMap[arch]}",
        "--dart-define=APP_ENV=$env",
        "--dart-define=CORE_VERSION=$coreVersion",
      ],
    );

    final version = Build.readVersion();
    final appName = Build.appName;
    final archName = arch.name;
    final bundleDir = join(current, "build", "linux", targetMap[arch]!.replaceAll("linux-", ""), "release", "bundle");
    final distDir = Directory(Build.distPath);
    if (!distDir.existsSync()) distDir.createSync(recursive: true);

    final iconPath = join(current, "assets", "images", "icon.png");
    final debArch = arch == Arch.amd64 ? "amd64" : "arm64";
    final rpmArch = arch == Arch.amd64 ? "x86_64" : "aarch64";

    // --- DEB ---
    final debRoot = join(current, "build", "deb_root");
    final debInstallDir = join(debRoot, "opt", appName);
    final debDesktopDir = join(debRoot, "usr", "share", "applications");
    final debIconDir = join(debRoot, "usr", "share", "icons", "hicolor", "256x256", "apps");
    final debControlDir = join(debRoot, "DEBIAN");

    for (final d in [debInstallDir, debDesktopDir, debIconDir, debControlDir]) {
      await Directory(d).create(recursive: true);
    }
    await Build.exec(["cp", "-r", "$bundleDir/.", debInstallDir]);
    File(join(debIconDir, "$appName.png")).writeAsBytesSync(File(iconPath).readAsBytesSync());
    File(join(debDesktopDir, "com.follow.clashx.desktop")).writeAsStringSync(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=$appName\n"
      "GenericName=$appName\n"
      "Comment=$appName\n"
      "Exec=/opt/$appName/$appName\n"
      "Icon=$appName\n"
      "Terminal=false\n"
      "Categories=Network;\n"
      "Keywords=FlClashX;Clash;Proxy;\n"
      "StartupNotify=true\n",
    );
    File(join(debControlDir, "control")).writeAsStringSync(
      "Package: flclashx\n"
      "Version: $version\n"
      "Section: x11\n"
      "Priority: optional\n"
      "Architecture: $debArch\n"
      "Depends: libayatana-appindicator3-dev, libkeybinder-3.0-dev\n"
      "Maintainer: pluralplay <mail@pluralplay.rw>\n"
      "Description: $appName\n",
    );
    final debPath = join(Build.distPath, "$appName-linux-$archName.deb");
    await Build.exec(name: "build deb", ["dpkg-deb", "--build", debRoot, debPath]);
    await Directory(debRoot).delete(recursive: true);
    print("✅ DEB created: $debPath");

    // --- RPM (amd64 only) ---
    if (arch == Arch.amd64) {
      final rpmBuildRoot = join(current, "build", "rpm_root");
      final rpmInstallDir = join(rpmBuildRoot, "opt", appName);
      final rpmDesktopDir = join(rpmBuildRoot, "usr", "share", "applications");
      final rpmIconDir = join(rpmBuildRoot, "usr", "share", "icons", "hicolor", "256x256", "apps");
      for (final d in [rpmInstallDir, rpmDesktopDir, rpmIconDir]) {
        await Directory(d).create(recursive: true);
      }
      await Build.exec(["cp", "-r", "$bundleDir/.", rpmInstallDir]);
      File(join(rpmIconDir, "$appName.png")).writeAsBytesSync(File(iconPath).readAsBytesSync());
      File(join(rpmDesktopDir, "com.follow.clashx.desktop")).writeAsStringSync(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=$appName\n"
        "GenericName=$appName\n"
        "Comment=$appName\n"
        "Exec=/opt/$appName/$appName\n"
        "Icon=$appName\n"
        "Terminal=false\n"
        "Categories=Network;\n"
        "Keywords=FlClashX;Clash;Proxy;\n"
        "StartupNotify=true\n",
      );

      final specPath = join(current, "build", "$appName.spec");
      File(specPath).writeAsStringSync(
        "Name: flclashx\n"
        "Version: $version\n"
        "Release: 1\n"
        "Summary: $appName\n"
        "License: Other\n"
        "Group: Applications/Internet\n"
        "Packager: pluralplay <mail@pluralplay.rw>\n"
        "AutoReqProv: no\n"
        "\n"
        "%description\n"
        "$appName proxy client\n"
        "\n"
        "%install\n"
        "cp -r %{_builddir}/root/* %{buildroot}/\n"
        "\n"
        "%files\n"
        "/opt/$appName/*\n"
        "/usr/share/applications/com.follow.clashx.desktop\n"
        "/usr/share/icons/hicolor/256x256/apps/$appName.png\n",
      );

      final rpmBuildDir = join(current, "build", "rpmbuild");
      await Directory(join(rpmBuildDir, "BUILD", "root")).create(recursive: true);
      await Build.exec(["cp", "-r", "$rpmBuildRoot/.", join(rpmBuildDir, "BUILD", "root")]);
      await Build.exec(name: "build rpm", [
        "rpmbuild", "-bb", specPath,
        "--define", "_topdir $rpmBuildDir",
        "--define", "_builddir ${join(rpmBuildDir, "BUILD")}",
        "--target", rpmArch,
      ]);

      final rpmOutputDir = join(rpmBuildDir, "RPMS", rpmArch);
      final rpmFiles = Directory(rpmOutputDir).listSync().where((f) => f.path.endsWith(".rpm"));
      if (rpmFiles.isNotEmpty) {
        final rpmOutPath = join(Build.distPath, "$appName-linux-$archName.rpm");
        Build.copyFile(rpmFiles.first.path, rpmOutPath);
        print("✅ RPM created: $rpmOutPath");
      }
      await Directory(rpmBuildRoot).delete(recursive: true);
      await Directory(rpmBuildDir).delete(recursive: true);
      File(specPath).deleteSync();
    }

    // --- AppImage (amd64 only) ---
    if (arch == Arch.amd64) {
      final appDir = join(current, "build", "AppDir");
      final appBinDir = join(appDir, "usr", "bin");
      final appLibDir = join(appDir, "usr", "lib");
      final appShareDesktop = join(appDir, "usr", "share", "applications");
      final appShareIcon = join(appDir, "usr", "share", "icons", "hicolor", "256x256", "apps");
      for (final d in [appBinDir, appLibDir, appShareDesktop, appShareIcon]) {
        await Directory(d).create(recursive: true);
      }

      final bundleFiles = Directory(bundleDir).listSync();
      for (final f in bundleFiles) {
        final name = basename(f.path);
        if (name == "lib") {
          await Build.exec(["cp", "-r", f.path, appDir + "/usr/"]);
        } else if (f is File) {
          Build.copyFile(f.path, join(appBinDir, name));
        } else {
          await Build.exec(["cp", "-r", f.path, join(appBinDir, name)]);
        }
      }

      File(join(appShareIcon, "$appName.png")).writeAsBytesSync(File(iconPath).readAsBytesSync());
      Build.copyFile(iconPath, join(appDir, "$appName.png"));
      File(join(appShareDesktop, "com.follow.clashx.desktop")).writeAsStringSync(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=$appName\n"
        "GenericName=$appName\n"
        "Comment=$appName\n"
        "Exec=$appName\n"
        "Icon=$appName\n"
        "Terminal=false\n"
        "Categories=Network;\n"
        "Keywords=FlClashX;Clash;Proxy;\n"
        "StartupNotify=true\n",
      );
      Build.copyFile(join(appShareDesktop, "com.follow.clashx.desktop"), join(appDir, "com.follow.clashx.desktop"));
      File(join(appDir, "AppRun")).writeAsStringSync(
        "#!/bin/bash\n"
        'SELF=\$(readlink -f "\$0")\n'
        'HERE=\${SELF%/*}\n'
        'export PATH="\${HERE}/usr/bin:\${PATH}"\n'
        'export LD_LIBRARY_PATH="\${HERE}/usr/lib:\${LD_LIBRARY_PATH}"\n'
        'exec "\${HERE}/usr/bin/$appName" "\$@"\n',
      );
      await Build.exec(["chmod", "+x", join(appDir, "AppRun")]);
      await Build.exec(["chmod", "+x", join(appBinDir, appName)]);

      final appImagePath = join(Build.distPath, "$appName-linux-$archName.AppImage");
      await Build.exec(
        name: "build AppImage",
        ["appimagetool", appDir, appImagePath],
        environment: {"ARCH": "x86_64"},
      );
      await Directory(appDir).delete(recursive: true);
      print("✅ AppImage created: $appImagePath");
    }
  }

  _buildAndroidApp({
    required String env,
    required String coreVersion,
  }) async {
    final distDir = Directory(Build.distPath);
    if (!distDir.existsSync()) distDir.createSync(recursive: true);

    await Build.exec(
      name: "flutter build apk (split)",
      [
        "flutter", "build", "apk", "--release",
        "--split-per-abi",
        "--dart-define=APP_ENV=$env",
        "--dart-define=CORE_VERSION=$coreVersion",
      ],
    );

    final splitDir = join(current, "build", "app", "outputs", "flutter-apk");
    final archMap = {
      "app-arm64-v8a-release.apk": "${Build.appName}-android-arm64-v8a.apk",
      "app-armeabi-v7a-release.apk": "${Build.appName}-android-armeabi-v7a.apk",
      "app-x86_64-release.apk": "${Build.appName}-android-x86_64.apk",
    };
    for (final f in Directory(splitDir).listSync()) {
      final name = basename(f.path);
      if (archMap.containsKey(name)) {
        Build.copyFile(f.path, join(Build.distPath, archMap[name]!));
      }
    }

    await Build.exec(
      name: "flutter build apk (universal)",
      [
        "flutter", "build", "apk", "--release",
        "--dart-define=APP_ENV=$env",
        "--dart-define=CORE_VERSION=$coreVersion",
      ],
    );
    Build.copyFile(
      join(splitDir, "app-release.apk"),
      join(Build.distPath, "${Build.appName}-android-universal.apk"),
    );
    print("✅ APKs created in ${Build.distPath}");
  }

  Future<String?> get systemArch async {
    if (Platform.isWindows) {
      return Platform.environment["PROCESSOR_ARCHITECTURE"];
    } else if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('uname', ['-m']);
      return result.stdout.toString().trim();
    }
    return null;
  }

  @override
  Future<void> run() async {
    final mode = target == Target.android ? Mode.lib : Mode.core;
    final String out = argResults?["out"] ?? (target.same ? "app" : "core");
    final archName = argResults?["arch"];
    final env = argResults?["env"] ?? "pre";
    final currentArches =
        arches.where((element) => element.name == archName).toList();
    final arch = currentArches.isEmpty ? null : currentArches.first;

    if (arch == null && target != Target.android) {
      throw "Invalid arch parameter";
    }

    await Build.syncCoreVersionDartFile();
    final coreVersion = await Build.extractCoreVersion();

    final corePaths = await Build.buildCore(
      target: target,
      arch: arch,
      mode: mode,
      coreVersion: coreVersion,
    );

    if (out != "app") {
      return;
    }

    switch (target) {
      case Target.windows:
        final token = await Build.calcSha256(corePaths.first);
        final buildMsix = argResults?["msix"] == true;
        await Build.buildHelper(target, token, arch: arch);
        await _buildWindowsApp(
          arch: arch!,
          env: env,
          coreVersion: coreVersion,
          token: token,
          msix: buildMsix,
        );
        return;
      case Target.linux:
        await _getLinuxDependencies(arch!);
        await _buildLinuxApp(
          arch: arch!,
          env: env,
          coreVersion: coreVersion,
        );
        return;
      case Target.android:
        await _buildAndroidApp(
          env: env,
          coreVersion: coreVersion,
        );
        return;
      case Target.macos:
        await _getMacosDependencies();
        await _buildMacosApp(
          arch: arch!,
          env: env,
          coreVersion: coreVersion,
        );
        return;
    }
  }
}

main(args) async {
  final runner = CommandRunner("setup", "build Application");
  runner.addCommand(BuildCommand(target: Target.android));
  runner.addCommand(BuildCommand(target: Target.linux));
  runner.addCommand(BuildCommand(target: Target.windows));
  runner.addCommand(BuildCommand(target: Target.macos));
  runner.run(args);
}
