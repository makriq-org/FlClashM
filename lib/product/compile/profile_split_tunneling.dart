import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

typedef ReadProfileSplitTunnelingRemoteSource = Future<String> Function(
  String url,
);

@immutable
class ResolvedProfileSplitTunneling {
  const ResolvedProfileSplitTunneling({
    required this.config,
    required this.accessControl,
  });

  final Map<String, dynamic> config;
  final AccessControl? accessControl;
}

bool requiresInstalledPackageInventoryForProfileSplitTunneling(
  Map<String, dynamic> rawConfig, {
  required bool isAndroid,
}) {
  if (!isAndroid) {
    return false;
  }

  final tun = _asStringKeyedMap(rawConfig['tun']);
  final inlineSelectors = [
    ..._asPackageSelectorList(
      tun['include-package'],
      fieldName: 'tun.include-package',
    ),
    ..._asPackageSelectorList(
      tun['exclude-package'],
      fieldName: 'tun.exclude-package',
    ),
  ];
  if (inlineSelectors.any(_selectorNeedsInstalledPackageAccess)) {
    return true;
  }

  return tun['include-package-file'] != null ||
      tun['exclude-package-file'] != null ||
      tun['include-package-url'] != null ||
      tun['exclude-package-url'] != null;
}

Future<ResolvedProfileSplitTunneling> resolveAndroidProfileSplitTunneling({
  required Map<String, dynamic> rawConfig,
  required bool isAndroid,
  required String profilesPath,
  required String profileId,
  List<String> installedPackageNames = const [],
  ReadProfileSplitTunnelingRemoteSource? readRemoteSource,
  void Function(String diagnostic)? onIgnoredLocalPath,
}) async {
  if (!isAndroid) {
    return ResolvedProfileSplitTunneling(
      config: rawConfig,
      accessControl: null,
    );
  }

  final tun = _asStringKeyedMap(rawConfig['tun']);
  final inlineIncludeSelectors = _asPackageSelectorList(
    tun['include-package'],
    fieldName: 'tun.include-package',
  );
  final inlineExcludeSelectors = _asPackageSelectorList(
    tun['exclude-package'],
    fieldName: 'tun.exclude-package',
  );
  final includePackageFileSources = _asPackageListSources(
    tun['include-package-file'],
    fieldName: 'tun.include-package-file',
  );
  final excludePackageFileSources = _asPackageListSources(
    tun['exclude-package-file'],
    fieldName: 'tun.exclude-package-file',
  );
  final rawIncludePackageUrls = _asPackageListSources(
    tun['include-package-url'],
    fieldName: 'tun.include-package-url',
    preferUrl: true,
  );
  final rawExcludePackageUrls = _asPackageListSources(
    tun['exclude-package-url'],
    fieldName: 'tun.exclude-package-url',
    preferUrl: true,
  );
  final includePackageSources = _remotePackageListSources(
    includePackageFileSources,
    fieldName: 'tun.include-package-file',
    onIgnoredLocalPath: onIgnoredLocalPath,
  );
  final excludePackageSources = _remotePackageListSources(
    excludePackageFileSources,
    fieldName: 'tun.exclude-package-file',
    onIgnoredLocalPath: onIgnoredLocalPath,
  );
  final includePackageUrls = _remotePackageListSources(
    rawIncludePackageUrls,
    fieldName: 'tun.include-package-url',
    onIgnoredLocalPath: onIgnoredLocalPath,
  );
  final excludePackageUrls = _remotePackageListSources(
    rawExcludePackageUrls,
    fieldName: 'tun.exclude-package-url',
    onIgnoredLocalPath: onIgnoredLocalPath,
  );
  final mergedIncludeSources = [
    ...includePackageSources,
    ...includePackageUrls,
  ];
  final mergedExcludeSources = [
    ...excludePackageSources,
    ...excludePackageUrls,
  ];

  if (inlineIncludeSelectors.isEmpty &&
      inlineExcludeSelectors.isEmpty &&
      mergedIncludeSources.isEmpty &&
      mergedExcludeSources.isEmpty) {
    if (includePackageFileSources.any((source) => source.path != null) ||
        excludePackageFileSources.any((source) => source.path != null)) {
      final normalizedTun = Map<String, dynamic>.from(tun)
        ..remove('include-package-file')
        ..remove('exclude-package-file');
      return ResolvedProfileSplitTunneling(
        config: Map<String, dynamic>.from(rawConfig)..['tun'] = normalizedTun,
        accessControl: null,
      );
    }
    return ResolvedProfileSplitTunneling(
      config: rawConfig,
      accessControl: null,
    );
  }

  if ((mergedIncludeSources.isNotEmpty || mergedExcludeSources.isNotEmpty) &&
      profilesPath.trim().isEmpty) {
    throw const FormatException(
      'Android profile split tunneling file lists require a valid profiles path.',
    );
  }

  final normalizedTun = Map<String, dynamic>.from(tun);
  final sourceSelectors = await Future.wait([
    _readPackageLists(
      mergedIncludeSources,
      profilesPath: profilesPath,
      profileId: profileId,
      fieldName: 'tun.include-package-file',
      readRemoteSource: readRemoteSource,
    ),
    _readPackageLists(
      mergedExcludeSources,
      profilesPath: profilesPath,
      profileId: profileId,
      fieldName: 'tun.exclude-package-file',
      readRemoteSource: readRemoteSource,
    ),
  ]);
  final includeSelectorEntries = <_PackageSelectorEntry>[
    ...inlineIncludeSelectors.map(
      (selector) => _PackageSelectorEntry(
        value: selector,
        preserveExactSelectorWithoutInstalledPackages: true,
      ),
    ),
    ...sourceSelectors[0].map(
      (selector) => _PackageSelectorEntry(
        value: selector,
        preserveExactSelectorWithoutInstalledPackages: false,
      ),
    ),
  ];
  final excludeSelectorEntries = <_PackageSelectorEntry>[
    ...inlineExcludeSelectors.map(
      (selector) => _PackageSelectorEntry(
        value: selector,
        preserveExactSelectorWithoutInstalledPackages: true,
      ),
    ),
    ...sourceSelectors[1].map(
      (selector) => _PackageSelectorEntry(
        value: selector,
        preserveExactSelectorWithoutInstalledPackages: false,
      ),
    ),
  ];
  final hasIncludeSelectors = includeSelectorEntries.isNotEmpty;
  final hasExcludeSelectors = excludeSelectorEntries.isNotEmpty;
  if (hasIncludeSelectors && hasExcludeSelectors) {
    throw const FormatException(
      'Android profile split tunneling is ambiguous: use either '
      '`tun.include-package` or `tun.exclude-package`, not both.',
    );
  }

  final includePackages = _resolvePackageSelectors(
    includeSelectorEntries,
    fieldName: 'tun.include-package',
    installedPackageNames: installedPackageNames,
  );
  final excludePackages = _resolvePackageSelectors(
    excludeSelectorEntries,
    fieldName: 'tun.exclude-package',
    installedPackageNames: installedPackageNames,
  );

  if (hasIncludeSelectors) {
    normalizedTun['include-package'] = includePackages;
  } else {
    normalizedTun.remove('include-package');
  }
  if (hasExcludeSelectors) {
    normalizedTun['exclude-package'] = excludePackages;
  } else {
    normalizedTun.remove('exclude-package');
  }
  normalizedTun
    ..remove('include-package-file')
    ..remove('exclude-package-file')
    ..remove('include-package-url')
    ..remove('exclude-package-url');

  final patched = Map<String, dynamic>.from(rawConfig);
  patched['tun'] = normalizedTun;
  return ResolvedProfileSplitTunneling(
    config: patched,
    accessControl: _buildAccessControlOverride(
      hasIncludeSelectors: hasIncludeSelectors,
      hasExcludeSelectors: hasExcludeSelectors,
      includePackages: includePackages,
      excludePackages: excludePackages,
    ),
  );
}

