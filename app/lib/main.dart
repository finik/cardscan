import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'screens/setup_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CardScanApp());
}

class CardScanApp extends StatefulWidget {
  const CardScanApp({super.key});

  @override
  State<CardScanApp> createState() => _CardScanAppState();
}

class _CardScanAppState extends State<CardScanApp> {
  final AppState _state = AppState();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _state.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Card Scan',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20)),
        useMaterial3: true,
      ),
      home: _ready
          ? SetupScreen(state: _state)
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}
