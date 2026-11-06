// Gateway duty: whenever this phone has a signal, it hands every voucher it holds to the relayer,
// which settles them on intents.near and pays the gas.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'store.dart';

/// Set at build time: flutter build apk --dart-define=RELAYER_URL=https://relayer.example
const relayerUrl = String.fromEnvironment('RELAYER_URL');

/// The relayer settles one voucher per transaction, a few seconds each, so uploads are kept small
/// enough to be answered in time. An answer lost to a timeout is not lost work: the relayer
/// finishes anyway and reports those vouchers settled on the next try.
const _vouchersPerUpload = 20;
const _answerWithin = Duration(seconds: 60);

class Gateway {
  Gateway(this._store, String relayerUrl, {http.Client? client, this.onChange})
      : _endpoint = Uri.parse('$relayerUrl/vouchers'),
        _client = client ?? http.Client();

  final VoucherStore _store;
  final Uri _endpoint;
  final http.Client _client;

  /// Called after every attempt to reach the relayer, so the UI can refresh.
  final void Function()? onChange;

  /// Whether the last attempt reached the relayer.
  bool online = false;

  Timer? _timer;
  StreamSubscription<void>? _puts;
  bool _busy = false, _again = false;

  /// Keeps trying: now, every half minute, and whenever a voucher is stored. The first phone with
  /// a signal settles for everyone, and no phone knows in advance that it will be the one.
  void start() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _attempt());
    _puts = _store.puts.listen((_) => _attempt());
    _attempt();
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _puts?.cancel();
  }

  /// One upload at a time. A voucher stored while one is in flight gets its own right after,
  /// rather than waiting for the next half minute.
  Future<void> _attempt() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    do {
      _again = false;
      try {
        await sync();
        online = true;
      } catch (_) {
        online = false; // no signal: the usual case, and the reason the mesh exists
      }
    } while (_again && online);
    _busy = false;
    onChange?.call();
  }

  /// Uploads every voucher that could still settle and records the ones the relayer reports
  /// settled. Vouchers it refuses for now (the payer's balance is short) are sent again next time.
  ///
  /// Throws if the relayer cannot be reached, which is the normal state of a phone with no signal.
  Future<void> sync() async {
    final now = DateTime.now();
    final pending = [
      for (final s in await _store.all())
        if (canSettle(s, now)) s.voucher
    ];
    for (var i = 0; i < pending.length; i += _vouchersPerUpload) {
      final batch = pending.skip(i).take(_vouchersPerUpload).toList();
      final response = await _client
          .post(_endpoint, headers: {'content-type': 'application/json'}, body: jsonEncode({'vouchers': batch}))
          .timeout(_answerWithin);
      if (response.statusCode != 200) throw StateError('relayer answered ${response.statusCode}');
      final results = jsonDecode(response.body)['results'] as List;
      // Results match vouchers by position, so a list of another length would credit the wrong ones.
      if (results.length != batch.length) throw StateError('relayer answered for ${results.length} of ${batch.length}');
      for (final (j, result) in results.indexed) {
        if (result['status'] == 'settled') await _store.markSettled(batch[j], result['tx'] as String?);
      }
    }
  }
}
