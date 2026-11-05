import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans one QR code and pops with its text.
class ScanScreen extends StatefulWidget {
  final String title;
  const ScanScreen({super.key, required this.title});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false; // onDetect keeps firing while the code is in view

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: MobileScanner(onDetect: (capture) {
          final value = capture.barcodes.firstOrNull?.rawValue;
          if (value == null || _done) return;
          _done = true;
          Navigator.pop(context, value);
        }),
      );
}

Future<String?> scanQr(BuildContext context, String title) =>
    Navigator.push<String>(context, MaterialPageRoute(builder: (_) => ScanScreen(title: title)));