List<_PackageListSource> _remotePackageListSources(
  List<_PackageListSource> sources, {
  required String fieldName,
  void Function(String diagnostic)? onIgnoredLocalPath,
}) {
  var ignoredLocalPath = false;
  final remoteSources = <_PackageListSource>[];
  for (final source in sources) {
    if (source.path != null) {
      ignoredLocalPath = true;
    }
    if (source.url != null) {
      remoteSources.add(_PackageListSource(url: source.url));
    }
  }
  if (ignoredLocalPath) {
    onIgnoredLocalPath?.call(
      'Android ignored unsupported local profile path `$fieldName`.',
    );
  }
  return remoteSources;
}

AccessControl? _buildAccessControlOverride({
  required bool hasIncludeSelectors,
  required bool hasExcludeSelectors,
  required List<String> includePackages,
  required List<String> excludePackages,
}) {
  if (hasIncludeSelectors) {
    return AccessControl(
      enable: true,
      mode: AccessControlMode.acceptSelected,
      acceptList: includePackages,
    );
  }

  if (hasExcludeSelectors) {
    return AccessControl(
      enable: true,
      mode: AccessControlMode.rejectSelected,
      rejectList: excludePackages,
    );
  }

  return null;
}

Map<String, dynamic> _asStringKeyedMap(dynamic value) {
  if (value is! Map) {
    return <String, dynamic>{};
  }
  return value.map((key, mapValue) => MapEntry(key.toString(), mapValue));
}

