import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/screens/receive.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // The spec's main hand-off: the payer's phone sends the voucher by radio and the payee's
  // screen turns to "Paid" without anyone scanning. It must do so for the right customer only.
  testWidgets('a voucher arriving over the mesh marks its own request as paid, and no other', (tester) async {
    final store = (await tester.runAsync(() => VoucherStore.open(inMemoryDatabasePath)))!;
    await tester.pumpWidget(MaterialApp(home: ReceiveScreen(accountId: 'merchant.near', store: store)));
    await tester.enterText(find.byType(TextField), '2.50');
    await tester.tap(find.text('Show QR'));
    await tester.pump();
    final qr = tester.widget<QrImageView>(find.byType(QrImageView)).key as ValueKey<String>;
    final request = PaymentRequest.decode(qr.value)!;

    /// A voucher signed for [signedFor] comes in over the mesh; then the screen gets time to check it.
    /// The screen's checks mix real database I/O with the test's fake clock, so both are stepped.
    Future<Map<String, dynamic>> arrive(PaymentRequest signedFor) async {
      final voucher = (await tester.runAsync(() async {
        final v = await signPayment(await Ed25519().newKeyPair(), signedFor);
        await store.put(v, VoucherKind.relayed, hops: 1);
        return v;
      }))!;
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      return voucher;
    }

    Future<VoucherKind> kindOf(Map<String, dynamic> voucher) async => (await tester.runAsync(() async =>
            (await store.all()).singleWhere((s) => voucherKey(s.voucher) == voucherKey(voucher)).kind))!;

    // Another customer's payment of the same amount to the same merchant, for an earlier request.
    final other = await arrive(PaymentRequest(
        receiverId: request.receiverId, token: request.token, amount: request.amount, id: newRequestId()));
    expect(find.text('Paid, pending settlement'), findsNothing);

    final ours = await arrive(request);
    expect(find.text('Paid, pending settlement'), findsOneWidget);
    expect(await kindOf(ours), VoucherKind.received);
    expect(await kindOf(other), VoucherKind.relayed, reason: 'still only carried, not counted as this sale');

    // With a signal, the gateway settles the payment at once (gateway.dart). The screen is still up,
    // and the chain's word is the one check the offline guards cannot make: the merchant should see it
    // before the customer leaves. The other customer's settlement is not this sale's.
    await tester.runAsync(() => store.setOutcome(other, Outcome.settled, tx: 'tx0', block: 1));
    await tester.pump();
    expect(find.text('Paid, pending settlement'), findsOneWidget);
    await tester.runAsync(() => store.setOutcome(ours, Outcome.failed));
    await tester.pump();
    expect(find.text('Paid, but the chain refused it'), findsOneWidget);
  });
}
