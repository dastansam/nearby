import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'gateway.dart';
import 'mesh/gossip.dart';
import 'mesh/multipeer_transport.dart';
import 'mesh/nearby_transport.dart';
import 'mesh/transport.dart';
import 'screens/pay.dart';
import 'screens/receive.dart';
import 'store.dart';
import 'theme.dart';
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
        theme: nearbyTheme(Brightness.light),
        darkTheme: nearbyTheme(Brightness.dark),
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
    // Each platform's own offline radio; the two do not speak to each other.
    final Transport radio = Platform.isIOS ? MultipeerTransport() : NearbyTransport();
    final gossip = Gossip(radio, _store, onChange: () {
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

  Future<void> _copy(String text, String said) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  /// Shows a settled payment's transaction on the explorer, inside the app.
  Future<void> _openTx(String tx) async {
    final link = 'https://nearblocks.io/txns/$tx';
    try {
      if (await launchUrl(Uri.parse(link), mode: LaunchMode.inAppBrowserView)) return;
    } catch (_) {
      // No browser to hand it to: the link is still worth having.
    }
    await _copy(link, 'Could not open the explorer. Link copied.');
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
    final scheme = Theme.of(context).colorScheme;
    final gateway = _gateway, attested = _attested;
    final online = gateway != null && gateway.problem == null;
    final stale = attested != null && isStale(attested, DateTime.now());
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // No app bar here to do it: keep the clock and the airplane icon readable on either background.
      value: scheme.brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 28), children: [
            Row(children: [
              Text('NearBy',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -1, color: scheme.onSurface)),
              const Spacer(),
              if (gateway != null) _Pill(online ? 'Online' : 'Offline', online ? scheme.primary : scheme.secondary),
            ]),
            const SizedBox(height: 18),
            if (relayerKey.isNotEmpty) ...[
              Panel(
                color: scheme.primaryContainer,
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
                onTap: _refreshBalance,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('OFFLINE BALANCE',
                        style: labelStyle(context, color: scheme.onPrimaryContainer.withValues(alpha: 0.72))),
                    const Spacer(),
                    Icon(Icons.refresh, size: 18, color: scheme.onPrimaryContainer.withValues(alpha: 0.72)),
                  ]),
                  const SizedBox(height: 14),
                  Amount(attested == null || stale ? '—' : formatUsdc(_budget.toString()),
                      size: 60, color: scheme.onPrimaryContainer),
                  const SizedBox(height: 12),
                  Text(
                    attested == null
                        ? 'Go online once to load it. Payees accept payments only against it.'
                        : stale
                            ? 'Out of date. Go online, then tap to refresh.'
                            : 'As of ${TimeOfDay.fromDateTime(attested.asOf.toLocal()).format(context)} · tap to refresh',
                    style: TextStyle(fontSize: 14, color: scheme.onPrimaryContainer.withValues(alpha: 0.8)),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
            ],
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _flow(() => pay(context, wallet, _store)),
                  icon: const Icon(Icons.north_east, size: 20),
                  label: const Text('Pay'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _flow(() => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => ReceiveScreen(accountId: wallet.accountId, store: _store)))),
                  icon: const Icon(Icons.south_west, size: 20),
                  label: const Text('Receive'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                _Fact(
                  icon: Icons.key_outlined,
                  title: 'Offline account',
                  detail: '${wallet.accountId.substring(0, 10)}…${wallet.accountId.substring(wallet.accountId.length - 8)}',
                  mono: true,
                  trailing: Icons.copy_outlined,
                  onTap: () => _copy(wallet.accountId, 'Account copied'),
                ),
                Divider(height: 1, indent: 54, color: scheme.outlineVariant),
                _Fact(
                  icon: Icons.hub_outlined,
                  title: _gossip == null ? 'Mesh off' : '${_gossip!.peerCount} phones connected',
                  detail: _gossip == null
                      ? (_meshError == null ? 'Starting' : 'QR payments still work. $_meshError')
                      : 'Carrying $_carried payments toward the internet',
                ),
                Divider(height: 1, indent: 54, color: scheme.outlineVariant),
                _Fact(
                  icon: Icons.cloud_outlined,
                  title: gateway == null ? 'No relayer in this build' : gateway.problem ?? 'Online: settling payments',
                  detail: gateway == null
                      ? 'Payments are signed and relayed, and settle from a phone that has one'
                      : '$_waiting payments waiting to settle',
                ),
              ]),
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text('ACTIVITY', style: labelStyle(context)),
            ),
            if (_vouchers.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                child: Text('No payments yet. Pay or receive one; it works with no signal.',
                    style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant)),
              ),
            for (final v in _vouchers) _payment(v),
          ]),
        ),
      ),
    );
  }

  Widget _payment(StoredVoucher v) {
    final scheme = Theme.of(context).colorScheme;
    final sent = v.kind == VoucherKind.sent, pending = canSettle(v, DateTime.now());
    final figure = formatUsdc(amountOf(v.voucher)).replaceFirst(' USDC', '');
    final tone = switch (v.outcome) {
      Outcome.settled => scheme.primary,
      Outcome.failed => scheme.error,
      null => pending ? scheme.secondary : scheme.onSurfaceVariant,
    };
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: v.tx != null
          ? () => _openTx(v.tx!)
          // Re-showing beats re-signing: a second voucher for one purchase would settle twice.
          : sent && pending
              ? () => showVoucher(context, _store, v.voucher)
              : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: tone.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(sent ? Icons.north_east : Icons.south_west, size: 20, color: tone),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(sent ? 'Sent' : 'Received',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const SizedBox(height: 2),
              Text(
                switch (v.outcome) {
                  Outcome.settled => v.tx == null ? 'Settled' : 'Settled · tap to see it on the explorer',
                  Outcome.failed => 'Did not settle',
                  // Another phone may have settled it in time; only the relayer can say.
                  null when !pending => 'Expired · not known to have settled',
                  null => sent ? 'Pending settlement · tap to show the QR again' : 'Pending settlement',
                },
                style: TextStyle(fontSize: 13, color: v.outcome == null ? scheme.onSurfaceVariant : tone),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Text('${sent ? '−' : '+'}$figure',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, fontFeatures: figures, color: scheme.onSurface)),
        ]),
      ),
    );
  }
}

/// A word with a dot: whether this phone can reach the relayer right now.
class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}

/// One line of the status sheet.
class _Fact extends StatelessWidget {
  final IconData icon;
  final String title, detail;
  final bool mono;
  final IconData? trailing;
  final VoidCallback? onTap;
  const _Fact(
      {required this.icon, required this.title, required this.detail, this.mono = false, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(children: [
          Icon(icon, size: 22, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const SizedBox(height: 2),
              Text(detail,
                  style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                      fontFamily: mono ? 'Menlo' : null,
                      fontFamilyFallback: mono ? const ['monospace'] : null)),
            ]),
          ),
          if (trailing != null) Icon(trailing, size: 18, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}