List<String> _asPackageSelectorList(
  dynamic value, {
  required String fieldName,
}) {
  if (value == null) {
    return const [];
  }
  if (value is String) {
    final normalized = value.trim();
    return normalized.isEmpty ? const [] : [normalized];
  }
  if (value is! List) {
    throw FormatException(
      'Profile field `$fieldName` must be a YAML list of Android package '
      'selectors.',
    );
  }
  final selectors = <String>[];
  for (final item in value) {
    final normalized = item.toString().trim();
    if (normalized.isEmpty) {
      continue;
    }
    selectors.add(normalized);
  }
  return selectors;
}

List<_PackageListSource> _asPackageListSources(
  dynamic value, {
  required String fieldName,
  bool preferUrl = false,
}) {
  if (value == null) {
    return const [];
  }
  if (value is String) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    if (preferUrl && !_isHttpUrl(normalized)) {
      throw FormatException(
        'Profile field `$fieldName` must contain a valid HTTP(S) URL: '
        '$normalized',
      );
    }
    return [
      _PackageListSource(
        url: _isHttpUrl(normalized) || preferUrl ? normalized : null,
        path: _isHttpUrl(normalized) || preferUrl ? null : normalized,
      ),
    ];
  }
  if (value is Map || value is YamlMap) {
    final source = _asPackageListSourceDescriptor(
      value,
      fieldName: fieldName,
      preferUrl: preferUrl,
    );
    return source == null ? const [] : [source];
  }
  if (value is! List) {
    throw FormatException(
      'Profile field `$fieldName` must be a path, a URL, a source map, or '
      'a YAML list of those values.',
    );
  }
  final sources = <_PackageListSource>{};
  for (final item in value) {
    if (item is String) {
      final normalized = item.trim();
      if (normalized.isEmpty) {
        continue;
      }
      if (preferUrl && !_isHttpUrl(normalized)) {
        throw FormatException(
          'Profile field `$fieldName` must contain valid HTTP(S) URLs: '
          '$normalized',
        );
      }
      sources.add(
        _PackageListSource(
          url: _isHttpUrl(normalized) || preferUrl ? normalized : null,
          path: _isHttpUrl(normalized) || preferUrl ? null : normalized,
        ),
      );
      continue;
    }
    final source = _asPackageListSourceDescriptor(
      item,
      fieldName: fieldName,
      preferUrl: preferUrl,
    );
    if (source != null) {
      sources.add(source);
    }
  }
  return sources.toList();
}

_PackageListSource? _asPackageListSourceDescriptor(
  dynamic value, {
  required String fieldName,
  required bool preferUrl,
}) {
  if (value is! Map && value is! YamlMap) {
    throw FormatException(
      'Profile field `$fieldName` accepts only strings or source maps.',
    );
  }
  final normalized = _asStringKeyedMap(value);
  final rawPath = normalized['path']?.toString().trim();
  final rawUrl = normalized['url']?.toString().trim();
  final pathValue = rawPath == null || rawPath.isEmpty ? null : rawPath;
  final urlValue = rawUrl == null || rawUrl.isEmpty ? null : rawUrl;
  if (pathValue == null && urlValue == null) {
    return null;
  }
  if (urlValue != null && !_isHttpUrl(urlValue)) {
    throw FormatException(
      'Profile field `$fieldName` contains an invalid URL source: $urlValue',
    );
  }
  if (preferUrl && urlValue == null) {
    if (pathValue == null || !_isHttpUrl(pathValue)) {
      throw FormatException(
        'Profile field `$fieldName` must contain valid HTTP(S) URLs.',
      );
    }
  }
  if (preferUrl &&
      urlValue == null &&
      pathValue != null &&
      _isHttpUrl(pathValue)) {
    return _PackageListSource(url: pathValue);
  }
  return _PackageListSource(path: pathValue, url: urlValue);
}

