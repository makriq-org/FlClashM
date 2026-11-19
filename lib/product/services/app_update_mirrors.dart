import 'package:flutter/foundation.dart';

import '../../providers/providers.dart';
import '../../state.dart';
import 'app_update_manifest.dart';

/// Заголовки подписки, которыми панель указывает зеркало каталога обновлений.
/// Значение — только адрес HTTPS: содержимое зеркала всё равно должно быть
/// подписано ключом FlClashM, поэтому панель не становится источником доверия.
const appUpdateMirrorHeaderStable = 'flclashx-update';
const appUpdateMirrorHeaderPrerelease = 'flclashx-update-pre';

/// Больше двух зеркал (по одному на канал) апдейтер не использует.
const maxAppUpdateMirrorUrlLength = 2048;

const _channelHeaders = {
  AppUpdateChannel.stable: appUpdateMirrorHeaderStable,
  AppUpdateChannel.prerelease: appUpdateMirrorHeaderPrerelease,
};

/// Зеркала активного профиля, снятые в один момент времени.
///
/// [identity] — контекст решения: профиль и его адреса. Ответ, полученный для
/// одного контекста, нельзя применить к другому: если профиль сменился, пока
/// шёл запрос, такой ответ отбрасывается.
@immutable
class AppUpdateMirrorSnapshot {
  const AppUpdateMirrorSnapshot({
    required this.profileId,
    required this.manifests,
  });

  /// Разбирает заголовки подписки; неподходящие значения просто не попадают
  /// в снимок, чтобы одно кривое зеркало не отключало остальные.
  factory AppUpdateMirrorSnapshot.fromHeaders({
    required String profileId,
    required Map<String, String> headers,
  }) {
    final manifests = <AppUpdateChannel, Uri>{};
    for (final MapEntry(key: channel, value: header) in _channelHeaders.entries) {
      final uri = appUpdateMirrorManifestUri(
        _readHeader(headers, header),
        channel: channel,
      );
      if (uri != null) {
        manifests[channel] = uri;
      }
    }
    if (manifests.isEmpty) {
      return empty;
    }
    return AppUpdateMirrorSnapshot(
      profileId: profileId,
      manifests: Map.unmodifiable(manifests),
    );
  }

  static const empty = AppUpdateMirrorSnapshot(
    profileId: '',
    manifests: <AppUpdateChannel, Uri>{},
  );

  final String profileId;
  final Map<AppUpdateChannel, Uri> manifests;

  bool get isEmpty => manifests.isEmpty;

  String get identity {
    final stable = manifests[AppUpdateChannel.stable]?.toString() ?? '';
    final prerelease =
        manifests[AppUpdateChannel.prerelease]?.toString() ?? '';
    return '$profileId\n$stable\n$prerelease';
  }

  bool sameDecisionContextAs(AppUpdateMirrorSnapshot other) =>
      identity == other.identity;

  Uri? manifestFor(AppUpdateChannel channel) => manifests[channel];
}

abstract interface class AppUpdateMirrorSource {
  AppUpdateMirrorSnapshot read();
}

/// Зеркала из заголовков активного профиля. Профиль читается через ту же
/// проекцию, что и остальной UI, без второго источника истины.
class ProfileAppUpdateMirrors implements AppUpdateMirrorSource {
  const ProfileAppUpdateMirrors();

  @override
  AppUpdateMirrorSnapshot read() {
    try {
      final profile = globalState.container.read(currentProfileProvider);
      return AppUpdateMirrorSnapshot.fromHeaders(
        profileId: profile?.id ?? '',
        headers: profile?.providerHeaders ?? const <String, String>{},
      );
    } catch (error) {
      // До готовности контейнера профилей зеркал нет: официальный каталог
      // остаётся доступным.
      return AppUpdateMirrorSnapshot.empty;
    }
  }
}

/// Разбирает значение заголовка в адрес подписанного указателя канала.
///
/// Значение — либо готовый адрес `*.json`, либо каталог, к которому
/// добавляется `<канал>.json`. Всё остальное (http, порт, логин, фрагмент,
/// указатель другого канала) отклоняется.
Uri? appUpdateMirrorManifestUri(
  String? raw, {
  required AppUpdateChannel channel,
}) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty || value.length > maxAppUpdateMirrorUrlLength) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasQuery ||
      !isAppUpdateMirrorUri(uri) ||
      uri.path == '/') {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.isEmpty) {
    return null;
  }
  final last = segments.last;
  if (last.endsWith('.json')) {
    if (last == _channelFileName(_otherChannel(channel))) {
      return null;
    }
    return uri;
  }
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return uri.replace(path: '$path${_channelFileName(channel)}');
}

/// Адрес подписи для указателя: `<url>.sig`, как у официального каталога.
Uri appUpdateSignatureUriOf(Uri manifestUri) {
  final path = '${manifestUri.path}.sig';
  return manifestUri.replace(path: path);
}

/// HTTPS без учётных данных, фрагмента и нестандартного порта.
bool isAppUpdateMirrorUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (!uri.hasPort || uri.port == 443);

String _channelFileName(AppUpdateChannel channel) => '${channel.wireName}.json';

AppUpdateChannel _otherChannel(AppUpdateChannel channel) =>
    channel == AppUpdateChannel.stable
    ? AppUpdateChannel.prerelease
    : AppUpdateChannel.stable;

String? _readHeader(Map<String, String> headers, String name) {
  final direct = headers[name];
  if (direct != null && direct.trim().isNotEmpty) {
    return direct;
  }
  final lower = name.toLowerCase();
  for (final MapEntry(:key, :value) in headers.entries) {
    if (key.toLowerCase() == lower && value.trim().isNotEmpty) {
      return value;
    }
  }
  return null;
}
