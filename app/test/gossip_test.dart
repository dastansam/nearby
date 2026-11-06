import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/mesh/gossip.dart';
import 'package:nearby/mesh/transport.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An in-memory radio. Phones are in range only when linked, and every message is recorded.
class Air {
  final phones = <String, Phone>{};
  final messages = <({String from, String to, Map<String, dynamic> message})>[];

  void link(Phone a, Phone b) {
    a.radio.inRange.add(b.radio.name);
    b.radio.inRange.add(a.radio.name);
    a.radio.onConnected(b.radio.name);
    b.radio.onConnected(a.radio.name);
  }

  void unlink(Phone a, Phone b) {
    a.radio.inRange.remove(b.radio.name);
    b.radio.inRange.remove(a.radio.name);
    a.radio.onDisconnected(b.radio.name);
    b.radio.onDisconnected(a.radio.name);
  }

  /// Waits until no phone has anything left to say.
  Future<void> settle() async {
    int seen;
    do {
      seen = messages.length;
      for (final p in phones.values.toList()) {
        await p.gossip.idle;
      }
    } while (messages.length != seen);
  }

  Iterable<Map<String, dynamic>> sent(String type) => messages.map((m) => m.message).where((m) => m['t'] == type);
}

class Radio implements Transport {
  Radio(this.air, this.name);
  final Air air;
  final String name;
  final inRange = <String>{};
  late void Function(String) onConnected, onDisconnected;
  late void Function(String, Uint8List) onMessage;

  @override
  Future<void> start({
    required void Function(String peer) onConnected,
    required void Function(String peer) onDisconnected,
    required void Function(String peer, Uint8List data) onMessage,
  }) async {
    this.onConnected = onConnected;
    this.onDisconnected = onDisconnected;
    this.onMessage = onMessage;
  }

  @override
  Future<void> send(String peer, Uint8List data) async {
    if (!inRange.contains(peer)) throw StateError('$peer is out of range');
    air.messages.add((from: name, to: peer, message: jsonDecode(utf8.decode(data))));
    air.phones[peer]!.radio.onMessage(name, data);
  }

  @override
  Future<void> stop() async {}
}

class Phone {
  Phone(this.radio, this.store, this.gossip);
  final Radio radio;
  final VoucherStore store;
  final Gossip gossip;

  Future<bool> holds(Map<String, dynamic> voucher) async => (await store.keys()).contains(voucherKey(voucher));
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const request = PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: '2500000');
  late Air air;
  late Directory dir;

  setUp(() {
    air = Air();
    dir = Directory.systemTemp.createTempSync('nearby_gossip_');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Phone> phone(String name) async {
    final radio = Radio(air, name);
    final store = await VoucherStore.open('${dir.path}/$name.db');
    final p = Phone(radio, store, Gossip(radio, store));
    await p.gossip.start();
    return air.phones[name] = p;
  }

  Future<Map<String, dynamic>> payment() async => signPayment(await Ed25519().newKeyPair(), request);

  // The point of the mesh: the payer and the gateway never meet, yet the payment gets there.
  test('a payment reaches a phone that never met the payer', () async {
    final payer = await phone('payer'), walker = await phone('walker'), gateway = await phone('gateway');
    final voucher = await payment();
    await payer.store.put(voucher, VoucherKind.sent);

    air.link(payer, walker);
    await air.settle();
    air.unlink(payer, walker);
    air.link(walker, gateway);
    await air.settle();

    expect(await gateway.holds(voucher), isTrue);
    final carried = (await gateway.store.all()).single;
    expect((carried.kind, carried.hops), (VoucherKind.relayed, 2));
    expect(carried.voucher, voucher, reason: 'the gateway must be able to submit exactly what was signed');
  });

  // The payer may keep the QR on screen for minutes; the payment should already be travelling.
  test('a payment is offered to connected phones as soon as it is stored, and passed on', () async {
    final payer = await phone('payer'), middle = await phone('middle'), far = await phone('far');
    await payer.store.put(await payment(), VoucherKind.sent);
    air.link(payer, middle);
    air.link(middle, far);
    await air.settle();
    air.messages.clear();

    final voucher = await payment();
    await payer.store.put(voucher, VoucherKind.sent);
    await air.settle();

    expect(await far.holds(voucher), isTrue);
    expect(air.sent('have').map((m) => (m['ids'] as List).length), everyElement(1),
        reason: 'only the new payment is announced, not everything the phone holds');
  });

  // Radio time is scarce and phones meet repeatedly; resending everything on every meeting
  // would drown the link once a phone carries a day of payments.
  test('phones that meet again exchange only what the other lacks', () async {
    final a = await phone('a'), b = await phone('b');
    final first = await payment(), second = await payment();
    await a.store.put(first, VoucherKind.sent);
    air.link(a, b);
    await air.settle();
    air.unlink(a, b);
    await a.store.put(second, VoucherKind.sent);
    air.messages.clear();

    air.link(a, b);
    await air.settle();

    expect(air.sent('voucher').map((m) => m['v']), [second]);
  });

  test('a voucher stops being passed on at the hop limit', () async {
    // Bounds how far anything, including junk signed by a throwaway key, can spread.
    final line = [for (var i = 0; i <= maxHops + 1; i++) await phone('p$i')];
    final voucher = await payment();
    await line.first.store.put(voucher, VoucherKind.sent);
    for (var i = 0; i < line.length - 1; i++) {
      air.link(line[i], line[i + 1]);
    }
    await air.settle();

    expect(await line[maxHops].holds(voucher), isTrue);
    expect(await line[maxHops + 1].holds(voucher), isFalse);
  });

  // A relay cannot tell a payment from junk except by checking it could still settle.
  group('a relay refuses to carry', () {
    Future<void> expectDropped(Map<String, dynamic> message) async {
      final relay = await phone('relay'), next = await phone('next'), sender = await phone('sender');
      air.link(relay, next);
      air.link(sender, relay);
      await air.settle();
      relay.radio.onMessage('sender', utf8.encode(jsonEncode(message)));
      await air.settle();
      expect(await relay.store.all(), isEmpty);
      expect(air.sent('voucher'), isEmpty);
    }

    test('a voucher altered in transit', () async {
      final v = await payment();
      (v['payload'] as Map<String, dynamic>)['message'] =
          (v['payload']['message'] as String).replaceFirst('merchant.near', 'thief.near');
      await expectDropped({'t': 'voucher', 'v': v, 'hops': 1});
    });

    test('an expired voucher', () async {
      final v = await signVoucher(await Ed25519().newKeyPair(), [Transfer('merchant.near', {usdcToken: '1'})],
          DateTime.now().subtract(const Duration(minutes: 1)), makeNonce());
      await expectDropped({'t': 'voucher', 'v': v, 'hops': 1});
    });

    test('a voucher claiming an impossible hop count', () async {
      await expectDropped({'t': 'voucher', 'v': await payment(), 'hops': 0});
      await expectDropped({'t': 'voucher', 'v': await payment(), 'hops': maxHops + 1});
    });
  });

  test('a garbage message from one peer does not stop the relay working', () async {
    final a = await phone('a'), b = await phone('b');
    air.link(a, b);
    await air.settle();
    b.radio.onMessage('a', Uint8List.fromList([0xff, 0x00, 0x7b]));
    b.radio.onMessage('a', utf8.encode('{"t":"have","ids":"not a list"}'));

    final voucher = await payment();
    await a.store.put(voucher, VoucherKind.sent);
    await air.settle();

    expect(await b.holds(voucher), isTrue);
  });
}
