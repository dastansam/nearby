import 'dart:typed_data';

/// A radio link to whichever phones are in range. The gossip layer only needs to know who is
/// connected and to exchange small messages with them, so Nearby Connections can be swapped
/// for raw BLE or another mesh without touching it.
abstract interface class Transport {
  /// Starts looking for peers and reports them through the handlers. Peer ids are only
  /// meaningful to this transport and may change between connections.
  Future<void> start({
    required void Function(String peer) onConnected,
    required void Function(String peer) onDisconnected,
    required void Function(String peer, Uint8List data) onMessage,
  });

  Future<void> send(String peer, Uint8List data);

  Future<void> stop();
}
