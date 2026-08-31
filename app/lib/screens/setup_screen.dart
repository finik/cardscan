import 'package:flutter/material.dart';

import '../app_state.dart';
import 'mode_menu_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _url = TextEditingController();
  final _deck = TextEditingController();
  bool _healthOk = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _url.text = widget.state.serverUrl;
    _deck.text = widget.state.deck;
  }

  @override
  void dispose() {
    _url.dispose();
    _deck.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = 'Checking…';
    });
    await widget.state.saveSetup(_url.text, _deck.text);
    final ok = await widget.state.checkHealth();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _healthOk = ok;
      _status = ok
          ? 'OK  ${widget.state.healthRoot ?? ''}'
          : 'Fail  ${widget.state.lastError ?? ''}';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Server OK' : 'Health check failed')),
    );
  }

  Future<void> _continue() async {
    await widget.state.saveSetup(_url.text, _deck.text);
    await widget.state.refreshDeck();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ModeMenuScreen(state: widget.state)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canGo = _healthOk && _deck.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Card Scan')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => setState(() => _healthOk = false),
            decoration: const InputDecoration(
              labelText: 'Server base URL',
              hintText: 'http://192.168.1.12:8080',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _busy ? null : _test,
            child: const Text('Test connection'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
          const SizedBox(height: 24),
          TextField(
            controller: _deck,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Deck name',
              hintText: 'Vikings',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: canGo && !_busy ? _continue : null,
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}
