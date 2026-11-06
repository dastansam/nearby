// Store-and-forward relay: every phone carries the vouchers it knows toward the internet.
//
// When two phones connect, each says which vouchers it holds ("have"), asks for the ones it
// lacks ("want"), and gets them one per message ("voucher"). A phone that signs, accepts or
// learns a new voucher offers it to its peers, so a payment hops phone to phone until one has a signal.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../store.dart';
import '../voucher/nep413.dart';
import 'transport.dart';

/// A voucher is not passed on after this many hops, which bounds how far junk can spread.
const maxHops = 8;

/// The app signs vouchers valid for 72 h. A relay refuses ones valid far longer: nothing prunes
/// the store yet, so junk with a deadline in the year 9999 would be carried forever.
const _maxLifetime = Duration(days: 7);

/// Ids per "have" or "want" message, to stay under Nearby's 32 KB limit for one payload.
const _idsPerMessage = 1000;

/// Short stand-in for a voucher's key in "have" and "want" lists.
String gossipId(String voucherKey) => sha256.convert(utf8.encode(voucherKey)).toString().substring(0, 16);

class Gossip {
  Gossip(this._transport, this._store, {this.onChange});

  final Transport _transport;
  final VoucherStore _store;

  /// Called when a peer comes or goes, so the UI can refresh. (New vouchers show up on [VoucherStore.puts].)
  final void Function()? onChange;

  final _peers = <String>{};
  StreamSubscription<void>? _puts;
  Future<void> _queue = Future.value();

  int get peerCount => _peers.length;

  /// Completes when every event received so far has been handled.
  Future<void> get idle => _queue;

  Future<void> start() {
    // This phone's own payments go out the moment they are stored, while the payer is still
    // showing the QR. Relayed ones are offered by _handle, which knows which peer to skip.
    _puts = _store.puts.listen((p) {
      if (p.kind != VoucherKind.relayed) _enqueue(() => _sendIds(_peers, 'have', [gossipId(voucherKey(p.voucher))]));
    });
    return _transport.start(
      onConnected: (peer) => _enqueue(() async {
        _peers.add(peer);
        onChange?.call();
        await _sendIds([peer], 'have', (await _forwardable()).keys.toList());
      }),
      onDisconnected: (peer) => _enqueue(() async {
        _peers.remove(peer);
        onChange?.call();
      }),
      onMessage: (peer, data) => _enqueue(() => _handle(peer, jsonDecode(utf8.decode(data)))),
    );
  }

  Future<void> stop() async {
    await _puts?.cancel();
    await _transport.stop();
  }

  /// One event at a time, in arrival order. A peer's bad message fails alone, and is logged:
  /// a local fault (say, the database) would otherwise look like a healthy mesh that relays nothing.
  Future<void> _enqueue(Future<void> Function() task) =>
      _queue = _queue.then((_) => task()).catchError((Object e) => debugPrint('gossip: $e'));

  /// Vouchers worth passing on, by gossip id: not expired and not at the hop limit.
  Future<Map<String, StoredVoucher>> _forwardable() async {
    final now = DateTime.now();
    return {
      for (final s in await _store.all())
        if (s.hops < maxHops && voucherDeadline(s.voucher).isAfter(now)) gossipId(voucherKey(s.voucher)): s
    };
  }

  Future<void> _sendIds(Iterable<String> peers, String type, List<String> ids) async {
    for (var i = 0; i < ids.length; i += _idsPerMessage) {
      final chunk = ids.sublist(i, (i + _idsPerMessage).clamp(0, ids.length));
      for (final peer in peers.toList()) {
        await _send(peer, {'t': type, 'ids': chunk});
      }
    }
  }

  /// A peer that just walked away must not stop the others being served; its disconnect is on the way.
  Future<void> _send(String peer, Map<String, dynamic> message) =>
      _transport.send(peer, utf8.encode(jsonEncode(message))).catchError((Object e) => debugPrint('gossip: $e'));

  Future<void> _handle(String peer, dynamic m) async {
    switch (m['t']) {
      case 'have':
        final held = {for (final key in await _store.keys()) gossipId(key)};
        await _sendIds([peer], 'want', [
          for (final id in (m['ids'] as List).cast<String>())
            if (!held.contains(id)) id
        ]);
      case 'want':
        final forwardable = await _forwardable();
        for (final id in (m['ids'] as List).cast<String>()) {
          final s = forwardable[id];
          if (s != null) await _send(peer, {'t': 'voucher', 'v': s.voucher, 'hops': s.hops + 1});
        }
      case 'voucher':
        final v = m['v'] as Map<String, dynamic>, hops = m['hops'] as int;
        // Carry only what could still settle: a relay has no other way to tell a payment from junk.
        if (hops < 1 || hops > maxHops || await verifyVoucher(v) != null) return;
        if (voucherDeadline(v).isAfter(DateTime.now().add(_maxLifetime))) return;
        if (!await _store.put(v, VoucherKind.relayed, hops: hops)) return;
        if (hops < maxHops) await _sendIds(_peers.where((p) => p != peer), 'have', [gossipId(voucherKey(v))]);
    }
  }
}
