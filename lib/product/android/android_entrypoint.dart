import 'dart:async';
import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/plugins/app.dart';
import 'package:flclashx/plugins/tile.dart';
import 'package:flclashx/plugins/vpn.dart';
import 'package:flclashx/state.dart';

import '../../clash/core.dart';
import '../../clash/lib.dart';
import '../../common/common.dart';
import '../../models/core.dart' as core_models show Action;
import '../../models/models.dart';

class AndroidEntrypoint {
  AndroidEntrypoint._();

  static final AndroidEntrypoint instance = AndroidEntrypoint._();

  Future<void> init() async {
    // Accessing the singletons wires up method channel handlers.
    vpn;
    tile?.addListener(_MainTileListener(this));
    // Let the Kotlin side replay pending START/STOP/CHANGE intents after the
    // Flutter engine is ready.
    unawaited(tile?.signalServiceReady());
  }

  Future<void> handleStart() async {
    try {
      unawaited(app?.tip(appLocalizations.startVpn));

      final profileId = globalState.config.currentProfileId;
      if (profileId == null) {
        unawaited(app?.tip("No profile selected"));
        return;
      }

      for (var i = 0; i < 30; i++) {
        if (await clashCore.isInit) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final profile = globalState.config.currentProfile;
      final title = buildNotificationTitle(profile);
      unawaited(clashLib?.updateNotificationParams(title: title));

      final rt = await clashLib?.startVpn() ?? 0;
      if (rt == 0) {
        commonPrint.log("Tile start: startVpn returned 0");
        unawaited(app?.tip("VPN start failed"));
        return;
      }

      await clashCore.startListener();
    } catch (e, stackTrace) {
      commonPrint.log("Tile onStart error: $e\n$stackTrace");
      unawaited(app?.tip("Start error: $e"));
    }
  }

  Future<void> handleStop() async {
    try {
      unawaited(app?.tip(appLocalizations.stopVpn));
      await globalState.appController.updateStatus(false);
    } catch (e) {
      commonPrint.log("Tile onStop error: $e");
    }
  }

  Future<void> handleChangeMode(String mode) async {
    try {
      final modeEnum = Mode.values.byName(mode);
      final patched = globalState.config.patchClashConfig.copyWith(
        mode: modeEnum,
      );
      globalState.config = globalState.config.copyWith(
        patchClashConfig: patched,
      );
      await preferences.saveConfig(globalState.config);

      final updateParamsMap = UpdateParams(
        tun: patched.tun.getRealTun(globalState.config.networkProps.routeMode),
        allowLan: patched.allowLan,
        findProcessMode: patched.findProcessMode,
        mode: modeEnum,
        logLevel: patched.logLevel,
        ipv6: patched.ipv6,
        tcpConcurrent: patched.tcpConcurrent,
        externalController: patched.externalController,
        unifiedDelay: patched.unifiedDelay,
        mixedPort: patched.mixedPort,
      ).toJson();

      final effective = globalState.effectiveExternalController.value;
      if (effective.isNotEmpty) {
        updateParamsMap['external-controller'] = effective;
      }

      final actionJson = json.encode(
        core_models.Action(
          id: "${ActionMethod.updateConfig.name}#${utils.id}",
          method: ActionMethod.updateConfig,
          data: json.encode(updateParamsMap),
        ),
      );
      unawaited(clashLib?.sendMessage(actionJson));
      unawaited(tile?.updateMode(mode));
    } catch (e) {
      commonPrint.log("Tile onChangeMode error: $e");
    }
  }

  String buildNotificationTitle(Profile? profile) {
    if (profile == null) {
      return appName;
    }

    final profileName = profile.label ?? profile.id;
    final serviceName = _decodeProviderHeader(
      profile.providerHeaders['flclashx-servicename'],
    );
    final displayName = serviceName.isNotEmpty ? serviceName : profileName;

    final serverGroupName = _decodeProviderHeader(
      profile.providerHeaders['flclashx-serverinfo'],
    );
    var serverName = '';
    if (serverGroupName.isNotEmpty) {
      serverName = profile.selectedMap[serverGroupName] ?? '';
    }
    if (serverName.isEmpty) {
      for (final entry in profile.selectedMap.entries) {
        final value = entry.value;
        if (value.isNotEmpty && value != 'DIRECT' && value != 'REJECT') {
          serverName = value;
          break;
        }
      }
    }

    return serverName.isNotEmpty ? '$displayName / $serverName' : displayName;
  }

  String _decodeProviderHeader(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }
    try {
      final normalized = base64.normalize(value);
      return utf8.decode(base64.decode(normalized)).trim();
    } catch (_) {
      return value.trim();
    }
  }
}

class _MainTileListener with TileListener {
  _MainTileListener(this.entrypoint);

  final AndroidEntrypoint entrypoint;

  @override
  void onStart() {
    unawaited(entrypoint.handleStart());
  }

  @override
  void onStop() {
    unawaited(entrypoint.handleStop());
  }

  @override
  void onChangeMode(String mode) {
    unawaited(entrypoint.handleChangeMode(mode));
  }
}

final androidEntrypoint = AndroidEntrypoint.instance;
