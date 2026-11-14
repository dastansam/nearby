import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearby/screens/topup.dart';
import 'package:nearby/voucher/payment.dart';

void main() {
  const account = '9f96ce959911f0c81f57ae2d1400be9299078ef2c81a33ab4cb55fa64ddb43c6';

  // The address shown is where a person sends real money. It must be one that pays THIS phone's
  // account inside intents.near, in USDC, and returns anything left over to the same place: a
  // request that named another account or kind would hand the top-up to someone else.
  test('the address asked for pays this phone, in USDC, inside intents.near', () async {
    late Map<String, dynamic> asked;
    final quote = await requestTopUp(MockClient((request) async {
      expect((request.method, request.url.path), ('POST', '/v0/quote'));
      asked = jsonDecode(request.body);
      return http.Response(
          jsonEncode({
            'quote': {'depositAddress': 'd' * 64, 'amountIn': '173172488476693114741389', 'amountOut': '500000'}
          }),
          201);
    }), account, '500000', now: DateTime.utc(2026, 11, 14, 21));

    expect(asked['dry'], false, reason: 'a dry quote has no address to send to');
    expect((asked['recipient'], asked['recipientType']), (account, 'INTENTS'));
    expect((asked['refundTo'], asked['refundType']), (account, 'INTENTS'));
    expect((asked['swapType'], asked['amount'], asked['destinationAsset']), ('EXACT_OUTPUT', '500000', usdcToken));
    expect((asked['originAsset'], asked['depositType']), ('nep141:wrap.near', 'ORIGIN_CHAIN'));
    expect(asked['deadline'], '2026-11-14T22:00:00.000Z');
    expect(quote.depositAddress, 'd' * 64);
  });

  // Sending less than the swap needs gets the money returned, not swapped. A person copies the
  // figure on screen, so it is rounded up, never down.
  test('the NEAR to send is rounded up to a thousandth', () {
    TopUpQuote of(String yocto) => TopUpQuote(depositAddress: 'd', yoctoNear: BigInt.parse(yocto), usdc: '1');
    expect(of('173172488476693114741389').near, '0.174');
    expect(of('1000000000000000000000000').near, '1.000');
    expect(of('1000000000000000000000001').near, '1.001');
  });

  // An address with no amount, or an error dressed as an answer, must not reach the screen.
  test('an answer without an address or an amount is refused, in the service\'s own words', () async {
    Future<void> answer(Object body, int status) => requestTopUp(
        MockClient((_) async => http.Response(body is String ? body : jsonEncode(body), status)), account, '1');
    await expectLater(answer({'message': 'Amount is too low'}, 400),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'Amount is too low')));
    await expectLater(answer({'quote': {'depositAddress': 'd' * 64}}, 201), throwsStateError);
    await expectLater(answer({'quote': {'amountIn': '5'}}, 201), throwsStateError);
    await expectLater(answer('<html>bad gateway</html>', 502), throwsStateError);
  });

  test('the status is the service\'s own word', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters['depositAddress'], 'abc');
      return http.Response(jsonEncode({'status': 'PROCESSING'}), 200);
    });
    expect(await topUpStatus(client, 'abc'), 'PROCESSING');
  });
}
