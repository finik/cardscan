import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'card_pad_screen.dart';
import 'simple_capture_screen.dart';

class ModeMenuScreen extends StatefulWidget {
  const ModeMenuScreen({super.key, required this.state});
  final AppState state;

  @override
  State<ModeMenuScreen> createState() => _ModeMenuScreenState();
}

class _ModeMenuScreenState extends State<ModeMenuScreen> {
  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onChange);
    widget.state.refreshDeck();
    widget.state.pumpQueue();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final listing = s.listing;
    return Scaffold(
      appBar: AppBar(title: Text(s.deck)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusLine(state: s),
          const SizedBox(height: 12),
          Text(
            '${listing.fileCount} files on Mac'
            '${s.inFlight > 0 ? '  ·  ${s.inFlight} still processing' : ''}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _ModeTile(
            icon: Icons.inventory_2_outlined,
            title: 'Capture box',
            subtitle: '${listing.box.length} saved',
            onTap: () => _openSimple(CaptureCategory.box),
          ),
          _ModeTile(
            icon: Icons.style_outlined,
            title: 'Capture back',
            subtitle: listing.back.isEmpty ? 'none yet' : listing.back.join(', '),
            onTap: () => _openSimple(CaptureCategory.back),
          ),
          _ModeTile(
            icon: Icons.grid_view,
            title: 'Capture cards',
            subtitle: '${listing.completedCardCodes.length}/52',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CardPadScreen(state: s),
                ),
              );
            },
          ),
          _ModeTile(
            icon: Icons.add_photo_alternate_outlined,
            title: 'Capture extras',
            subtitle: '${listing.extras.length} saved (jokers, extras)',
            onTap: () => _openSimple(CaptureCategory.extra),
          ),
          SwitchListTile(
            value: s.debugUploads,
            onChanged: s.setDebugUploads,
            title: const Text('Upload originals'),
            subtitle: const Text('Keeps the full still and guide box under _debug so a bad crop can be diagnosed afterwards.'),
          ),
        ],
      ),
    );
  }

  void _openSimple(CaptureCategory category) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SimpleCaptureScreen(state: widget.state, category: category),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ok = state.reachable;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ok
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ok
            ? 'Mac reachable  ${state.healthRoot ?? state.serverUrl}'
            : 'Mac unreachable — shots queue locally',
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 32),
        title: Text(title, style: const TextStyle(fontSize: 18)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