Future<List<String>> _readPackageLists(
  List<_PackageListSource> sources, {
  required String profilesPath,
  required String profileId,
  required String fieldName,
  ReadProfileSplitTunnelingRemoteSource? readRemoteSource,
}) async {
  final packages = <String>[];
  Future<List<String>> readSource(_PackageListSource source) async {
    final sourceFieldName =
        source.url != null ? fieldName.replaceAll('-file', '-url') : fieldName;
    final readResult = await _readPackageListFromRemoteSource(
      source,
      profilesPath: profilesPath,
      profileId: profileId,
      fieldName: sourceFieldName,
      readRemoteSource: readRemoteSource,
    );
    final selectors = _parsePackageListFileContent(
      readResult.content,
      fieldName: sourceFieldName,
      path: source.url ?? source.path ?? sourceFieldName,
    );
    _validatePackageSelectors(
      selectors,
      fieldName: sourceFieldName,
    );
    if (!readResult.fromCache && readResult.cachePath != null) {
      await _writePackageListCache(readResult.cachePath!, readResult.content);
    }
    return selectors;
  }

  const maxConcurrentReads = 4;
  for (var offset = 0; offset < sources.length; offset += maxConcurrentReads) {
    final proposedEnd = offset + maxConcurrentReads;
    final end =
        proposedEnd < sources.length ? proposedEnd : sources.length;
    final results = await Future.wait(
      sources.sublist(offset, end).map(readSource),
    );
    results.forEach(packages.addAll);
  }
  return packages;
}

Future<_PackageListReadResult> _readPackageListFromRemoteSource(
  _PackageListSource source, {
  required String profilesPath,
  required String profileId,
  required String fieldName,
  ReadProfileSplitTunnelingRemoteSource? readRemoteSource,
}) async {
  final rawUrl = source.url;
  if (rawUrl == null || rawUrl.isEmpty) {
    throw FormatException(
      'Package list URL for `$fieldName` is missing a valid remote source.',
    );
  }
  final cachePath = _resolvePackageListCachePath(
    source,
    profilesPath: profilesPath,
    profileId: profileId,
    fieldName: fieldName,
  );
  final cacheFile = File(cachePath);
  await cacheFile.parent.create(recursive: true);
  if (cacheFile.existsSync()) {
    _scheduleRemotePackageListRefresh(
      url: rawUrl,
      cachePath: cachePath,
      fieldName: fieldName,
      readRemoteSource: readRemoteSource,
    );
    return _PackageListReadResult(
      content: await cacheFile.readAsString(),
      cachePath: cachePath,
      fromCache: true,
    );
  }
  try {
    final content =
        await (readRemoteSource ?? _defaultReadRemoteSource)(rawUrl);
    return _PackageListReadResult(
      content: content,
      cachePath: cachePath,
    );
  } catch (_) {
    throw FormatException(
      'Package list URL for `$fieldName` could not be fetched and no cache '
      'is available: $rawUrl',
    );
  }
}

final _remotePackageListRefreshes = <String, Future<void>>{};

void _scheduleRemotePackageListRefresh({
  required String url,
  required String cachePath,
  required String fieldName,
  ReadProfileSplitTunnelingRemoteSource? readRemoteSource,
}) {
  if (_remotePackageListRefreshes.containsKey(cachePath)) return;
  late final Future<void> task;
  task = _refreshRemotePackageListCache(
    url: url,
    cachePath: cachePath,
    fieldName: fieldName,
    readRemoteSource: readRemoteSource,
  ).whenComplete(() {
    if (identical(_remotePackageListRefreshes[cachePath], task)) {
      unawaited(_remotePackageListRefreshes.remove(cachePath));
    }
  });
  _remotePackageListRefreshes[cachePath] = task;
  unawaited(task);
}

Future<void> _refreshRemotePackageListCache({
  required String url,
  required String cachePath,
  required String fieldName,
  ReadProfileSplitTunnelingRemoteSource? readRemoteSource,
}) async {
  try {
    final content = await (readRemoteSource ?? _defaultReadRemoteSource)(url);
    final selectors = _parsePackageListFileContent(
      content,
      fieldName: fieldName,
      path: url,
    );
    _validatePackageSelectors(selectors, fieldName: fieldName);
    await _writePackageListCache(cachePath, content);
  } catch (error) {
    commonPrint.log(
      'Android package list background refresh failed for `$url`: $error',
    );
  }
}

