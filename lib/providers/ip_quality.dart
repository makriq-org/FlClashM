import 'dart:async';

import 'package:flclashx/product/backend/backend.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/ip_quality.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/ip_quality.g.dart';

Duration? _noRetry(int retryCount, Object error) => null;

@Riverpod(keepAlive: true)
Duration ipQualityFailureCooldown(Ref ref) => const Duration(minutes: 5);

@Riverpod(retry: _noRetry)
Future<IpQuality> ipQuality(Ref ref, String ip) async {
  try {
    final record = Map<String, dynamic>.from(
      await backendClient.request('ipQuality.get', {
        'ip': ip,
        'refresh': ref.isRefresh,
      }) as Map,
    );
    final data = Map<String, dynamic>.from(record['quality'] as Map);
    final quality = IpQuality(
      ip: data['ip'] as String,
      source: IpQualitySource.values.byName(data['source'] as String),
      type: IpType.values.byName(data['type'] as String),
      organization: data['organization'] as String?,
      asn: data['asn'] as int?,
      isProxy: data['isProxy'] == true,
      isVpn: data['isVpn'] == true,
      isTor: data['isTor'] == true,
      isAbuser: data['isAbuser'] == true,
    );
    if (ref.mounted) {
      final expires = DateTime.parse(record['checkedAt'] as String)
          .add(const Duration(days: 3));
      ref.keepAlive();
      final timer = Timer(
        expires.difference(DateTime.now()),
        ref.invalidateSelf,
      );
      ref.onDispose(timer.cancel);
    }
    return quality;
  } catch (error) {
    if (!ref.mounted) rethrow;
    commonPrint.log(
      'ip quality lookup failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    final link = ref.keepAlive();
    final timer = Timer(ref.read(ipQualityFailureCooldownProvider), link.close);
    ref.onDispose(timer.cancel);
    throw const IpQualityLookupException([
      (source: IpQualitySource.ipInfo, status: IpQualitySourceStatus.failed),
    ]);
  }
}
