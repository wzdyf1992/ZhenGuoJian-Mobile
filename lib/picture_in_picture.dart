import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_device.dart';

double _clampRatio(double aspectRatio) =>
    aspectRatio.isFinite && aspectRatio > 0
    ? aspectRatio.clamp(1 / 2.39, 2.39)
    : 16 / 9;

Map<String, int> _ratio(double aspectRatio) {
  final ratio = _clampRatio(aspectRatio);
  return ratio >= 1
      ? {'width': (1000 * ratio).round(), 'height': 1000}
      : {'width': 1000, 'height': (1000 / ratio).round()};
}

class PictureInPicture extends ChangeNotifier {
  PictureInPicture._() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    AppDevice.channel.setMethodCallHandler(_handle);
    AppLifecycleListener(onStateChange: _lifecycleChanged);
    unawaited(_status());
  }

  static final instance = PictureInPicture._();

  void Function(String action)? onAction;
  bool _supported = false;
  bool _active = false;
  bool _pending = false;
  bool _leaving = false;
  Timer? _timer;
  Map<String, Object>? _sent;

  bool get available =>
      defaultTargetPlatform == TargetPlatform.android && _supported;

  bool get shown => _active || _pending;
  bool get leaving => _leaving;
  bool get active => _active;

  Future<void> _status() async {
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      _supported = status?['supported'] == true;
    } catch (_) {
      _supported = false;
    }
    notifyListeners();
  }

  Future<void> _handle(MethodCall call) async {
    final arguments = call.arguments;
    switch (call.method) {
      case 'pictureInPictureChanged':
        _setActive(arguments is Map && arguments['active'] == true);
      case 'pictureInPicturePending':
        _pending = true;
        notifyListeners();
      case 'pictureInPictureAction':
        if (arguments case {'action': final String action}) {
          onAction?.call(action);
        }
    }
  }

  void _setActive(bool active) {
    _timer?.cancel();
    _leaving = _active && !active;
    _active = active;
    _pending = false;
    if (_leaving) {
      _timer = Timer(const Duration(milliseconds: 700), () {
        _leaving = false;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void _lifecycleChanged(AppLifecycleState state) {
    if (!_pending || state == AppLifecycleState.inactive) return;
    _pending = false;
    notifyListeners();
  }

  void update({
    required double aspectRatio,
    required bool playing,
    required bool hasPrevious,
    required bool hasNext,
    required bool autoEnter,
  }) {
    if (defaultTargetPlatform != TargetPlatform.android || !_supported) return;
    final next = <String, Object>{
      ..._ratio(aspectRatio),
      'playing': playing,
      'hasPrevious': hasPrevious,
      'hasNext': hasNext,
      'autoEnter': autoEnter,
    };
    if (mapEquals(next, _sent)) return;
    _sent = next;
    unawaited(
      AppDevice.channel
          .invokeMethod<void>('updatePictureInPicture', next)
          .catchError((Object _) {}),
    );
  }

  void clear() {
    if (_sent == null) return;
    _sent = null;
    unawaited(
      AppDevice.channel
          .invokeMethod<void>('updatePictureInPicture')
          .catchError((Object _) {}),
    );
  }

  Future<void> enter(double aspectRatio) async {
    if (shown || !available) return;
    _timer?.cancel();
    _pending = true;
    notifyListeners();
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        _ratio(aspectRatio),
      );
      if (status?['active'] == true || status?['requested'] == true) {
        if (_pending) {
          _timer = Timer(const Duration(seconds: 2), () {
            if (!_pending) return;
            _pending = false;
            notifyListeners();
          });
        }
        return;
      }
    } catch (_) {}
    _pending = false;
    notifyListeners();
  }
}
