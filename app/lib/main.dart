import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gateway.dart';
import 'mesh/gossip.dart';
import 'mesh/nearby_transport.dart';
import 'screens/pay.dart';
import 'screens/receive.dart';
import 'store.dart';
import 'voucher/attestation.dart';
import 'voucher/guards.dart';
import 'voucher/payment.dart';
import 'wallet.dart';

void main() => runApp(const NearByApp());

class NearByApp extends StatelessWidget {
  const NearByApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NearBy',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Wallet? _wallet;
  late VoucherStore _store;
  List<StoredVoucher> _vouchers = [];
  Object? _loadError;
  Gossip? _gossip;
  StreamSubscription<void>? _puts, _outcomes;
  Timer? _reload;
  int _carried = 0;
  Gateway? _gateway;
  int _waiting = 0; // vouchers on this phone, its own or carried, not yet known to be settled
  Attestation? _attested; // this phone's own balance, as the relayer last signed it
  BigInt _budget = BigInt.zero; // what is left of it after the payments signed since
  Object? _meshError;
  bool _busy = false; // a Pay or Receive flow is open; a second tap must not start another

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gossip?.stop();
    _puts?.cancel();
    _outcomes?.cancel();
    _reload?.cancel();
    _gateway?.stop();
    super.dispose();
  }

  Future<void> _load() async {
    final Wallet wallet;
    try {
      wallet = await Wallet.load();
      _store = await VoucherStore.open();
      if (mounted) setState(() => _wallet = wallet);
      await _reloadVouchers();
    } catch (e) {
      // Never fall through to a fresh wallet: the stored key may hold the user's money.
      if (mounted) {
        setState(() {
          _wallet = null;
          _loadError = e;
        });
      }
      return;
    }
    if (!mounted) return;
    // Paying and receiving by QR work without the mesh, so a mesh failure is shown, not fatal.
    // A phone met after a while hands over its vouchers and receipts in a burst; one reload covers the burst.
    void reloadSoon(StoredVoucher _) => _reload ??= Timer(const Duration(milliseconds: 300), () {
          _reload = null;
          _reloadVouchers();
        });
    _puts = _store.puts.listen(reloadSoon);
    _outcomes = _store.outcomes.listen(reloadSoon);
    if (relayerUrl.isNotEmpty) {
      _gateway = Gateway(_store, relayerUrl, account: wallet.accountId, onChange: _reloadVouchers)..start();
    }
    final gossip = Gossip(NearbyTransport(), _store, onChange: () {
      if (mounted) setState(() {});
    });
    try {
      await gossip.start();
      if (mounted) setState(() => _gossip = gossip);
    } catch (e) {
      // Starting can fail halfway (advertising up, discovery refused); do not leave half a mesh running unseen.
      await gossip.stop().catchError((_) {});
      if (mounted) setState(() => _meshError = e);
    }
  }

  Future<void> _flow(Future<void> Function() run) async {
    if (_busy) return;
    _busy = true;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await run();
      await _reloadVouchers();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Something went wrong, check the list before retrying: $e')));
    } finally {
      _busy = false;
    }
  }

  Future<void> _refreshBalance() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _gateway?.refreshAttestation();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not reach the relayer')));
    }
    await _reloadVouchers();
  }

  Future<void> _copyTx(String tx) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: 'https://nearblocks.io/txns/$tx'));
    messenger.showSnackBar(const SnackBar(content: Text('Transaction link copied')));
  }

  Future<void> _reloadVouchers() async {
    final all = await _store.all(), now = DateTime.now();
    final wallet = _wallet;
    final attested = wallet == null ? null : await attestationFor(_store, wallet.accountId);
    final mine = wallet == null ? const <StoredVoucher>[] : await _store.from(wallet.accountId);
    if (!mounted) return;
    // Only this phone's own payments are listed; carried ones would bury them, so they are just counted.
    setState(() {
      _vouchers = all.where((v) => v.kind != VoucherKind.relayed).toList();
      _carried = all.where((v) => v.kind == VoucherKind.relayed && canSettle(v, now)).length;
      _waiting = all.where((v) => canSettle(v, now)).length;
      _attested = attested;
      // Never shown below zero: signed for more than was attested just means nothing is left.
      final left = attested == null ? BigInt.zero : spendable(attested, mine);
      _budget = left.isNegative ? BigInt.zero : left;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wallet = _wallet;
    if (wallet == null) {
      return Scaffold(
        body: Center(
          child: _loadError == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not open the wallet. Your key was not changed.\n\n$_loadError'),
                ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('NearBy')),
      body: Column(children: [
        ListTile(
          title: const Text('Offline account'),
          subtitle: SelectableText(wallet.accountId),
        ),
        if (relayerKey.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: Text(_attested == null
                ? 'Offline balance unknown'
                : isStale(_attested!, DateTime.now())
                    ? 'Offline balance out of date'
                    : 'Offline balance: ${formatUsdc(_budget.toString())}'),
            subtitle: Text(_attested == null
                ? 'Go online once to load it. Payees accept payments only against it.'
                : 'As of ${TimeOfDay.fromDateTime(_attested!.asOf.toLocal()).format(context)} · tap to refresh'),
            onTap: _refreshBalance,
          ),
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: Text(_gossip == null ? 'Mesh off' : '${_gossip!.peerCount} phones connected'),
          subtitle: Text(_gossip == null
              ? (_meshError == null ? 'Starting' : 'QR payments still work. $_meshError')
              : 'Carrying $_carried payments toward the internet'),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: Text(_gateway == null
              ? 'No relayer in this build'
              : _gateway!.problem ?? 'Online: settling payments'),
          subtitle: Text(_gateway == null
              ? 'Payments are signed and relayed, and settle from a phone that has one'
              : '$_waiting payments waiting to settle'),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: () => _flow(() => pay(context, wallet, _store)),
                child: const Text('Pay'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.tonal(
                onPressed: () => _flow(() => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => ReceiveScreen(accountId: wallet.accountId, store: _store)))),
                child: const Text('Receive'),
              ),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _vouchers.length,
            itemBuilder: (context, i) {
              final v = _vouchers[i];
              final sent = v.kind == VoucherKind.sent, pending = canSettle(v, DateTime.now());
              return ListTile(
                leading: Icon(sent ? Icons.arrow_upward : Icons.arrow_downward),
                title: Text('${sent ? 'Sent' : 'Received'} ${formatUsdc(amountOf(v.voucher))}'),
                subtitle: Text(switch (v.outcome) {
                  Outcome.settled => v.tx == null ? 'Settled' : 'Settled · tap to copy the transaction link',
                  Outcome.failed => 'Did not settle',
                  // Another phone may have settled it in time; only the relayer can say.
                  null when !pending => 'Expired · not known to have settled',
                  null => sent ? 'Pending settlement · tap to show the QR again' : 'Pending settlement',
                }),
                onTap: v.tx != null
                    ? () => _copyTx(v.tx!)
                    // Re-showing beats re-signing: a second voucher for one purchase would settle twice.
                    : sent && pending
                        ? () => showVoucher(context, _store, v.voucher)
                        : null,
              );
            },
          ),
        ),
      ]),
    );
  }
}
