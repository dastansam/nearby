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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (wallet, store) = await (Wallet.load(), VoucherStore.open()).wait;
    _store = store;
    await _reloadVouchers();
    if (mounted) setState(() => _wallet = wallet);
  }

  Future<void> _reloadVouchers() async {
    final vouchers = await _store.all();
    if (mounted) setState(() => _vouchers = vouchers);
  }

  Future<void> _refreshSalt() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _wallet!.refreshSalt();
      if (mounted) setState(() {});
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Refresh failed, are you online? ($e)')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = _wallet;
    if (wallet == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('NearBy')),
      body: Column(children: [
        ListTile(
          title: const Text('Offline account'),
          subtitle: SelectableText(wallet.accountId),
        ),
        ListTile(
          title: Text(wallet.salt == null ? 'Not ready to pay offline' : 'Ready to pay offline'),
          subtitle: Text(wallet.salt == null ? 'Go online and tap refresh' : 'Salt ${wallet.salt}'),
          trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshSalt),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: () async {
                  await pay(context, wallet, _store);
                  await _reloadVouchers();
                },
                child: const Text('Pay'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.tonal(
                onPressed: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ReceiveScreen(accountId: wallet.accountId, store: _store)));
                  await _reloadVouchers();
                },
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
                subtitle: const Text('Pending settlement'),
              );
            },
          ),
        ),
      ]),
    );
  }
}
