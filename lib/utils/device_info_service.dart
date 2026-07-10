import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashm/common/common.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:win32_registry/win32_registry.dart';

class DeviceDetails {
  DeviceDetails({
    this.hwid,
    this.os,
    this.osVersion,
    this.model,
    this.appVersion,
  });
  final String? hwid;
  final String? os;
  final String? osVersion;
  final String? model;
  final String? appVersion;
}

class DeviceInfoService {
  final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();
  // HWID is derived deterministically from a stable per-device identifier
  // (ANDROID_ID / MachineGuid / machine-id / systemGUID), so it is computed once
  // per app session and held in memory rather than persisted to shared_preferences:
  // recomputing yields the same value, and nothing stale can get stuck there.
  static String? _cachedHwid;
  static const MethodChannel _channel =
      MethodChannel('com.makriq.flclash/device_id');

  String _generateCompact16CharId(String fullId) {
    final bytes = utf8.encode(fullId);
    final hash = sha256.convert(bytes);
    final hashHex = hash.toString();
    return hashHex.substring(0, 16).toUpperCase();
  }

  Future<String?> _getAndroidId() async {
    try {
      final String? androidId = await _channel.invokeMethod('getAndroidId');
      if (androidId != null && androidId.isNotEmpty) {
        return androidId;
      }
      return null;
    } catch (e) {
      commonPrint.log("Failed to get Android ID: $e");
      return null;
    }
  }

  Future<String?> _getWindowsMachineGuid() async {
    try {
      const keyPath = r'SOFTWARE\Microsoft\Cryptography';
      const valueName = 'MachineGuid';

      final key = Registry.openPath(RegistryHive.localMachine, path: keyPath);
      final data = key.getValue(valueName);
      key.close();

      return data?.toString();
    } catch (e) {
      return null;
    }
  }

  Future<String?> _getPlatformDeviceId() async {
    try {
      if (Platform.isWindows) {
        final machineGuid = await _getWindowsMachineGuid();
        if (machineGuid != null && machineGuid.isNotEmpty) {
          return machineGuid;
        }

        final info = await _deviceInfoPlugin.windowsInfo;
        final fallback =
            '${info.computerName}-${info.deviceId}-${info.productId}';
        return fallback;
      } else if (Platform.isAndroid) {
        // Try to get ANDROID_ID first (unique per device, persists across app reinstalls)
        final androidId = await _getAndroidId();
        if (androidId != null && androidId.isNotEmpty) {
          return androidId;
        }

        // Fallback to device info if ANDROID_ID is not available
        final info = await _deviceInfoPlugin.androidInfo;
        final combined =
            '${info.brand}-${info.device}-${info.hardware}-${info.id}';
        return combined;
      } else if (Platform.isLinux) {
        final info = await _deviceInfoPlugin.linuxInfo;
        final combined = info.machineId ?? '${info.id}-${info.name}';
        return combined;
      } else if (Platform.isMacOS) {
        final info = await _deviceInfoPlugin.macOsInfo;
        final combined =
            info.systemGUID ?? '${info.model}-${info.computerName}';
        return combined;
      }
      return null;
    } catch (e) {
      commonPrint.log("Failed to get platform device ID: $e");
      return null;
    }
  }

  Future<String?> _resolveHwid() async {
    if (_cachedHwid != null) return _cachedHwid;
    try {
      final deviceId = await _getPlatformDeviceId();

      if (deviceId == null || deviceId.isEmpty) {
        commonPrint.log("ERROR: Device ID is null or empty");
        return null;
      }

      // Android: ANDROID_ID directly; other platforms: hash the device ID to 16
      // characters. Cached for the rest of the app session.
      _cachedHwid =
          Platform.isAndroid ? deviceId : _generateCompact16CharId(deviceId);

      return _cachedHwid;
    } catch (e) {
      commonPrint.log("ERROR getting HWID: $e");
      return null;
    }
  }

  Future<DeviceDetails> getDeviceDetails() async {
    String? hwid, os, osVersion, model;
    final packageInfo = await PackageInfo.fromPlatform();
    final appVersion = packageInfo.version;

    try {
      hwid = await _resolveHwid();

      if (Platform.isWindows) {
        final info = await _deviceInfoPlugin.windowsInfo;
        os = 'Windows';
        osVersion = info.displayVersion;
        model = info.productName;
      } else if (Platform.isAndroid) {
        final info = await _deviceInfoPlugin.androidInfo;
        os = 'Android';
        osVersion = info.version.release;
        model = '${info.manufacturer} ${info.model}';
      } else if (Platform.isLinux) {
        final info = await _deviceInfoPlugin.linuxInfo;
        os = 'Linux';
        osVersion = info.versionId;
        model = info.name;
      } else if (Platform.isMacOS) {
        final info = await _deviceInfoPlugin.macOsInfo;
        os = 'macOS';
        osVersion = info.osRelease;
        model = info.model;
      }
    } catch (e) {
      // Silently handle errors in device info retrieval
    }

    return DeviceDetails(
      hwid: hwid,
      os: os,
      osVersion: osVersion,
      model: model,
      appVersion: appVersion,
    );
  }
}
