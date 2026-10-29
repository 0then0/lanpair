import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Native operations are deliberately independent of direct TCP/UDP probes.
class PlatformBridge {
  static const _methods = MethodChannel('lanpair/platform');
  static const _events = EventChannel('lanpair/discovery');

  Stream<Map<String, dynamic>> get events => _eventStream;

  late final Stream<Map<String, dynamic>> _eventStream = _events
      .receiveBroadcastStream()
      .map((value) => Map<String, dynamic>.from(value as Map));

  Future<Map<String, dynamic>> capabilities({bool request = false}) async {
    try {
      final value = await _methods.invokeMapMethod<String, dynamic>(
        request ? 'requestPermission' : 'capabilities',
      );
      return value ?? _unavailable;
    } on MissingPluginException {
      return _unavailable;
    } on PlatformException catch (e) {
      return {
        ..._unavailable,
        'limitationCodes': [e.code],
      };
    }
  }

  Map<String, dynamic> get _unavailable => {
    'platform': Platform.operatingSystem,
    'permission': 'unknown',
    'rawMulticast': false,
    'discovery': false,
    'limitationCodes': ['nativeUnavailable'],
  };

  Future<void> settings() => _methods.invokeMethod<void>('openSettings');
  Future<void> acquireMulticast() =>
      _methods.invokeMethod<void>('acquireMulticast');
  Future<void> releaseMulticast() =>
      _methods.invokeMethod<void>('releaseMulticast');
  Future<void> startDiscovery({
    required String sessionId,
    required String deviceId,
    required int port,
    required int interfaceIndex,
  }) => _methods.invokeMethod<void>('startDiscovery', {
    'name': 'LANPair-${sessionId.substring(0, 8)}-${deviceId.substring(0, 6)}',
    'port': port,
    'sessionId': sessionId,
    'deviceId': deviceId,
    'interfaceIndex': interfaceIndex,
  });
  Future<void> stopDiscovery() => _methods.invokeMethod<void>('stopDiscovery');
}