Future<String> _defaultReadRemoteSource(String url) async {
  final response = await request.getTextResponseForUrl(url);
  if (response.statusCode != 200) {
    throw DioException.badResponse(
      statusCode: response.statusCode ?? 500,
      requestOptions: response.requestOptions,
      response: response,
    );
  }
  return response.data?.toString() ?? '';
}

String _resolvePackageListCachePath(
  _PackageListSource source, {
  required String profilesPath,
  required String profileId,
  required String fieldName,
}) {
  final rawUrl = source.url;
  if (rawUrl == null || rawUrl.isEmpty) {
    throw FormatException(
      'Package list URL for `$fieldName` is missing a cacheable source.',
    );
  }
  return path.join(
    profilesPath,
    'providers',
    profileId,
    'packages',
    rawUrl.toMd5(),
  );
}

bool _isHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.hasAuthority;
}

List<String> _parsePackageListFileContent(
  String content, {
  required String fieldName,
  required String path,
}) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) {
    return const [];
  }

  try {
    final yamlContent = loadYaml(trimmed);
    if (yamlContent is List || yamlContent is YamlList) {
      return _asPackageSelectorList(
        yamlContent,
        fieldName: '$fieldName ($path)',
      );
    }
  } catch (_) {}

  final selectors = <String>[];
  for (final line in const LineSplitter().convert(content)) {
    var normalized = line.trim();
    if (normalized.isEmpty || normalized.startsWith('#')) {
      continue;
    }
    if (normalized.startsWith('-')) {
      normalized = normalized.substring(1).trim();
    }
    final inlineCommentIndex = normalized.indexOf(' #');
    if (inlineCommentIndex != -1) {
      normalized = normalized.substring(0, inlineCommentIndex).trim();
    }
    if (normalized.isEmpty || normalized.startsWith('#')) {
      continue;
    }
    selectors.add(normalized);
  }
  return selectors;
}

void _validatePackageSelectors(
  List<String> selectors, {
  required String fieldName,
}) {
  for (final selector in selectors) {
    _CompiledPackageSelector.parse(
      selector,
      fieldName: fieldName,
    );
  }
}

Future<void> _writePackageListCache(String cachePath, String content) async {
  final cacheFile = File(cachePath);
  final tempFile = File(
    '$cachePath.${DateTime.now().microsecondsSinceEpoch}.part',
  );
  final cacheDir = cacheFile.parent;
  if (!cacheDir.existsSync()) {
    await cacheDir.create(recursive: true);
  }
  await tempFile.writeAsString(content, flush: true);
  if (cacheFile.existsSync()) {
    await cacheFile.delete();
  }
  await tempFile.rename(cachePath);
}

List<String> _resolvePackageSelectors(
  List<_PackageSelectorEntry> selectors, {
  required String fieldName,
  required List<String> installedPackageNames,
}) {
  if (selectors.isEmpty) {
    return const [];
  }

  final compiledSelectors = selectors
      .map(
        (selector) => _CompiledPackageSelector.parse(
          selector.value,
          fieldName: fieldName,
        ),
      )
      .toList();
  final normalizedInstalledPackages = LinkedHashSet<String>.from(
    installedPackageNames
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty),
  ).toList();

  if (normalizedInstalledPackages.isEmpty) {
    final resolvedPackages = <String>{};
    for (var index = 0; index < compiledSelectors.length; index++) {
      final selector = compiledSelectors[index];
      final selectorEntry = selectors[index];
      if (selector.requiresInstalledPackageScan) {
        commonPrint.log(
          'Android package selector `${selector.raw}` in `$fieldName` was '
          'ignored because no installed applications list is available.',
        );
        continue;
      }
      if (!selectorEntry.preserveExactSelectorWithoutInstalledPackages) {
        commonPrint.log(
          'Android package selector `${selector.raw}` in `$fieldName` was '
          'ignored because it came from an external package list and no '
          'installed applications list is available.',
        );
        continue;
      }
      if (selector.include) {
        resolvedPackages.add(selector.pattern);
      } else {
        resolvedPackages.remove(selector.pattern);
      }
    }
    return resolvedPackages.toList();
  }

  final matchCounters = List<int>.filled(compiledSelectors.length, 0);
  final resolvedPackages = <String>{};
  for (var index = 0; index < compiledSelectors.length; index++) {
    final selector = compiledSelectors[index];
    final matches =
        normalizedInstalledPackages.where(selector.matches).toList();
    matchCounters[index] = matches.length;
    if (matches.isEmpty) {
      continue;
    }
    if (selector.include) {
      resolvedPackages.addAll(matches);
    } else {
      resolvedPackages.removeAll(matches);
    }
  }

  final unmatchedSelectors = <String>[
    for (var index = 0; index < compiledSelectors.length; index++)
      if (matchCounters[index] == 0) compiledSelectors[index].raw,
  ];
  if (unmatchedSelectors.isNotEmpty) {
    final preview = unmatchedSelectors.take(5).join(', ');
    final suffix = unmatchedSelectors.length > 5 ? ', ...' : '';
    commonPrint.log(
      'Android split tunneling `$fieldName` has '
      '${unmatchedSelectors.length} selectors with no installed app matches: '
      '$preview$suffix',
    );
  }

  return resolvedPackages.toList();
}

