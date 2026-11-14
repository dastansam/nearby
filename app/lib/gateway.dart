// Gateway duty: whenever this phone has a signal, it hands every voucher it holds to the relayer,
// which settles them on intents.near and pays the gas.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'store.dart';
import 'voucher/attestation.dart';

/// Set at build time: flutter build apk --dart-define=RELAYER_URL=https://relayer.example
const relayerUrl = String.fromEnvironment('RELAYER_URL');

/// The relayer settles one voucher per transaction, a few seconds each, so uploads are kept small
/// enough to be answered in time. An answer lost to a timeout is not lost work: the relayer
/// finishes anyway and reports those vouchers settled on the next try.
const _vouchersPerUpload = 10;
const _answerWithin = Duration(seconds: 120);

class Gateway {
  Gateway(this._store, String relayerUrl, {this.account, http.Client? client, this.onChange})
      : _base = relayerUrl.replaceFirst(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  final VoucherStore _store;
  final String _base;
  final http.Client _client;

  /// This phone's own offline account, whose balance attestation is kept fresh. Null: none is fetched.
  final String? account;

  /// Called after every attempt to reach the relayer, so the UI can refresh.
  final void Function()? onChange;

  /// Why the last attempt did not go through, for the user to read; null when it did.
  String? problem = _noSignal;
  static const _noSignal = 'No signal';

  Timer? _timer, _pulse;
  StreamSubscription<void>? _puts;
  bool _busy = false, _again = false;

  /// Keeps trying: now, every half minute, and whenever a voucher is stored. The first phone with
  /// a signal settles for everyone, and no phone knows in advance that it will be the one.
  void start() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _attempt());
    _pulse = Timer.periodic(const Duration(seconds: 4), (_) => checkSignal());
    _puts = _store.puts.listen((_) => _attempt());
    _attempt();
  }

  /// Asks the relayer the cheapest question there is. An attempt with nothing to upload makes no
  /// request, so it cannot tell that the signal has gone; and a phone that has just got it back
  /// should settle now, not at the next half minute.
  Future<void> checkSignal() async {
    if (_busy) return; // an attempt is talking to the relayer and will say how it went
    bool reached;
    try {
      reached = (await _client.get(Uri.parse('$_base/healthz')).timeout(const Duration(seconds: 3))).statusCode == 200;
    } catch (_) {
      reached = false;
    }
    if (reached && problem == _noSignal) return _attempt();
    if (!reached && problem == null) {
      problem = _noSignal;
      onChange?.call();
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _pulse?.cancel();
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
        await _refreshAttestationIfOld();
        problem = null;
      } on http.ClientException {
        problem = _noSignal; // the usual case, and the reason the mesh exists
      } on TimeoutException {
        problem = _noSignal;
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
  /// Expired ones are asked about too: another phone may have settled them in time. So are settled
  /// ones whose block is not known yet: until it is, they count against the payer's balance.
  ///
  /// Throws if the relayer cannot be reached, which is the normal state of a phone with no signal.
  Future<void> sync() async {
    final pending = [
      for (final s in await _store.all())
        if (s.outcome == null || (s.outcome == Outcome.settled && s.settledBlock == null)) s.voucher
    ];
    for (var i = 0; i < pending.length; i += _vouchersPerUpload) {
      final batch = pending.skip(i).take(_vouchersPerUpload).toList();
      final response = await _client
          .post(Uri.parse('$_base/vouchers'), headers: {'content-type': 'application/json'}, body: jsonEncode({'vouchers': batch}))
          .timeout(_answerWithin);
      if (response.statusCode != 200) throw StateError('relayer answered ${response.statusCode}');
      final results = jsonDecode(response.body)['results'] as List;
      // Results match vouchers by position, so a list of another length would credit the wrong ones.
      if (results.length != batch.length) throw StateError('relayer answered for ${results.length} of ${batch.length}');
      for (final (j, result) in results.indexed) {
        final outcome = const {'settled': Outcome.settled, 'invalid': Outcome.failed}[result['status']];
        if (outcome == null) {
          // "rejected" is not final, but a merchant with the customer still in front of them must hear it.
          if (result['status'] == 'rejected') _store.noteRejection(batch[j], result['reason'] as String? ?? 'rejected');
          continue;
        }
        // A settled result may carry the relayer's signed receipt, for phones with no signal that
        // still carry the voucher. They check it against the key this build pins, so one that fails
        // here would only be refused by every peer: record the answer without it, and say so (not
        // in a build that pins no key: it cannot carry receipts, and that is no misconfiguration).
        final receipt = result['receipt'];
        if (receipt != null && relayerKey.isNotEmpty) {
          if (await keepReceipt(_store, batch[j], receipt)) continue;
          debugPrint('gateway: the relayer\'s receipt is not signed by the key this build trusts');
        }
        await _store.setOutcome(batch[j], outcome, tx: result['tx'] as String?, block: result['block'] as int?);
      }
    }
  }

  /// Fetches a new balance attestation for [account]: what payees will accept this phone's
  /// payments against for the next 24 h. Throws if the relayer cannot be reached.
  Future<void> refreshAttestation() async {
    final response = await _client.get(Uri.parse('$_base/attestation/$account')).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw StateError('relayer answered ${response.statusCode}');
    final signed = jsonDecode(response.body);
    // Said out loud: a build with the wrong RELAYER_KEY would otherwise just never have a balance.
    if (await readAttestation(signed) == null) throw StateError('its attestation is not signed by the key this build trusts');
    await keepAttestation(_store, signed);
  }

  /// Often enough that a phone leaving coverage has most of the 24 h left; not on every upload.
  Future<void> _refreshAttestationIfOld() async {
    if (account == null || relayerKey.isEmpty) return; // nothing this build could verify or use
    final held = await attestationFor(_store, account!);
    if (held == null || held.asOf.isBefore(DateTime.now().subtract(const Duration(minutes: 10)))) {
      await refreshAttestation();
    }
  }
}
