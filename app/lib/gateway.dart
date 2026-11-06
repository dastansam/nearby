// Gateway duty: whenever this phone has a signal, it hands every voucher it holds to the relayer,
// which settles them on intents.near and pays the gas.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'store.dart';

/// Set at build time: flutter build apk --dart-define=RELAYER_URL=https://relayer.example
const relayerUrl = String.fromEnvironment('RELAYER_URL');

/// The relayer settles one voucher per transaction, a few seconds each, so uploads are kept small
/// enough to be answered in time. An answer lost to a timeout is not lost work: the relayer
/// finishes anyway and reports those vouchers settled on the next try.
const _vouchersPerUpload = 10;
const _answerWithin = Duration(seconds: 120);

class Gateway {
  Gateway(this._store, String relayerUrl, {http.Client? client, this.onChange})
      : _endpoint = Uri.parse('${relayerUrl.replaceFirst(RegExp(r'/+$'), '')}/vouchers'),
        _client = client ?? http.Client();

  final VoucherStore _store;
  final Uri _endpoint;
  final http.Client _client;

  /// Called after every attempt to reach the relayer, so the UI can refresh.
  final void Function()? onChange;

  /// Why the last attempt did not go through, for the user to read; null when it did.
  String? problem = 'No signal';

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
        problem = null;
      } on http.ClientException {
        problem = 'No signal'; // the usual case, and the reason the mesh exists
      } on TimeoutException {
        problem = 'No signal';
      } catch (e) {
        // A wrong relayer address or a relayer fault would otherwise look like a phone with no signal.
        problem = 'Relayer problem: $e';
        debugPrint('gateway: $e');
      }
    } while (_again && problem == null);
    _busy = false;
    onChange?.call();
  }

  /// Uploads every voucher without a final answer and records the relayer's: settled, or never
  /// going to. Vouchers it refuses for now (the payer's balance is short) are sent again next time.
  /// Expired ones are asked about too: another phone may have settled them in time.
  ///
  /// Throws if the relayer cannot be reached, which is the normal state of a phone with no signal.
  Future<void> sync() async {
    final pending = [
      for (final s in await _store.all())
        if (s.outcome == null) s.voucher
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
        final outcome = const {'settled': Outcome.settled, 'invalid': Outcome.failed}[result['status']];
        if (outcome != null) await _store.setOutcome(batch[j], outcome, tx: result['tx'] as String?);
      }
    }
  }
}
