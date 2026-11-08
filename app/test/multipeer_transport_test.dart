
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/mesh/multipeer_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.nearby/multipeer');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // The other half of this protocol is ios/Runner/Multipeer.swift. The two are only ever checked
  // against each other on a phone, so the Dart half is pinned here: a renamed method or a
  // reshaped argument would otherwise show up as a mesh that silently never connects.
  test('speaks the channel protocol the Swift side implements', () async {
    final toIos = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async => toIos.add(call));
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Future<void> fromIos(String method, Object? arguments) => messenger.handlePlatformMessage(
        channel.name, channel.codec.encodeMethodCall(MethodCall(method, arguments)), (_) {});

    final events = <String>[];
    final radio = MultipeerTransport();
    await radio.start(
      onConnected: (p) => events.add('up $p'),
      onDisconnected: (p) => events.add('down $p'),
      onMessage: (p, data) => events.add('from $p: ${String.fromCharCodes(data)}'),
    );
    expect(toIos.single.method, 'start');
    expect(toIos.single.arguments, isNull, reason: 'the Swift side picks its own name');

    await fromIos('connected', 'a1b2c3d4');
    await fromIos('message', {'peer': 'a1b2c3d4', 'data': Uint8List.fromList('hi'.codeUnits)});
    await fromIos('disconnected', 'a1b2c3d4');
    expect(events, ['up a1b2c3d4', 'from a1b2c3d4: hi', 'down a1b2c3d4']);

    await radio.send('a1b2c3d4', Uint8List.fromList([7]));
    expect(toIos[1].method, 'send');
    expect(toIos[1].arguments, {'peer': 'a1b2c3d4', 'data': [7]});

    await radio.stop();
    expect(toIos.last.method, 'stop');
    await fromIos('connected', 'late');
    expect(events.length, 3, reason: 'nothing is reported after stop');
  });
}
