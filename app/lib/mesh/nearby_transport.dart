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

  @override
  Future<void> start({
    required void Function(String peer) onConnected,
    required void Function(String peer) onDisconnected,
    required void Function(String peer, Uint8List data) onMessage,
  }) async {
    // Anyone running the app may connect: vouchers are signed, and relays verify before carrying.
    void accept(String id, ConnectionInfo info) => _nearby.acceptConnection(id, onPayLoadRecieved: (id, payload) {
          final bytes = payload.bytes;
          if (bytes != null) onMessage(id, bytes);
        }).catchError((_) => false);
    void result(String id, Status status) {
      if (status == Status.CONNECTED) onConnected(id);
    }

    // Which of these exist depends on the Android version; Nearby fails below if one it needs is missing.
    await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.location,
    ].request();
    await _nearby.startAdvertising(_name, Strategy.P2P_CLUSTER,
        onConnectionInitiated: accept,
        onConnectionResult: result,
        onDisconnected: onDisconnected,
        serviceId: _serviceId);
    await _nearby.startDiscovery(_name, Strategy.P2P_CLUSTER,
        onEndpointFound: (id, name, _) {
          if (_name.compareTo(name) >= 0) return;
          // Dialing fails harmlessly if the link is already up or the phone walked away.
          _nearby
              .requestConnection(_name, id,
                  onConnectionInitiated: accept, onConnectionResult: result, onDisconnected: onDisconnected)
              .catchError((_) => false);
        },
        onEndpointLost: (_) {},
        serviceId: _serviceId);
  }

  @override
  Future<void> send(String peer, Uint8List data) => _nearby.sendBytesPayload(peer, data);

  @override
  Future<void> stop() async {
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    await _nearby.stopAllEndpoints();
  }
}
