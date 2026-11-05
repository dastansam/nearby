import 'package:flutter/material.dart';

void main() => runApp(const MeshPayApp());

class MeshPayApp extends StatelessWidget {
  const MeshPayApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MeshPay',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('MeshPay')),
        body: const Center(child: Text('Pay · Receive · Outbox — coming on day 2')),
      );
}
