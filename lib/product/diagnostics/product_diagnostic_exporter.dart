import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'diagnostic_archive.dart';

final class DiagnosticExportContext {
  const DiagnosticExportContext({
    required this.homeDirectory,
    required this.appVersion,
    required this.buildNumber,
    required this.appTag,
    required this.coreVersion,
    required this.runtime,
  });

  final String homeDirectory;
  final String appVersion;
  final String buildNumber;
  final String appTag;
  final String coreVersion;
  final Map<String, Object?> runtime;
}

abstract interface class DiagnosticPlatformBridge {
  Future<Map<String, Object?>> prepareSnapshot();
}

final class AndroidDiagnosticPlatformBridge
    implements DiagnosticPlatformBridge {
  const AndroidDiagnosticPlatformBridge();

  static const _channel = MethodChannel('com.makriq.flclash/diagnostics');

  @override
  Future<Map<String, Object?>> prepareSnapshot() async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        'prepareSnapshot',
      );
      return value ?? const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }
}

final class ProductDiagnosticExporter {
  const ProductDiagnosticExporter({
    this.platformBridge = const AndroidDiagnosticPlatformBridge(),
    this.archiveBuilder = const DiagnosticArchiveBuilder(),
  });

  final DiagnosticPlatformBridge platformBridge;
  final DiagnosticArchiveBuilder archiveBuilder;

  Future<Uint8List> buildArchive(DiagnosticExportContext context) async {
    final platform = await platformBridge.prepareSnapshot();
    final nativeDirectory = platform['directory'] as String?;
    final directories = <Directory>{
      Directory(path.join(context.homeDirectory, 'diagnostics')),
      Directory(path.join(context.homeDirectory, 'logs')),
      if (nativeDirectory != null && nativeDirectory.isNotEmpty)
        Directory(nativeDirectory),
    };
    final rawAbis = platform['abis'];
    final abis = rawAbis is List
        ? rawAbis.whereType<String>().toList(growable: false)
        : const <String>[];
    return archiveBuilder.build(
      directories: directories,
      manifest: DiagnosticArchiveManifest(
        createdAt: DateTime.now(),
        appVersion: context.appVersion,
        buildNumber: context.buildNumber,
        appTag: context.appTag,
        coreVersion: context.coreVersion,
        androidApi: platform['api'] as int?,
        androidAbis: abis,
        runtime: context.runtime,
        localFlushComplete: platform['localFlushComplete'] as bool?,
        remoteFlushRequested: platform['remoteFlushRequested'] as bool?,
      ),
    );
  }
}

const productDiagnosticExporter = ProductDiagnosticExporter();