final class _CompiledPackageSelector {
  const _CompiledPackageSelector({
    required this.raw,
    required this.pattern,
    required this.include,
    required this.matcher,
    required this.requiresInstalledPackageScan,
  });

  factory _CompiledPackageSelector.parse(
    String rawValue, {
    required String fieldName,
  }) {
    final normalized = rawValue.trim();
    final isNegated = normalized.startsWith('!');
    final selectorBody =
        isNegated ? normalized.substring(1).trim() : normalized;
    if (selectorBody.isEmpty) {
      throw FormatException(
        'Profile field `$fieldName` contains an empty Android package '
        'selector: $rawValue',
      );
    }

    final regexBody = _extractRegexBody(selectorBody);
    if (regexBody != null) {
      try {
        final regex = RegExp(regexBody);
        return _CompiledPackageSelector(
          raw: normalized,
          pattern: selectorBody,
          include: !isNegated,
          requiresInstalledPackageScan: true,
          matcher: regex.hasMatch,
        );
      } catch (error) {
        throw FormatException(
          'Profile field `$fieldName` contains an invalid package regular '
          'expression `$selectorBody`: $error',
        );
      }
    }

    if (selectorBody.contains('*')) {
      final glob = RegExp(
        '^${RegExp.escape(selectorBody).replaceAll(r'\*', '.*')}\$',
      );
      return _CompiledPackageSelector(
        raw: normalized,
        pattern: selectorBody,
        include: !isNegated,
        requiresInstalledPackageScan: true,
        matcher: glob.hasMatch,
      );
    }

    return _CompiledPackageSelector(
      raw: normalized,
      pattern: selectorBody,
      include: !isNegated,
      requiresInstalledPackageScan: false,
      matcher: (packageName) => packageName == selectorBody,
    );
  }

  final String raw;
  final String pattern;
  final bool include;
  final bool requiresInstalledPackageScan;
  final bool Function(String packageName) matcher;

  bool matches(String packageName) => matcher(packageName);
}

String? _extractRegexBody(String selector) {
  for (final prefix in const ['re:', 'regex:', 'regexp:']) {
    if (selector.startsWith(prefix)) {
      return selector.substring(prefix.length);
    }
  }
  return null;
}

bool _selectorNeedsInstalledPackageAccess(String rawSelector) {
  final normalized = rawSelector.trim();
  if (normalized.isEmpty) {
    return false;
  }
  final selectorBody =
      normalized.startsWith('!') ? normalized.substring(1).trim() : normalized;
  return selectorBody.contains('*') || _extractRegexBody(selectorBody) != null;
}

class _PackageSelectorEntry {
  const _PackageSelectorEntry({
    required this.value,
    required this.preserveExactSelectorWithoutInstalledPackages,
  });

  final String value;
  final bool preserveExactSelectorWithoutInstalledPackages;
}

class _PackageListSource {
  const _PackageListSource({this.path, this.url});

  final String? path;
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is _PackageListSource && other.path == path && other.url == url;

  @override
  int get hashCode => Object.hash(path, url);
}

class _PackageListReadResult {
  const _PackageListReadResult({
    required this.content,
    this.cachePath,
    this.fromCache = false,
  });

  final String content;
  final String? cachePath;
  final bool fromCache;
}
