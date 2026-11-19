import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'graph.dart';

/// The outbounds the profile build starts from, with the script already run.
final proxyChainGraphProvider = FutureProvider.autoDispose
    .family<ProxyChainGraph?, String>((ref, profileId) async {
      final source = ref.watch(
        profileProvider(profileId).select(
          (profile) => (
            type: profile?.type,
            extendType: profile?.extendType,
            scriptId: profile?.scriptId,
          ),
        ),
      );
      if (source.type == null || source.type == ProfileType.custom) {
        return null;
      }
      var raw = await ref.read(coreHandlerProvider).getConfig(profileId);
      if (source.extendType == ExtendType.script) {
        final script = ref.watch(
          scriptsProvider.select(
            (state) => (state.value ?? const <Script>[]).get(source.scriptId),
          ),
        );
        if (script != null && script.source.isNotEmpty) {
          raw = await handleEvaluate(script.source, raw);
        }
      }
      return compute(ProxyChainGraph.fromRaw, raw);
    });
