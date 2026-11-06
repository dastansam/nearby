import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'transport.dart';

const _serviceId = 'dev.nearby.nearby';

/// Android Nearby Connections: every phone both advertises and discovers (cluster strategy),
/// and Nearby picks BLE, Bluetooth or Wi-Fi underneath.
class NearbyTransport implements Transport {
  final _nearby = Nearby();

  /// Random per app start, so the advertisement does not carry a stable identity. Of two
  /// phones that see each other, the one with the smaller name dials, so they never both do.
  final _name = List.generate(8, (_) => Random.secure().nextInt(16).toRadixString(16)).join();

  /// Phones in range that this one is the dialer for, and the phones connected right now.
  final _dialable = <String>{}, _connected = <String>{};
  final _redials = <String, Timer>{};

  @override
  Future<void> start({
    required void Function(String peer) onConnected,
    required void Function(String peer) onDisconnected,
    required void Function(String peer, Uint8List data) onMessage,
  }) async {
    // Which of these exist depends on the Android version; Nearby fails below if one it needs is missing.
    await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.location,
    ].request();

    // Anyone running the app may connect: vouchers are signed, and relays verify before carrying.
    void accept(String id, ConnectionInfo info) => _nearby.acceptConnection(id, onPayLoadRecieved: (id, payload) {
          final bytes = payload.bytes;
          if (bytes != null) onMessage(id, bytes);
        }).catchError((_) => false);

    // Nearby reports a phone once, when it comes into range. A dial that fails or a link that
    // drops while the phone is still there would otherwise leave the two unconnected for good.
    late final void Function(String id) dial;
    void redial(String id) => _redials[id] ??= Timer(const Duration(seconds: 5), () {
          _redials.remove(id);
          dial(id);
        });
    void up(String id, Status status) {
      if (status != Status.CONNECTED) return redial(id);
      _connected.add(id);
      onConnected(id);
    }

    void down(String id) {
      _connected.remove(id);
      onDisconnected(id);
      redial(id);
    }

    dial = (id) {
      if (!_dialable.contains(id) || _connected.contains(id)) return;
      _nearby
          .requestConnection(_name, id, onConnectionInitiated: accept, onConnectionResult: up, onDisconnected: down)
          .catchError((_) {
        redial(id);
        return false;
      });
    };

    await _nearby.startAdvertising(_name, Strategy.P2P_CLUSTER,
        onConnectionInitiated: accept, onConnectionResult: up, onDisconnected: down, serviceId: _serviceId);
    await _nearby.startDiscovery(_name, Strategy.P2P_CLUSTER,
        onEndpointFound: (id, name, _) {
          if (_name.compareTo(name) >= 0) return;
          _dialable.add(id);
          dial(id);
        },
        onEndpointLost: (id) => _dialable.remove(id),
        serviceId: _serviceId);
  }

  @override
  Future<void> send(String peer, Uint8List data) => _nearby.sendBytesPayload(peer, data);

  @override
  Future<void> stop() async {
    for (final t in _redials.values) {
      t.cancel();
    }
    _redials.clear();
    _dialable.clear();
    _connected.clear();
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    await _nearby.stopAllEndpoints();
  }
}
