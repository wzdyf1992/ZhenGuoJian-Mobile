import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core_bridge.dart';

class AppDevice {
  const AppDevice({this.television = false, this.version = ''});
  final bool television;
  final String version;
  static const channel = MethodChannel('duanju/device');
  static const castChannel = MethodChannel('duanju/cast');
  static void Function(String action)? _castAction;
  static var _televisionMode = false;
  static var _phoneMode = false;

  static Future<AppDevice> detect({
    AppDevice fallback = const AppDevice(),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      try {
        final info = await PackageInfo.fromPlatform();
        return AppDevice(version: info.version);
      } catch (_) {
        return fallback;
      }
    }
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final television = data?['television'];
      if (television is! bool) return fallback;
      final version = data?['version'];
      return AppDevice(
        television: television,
        version: version is String && version.isNotEmpty
            ? version
            : fallback.version,
      );
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    } on TimeoutException {
      return fallback;
    }
  }

  static Future<bool> compatibleRendering() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('compatibleRendering') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setCompatibleRendering(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await channel.invokeMethod('setCompatibleRendering', {
        'enabled': enabled,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setTelevisionMode(bool enabled) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _televisionMode = enabled;
      return setPlayerOrientation(PlayerOrientation.auto);
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<void>('setTelevisionMode', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  static Future<void> setPhoneMode(bool enabled) {
    _phoneMode = enabled;
    return releaseOrientation();
  }

  static Future<void> releaseOrientation() => setPlayerOrientation(
    _phoneMode ? PlayerOrientation.lockedPortrait : PlayerOrientation.auto,
  );

  static Future<void> setPlayerOrientation(
    PlayerOrientation orientation,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await channel.invokeMethod<void>('setPlayerOrientation', {
          'mode': orientation.name,
        });
      } catch (_) {}
      return;
    }
    try {
      await SystemChrome.setPreferredOrientations(switch (_televisionMode
          ? PlayerOrientation.landscape
          : orientation) {
        PlayerOrientation.landscape ||
        PlayerOrientation.lockedLandscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        PlayerOrientation.portrait || PlayerOrientation.lockedPortrait =>
          const [DeviceOrientation.portraitUp],
        PlayerOrientation.auto => const [],
      });
    } catch (_) {}
  }

  static Future<double?> brightness() async {
    try {
      return await channel.invokeMethod<double>('getBrightness');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await channel.invokeMethod<void>('setBrightness', {'brightness': value});
    } catch (_) {}
  }

  static Future<void> resetBrightness() async {
    try {
      await channel.invokeMethod<void>('resetBrightness');
    } catch (_) {}
  }

  static Future<double?> volume() async {
    try {
      return await channel.invokeMethod<double>('volume');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setVolume(double value) async {
    try {
      await channel.invokeMethod<void>('setVolume', {'volume': value});
    } catch (_) {}
  }

  static Future<String?> createDocument(String name, String mimeType) async {
    try {
      return await channel.invokeMethod<String>('createDocument', {
        'name': name,
        'mimeType': mimeType,
      });
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法创建文件');
    }
  }

  static Future<bool> requestVideoExport() async {
    try {
      return await channel.invokeMethod<bool>('requestVideoExport') ?? false;
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法申请存储权限');
    }
  }

  static Future<void> exportVideo(
    String source,
    String folder,
    String name,
  ) async {
    try {
      await channel.invokeMethod<void>('exportVideo', {
        'source': source,
        'folder': folder,
        'name': name,
      });
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '导出失败');
    }
  }

  static Future<void> deleteDocument(String uri) async {
    try {
      await channel.invokeMethod<bool>('deleteDocument', {'uri': uri});
    } catch (_) {}
  }

  static Future<({int level, bool charging})?> battery() async {
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('battery');
      final level = data?['level'];
      if (level is! int) return null;
      return (level: level, charging: data?['charging'] == true);
    } catch (_) {
      return null;
    }
  }

  static Future<List<({String name, String address})>> lanAddresses() async {
    if (defaultTargetPlatform != TargetPlatform.android) return const [];
    try {
      final items = await channel
          .invokeListMethod<dynamic>('lanAddresses')
          .timeout(const Duration(seconds: 2));
      if (items == null) return const [];
      final results = <({String name, String address})>[];
      for (final item in items) {
        if (item is! Map) continue;
        final address = item['address'];
        if (address is! String || address.isEmpty) continue;
        final name = item['name'];
        results.add((name: name is String ? name : '', address: address));
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  static void Function(String action)? get onCastAction => _castAction;

  static set onCastAction(void Function(String action)? handler) {
    _castAction = handler;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      castChannel.setMethodCallHandler(
        handler == null
            ? null
            : (call) async {
                if (call.method != 'castMediaAction') return;
                final map = call.arguments;
                if (map is! Map) return;
                final action = map['action'];
                if (action is String && action.isNotEmpty) {
                  _castAction?.call(action);
                }
              },
      );
    } catch (_) {}
  }

  static Future<void> updateCastSession({
    required bool active,
    String deviceName = '',
    String title = '',
    bool playing = false,
    bool paused = false,
    bool hasPrevious = false,
    bool hasNext = false,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await castChannel.invokeMethod<void>('updateCastSession', {
        'active': active,
        'deviceName': deviceName,
        'title': title,
        'playing': playing,
        'paused': paused,
        'hasPrevious': hasPrevious,
        'hasNext': hasNext,
      });
    } catch (_) {}
  }

  static Future<void> setCastKeepAwake(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<void>('setCastKeepAwake', {
        'enabled': enabled,
      });
    } catch (_) {}
  }
}

enum PlayerOrientation {
  landscape,
  lockedLandscape,
  portrait,
  lockedPortrait,
  auto,
}
