import 'package:flutter/material.dart';

import 'src/ar_meshy_page.dart';

void main() {
  runApp(const GenaiApp());
}

class GenaiApp extends StatelessWidget {
  const GenaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Genai AR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F8CFF)),
        useMaterial3: true,
      ),
      home: const ARMeshyPage(),
    );
  }
}
