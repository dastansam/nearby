import 'package:flutter/services.dart';

import 'transport.dart';

/// iOS Multipeer Connectivity (ios/Runner/Multipeer.swift): every iPhone both advertises and
/// browses, and Multipeer picks Bluetooth or peer-to-peer Wi-Fi underneath. iPhones only: it
/// does not speak to Android's Nearby Connections. Naming, dialing and redialing are all on
/// the Swift side; this class only carries bytes and events across the channel.
///
/// The channel protocol, both ways by method call:
///   to iOS:   start(), send({peer, data}), stop()
///   from iOS: connected(peer), disconnected(peer), message({peer, data})
class MultipeerTransport implements Transport {
  static const _channel = MethodChannel('dev.nearby/multipeer');

  @override
  Future<void> start({
    required void Function(String peer) onConnected,
    required void Function(String peer) onDisconnected,
    required void Function(String peer, Uint8List data) onMessage,
  }) async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'connected':
          onConnected(call.arguments as String);
        case 'disconnected':
          onDisconnected(call.arguments as String);
        case 'message':
          onMessage(call.arguments['peer'] as String, call.arguments['data'] as Uint8List);
      }
    });
    await _channel.invokeMethod<void>('start');
  }

  @override
  Future<void> send(String peer, Uint8List data) => _channel.invokeMethod<void>('send', {'peer': peer, 'data': data});

  @override
  Future<void> stop() async {
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('stop');
  }
}
