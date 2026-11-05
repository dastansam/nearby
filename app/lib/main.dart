import 'package:flutter/material.dart';

import 'screens/pay.dart';
import 'screens/receive.dart';
import 'store.dart';
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
  bool _busy = false; // a Pay or Receive flow is open; a second tap must not start another

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final wallet = await Wallet.load();
      _store = await VoucherStore.open();
      await _reloadVouchers();
      if (mounted) setState(() => _wallet = wallet);
    } catch (e) {
      // Never fall through to a fresh wallet: the stored key may hold the user's money.
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _flow(Future<void> Function() run) async {
    if (_busy) return;
    _busy = true;
    try {
      await run();
      await _reloadVouchers();
    } finally {
      _busy = false;
    }
  }

  Future<void> _reloadVouchers() async {
    final vouchers = await _store.all();
    if (mounted) setState(() => _vouchers = vouchers);
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
              return ListTile(
                leading: Icon(v.sent ? Icons.arrow_upward : Icons.arrow_downward),
                title: Text('${v.sent ? 'Sent' : 'Received'} ${formatUsdc(v.amount)}'),
                subtitle: Text(v.sent ? 'Pending settlement · tap to show the QR again' : 'Pending settlement'),
                // Re-showing beats re-signing: a second voucher for one purchase would settle twice.
                onTap: v.sent
                    ? () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => VoucherScreen(voucher: v.voucher)))
                    : null,
              );
            },
          ),
        ),
      ]),
    );
  }
}
