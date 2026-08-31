import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../capture.dart';
import '../models.dart';
import '../warp.dart';
import '../widgets/camera_cover.dart';
import '../widgets/still_camera.dart';

class CardPadScreen extends StatefulWidget {
  const CardPadScreen({super.key, required this.state});
  final AppState state;

  @override
  State<CardPadScreen> createState() => _CardPadScreenState();
}

class _CardPadScreenState extends State<CardPadScreen> {
  String _suit = 'S';
  String _rank = 'A';
  bool _shooting = false;
  bool _flash = false;
  final _viewKey = GlobalKey();
  final _frameKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onChange);
    widget.state.refreshDeck();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Set<String> get _done => widget.state.listing.completedCardCodes;

  Future<void> _capture(CameraController cam, String rank) async {
    if (_shooting || cam.value.isTakingPicture) return;
    setState(() => _rank = rank);
    final code = '$rank$_suit';
    HapticFeedback.selectionClick();
    setState(() {
      _shooting = true;
      _flash = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (mounted) setState(() => _flash = false);
    try {
      final result = await captureToFrame(
        controller: cam,
        viewKey: _viewKey,
        frameKey: _frameKey,
      );
      if (!mounted) return;
      unawaited(_send(code, result.jpeg));
      unawaited(_sendDebug(code, result));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<void> _send(String code, Uint8List jpeg, {bool replace = false, String? filename}) async {
    filename ??= '$code.jpg';
    try {
      final ok = await widget.state.uploadNow(
        category: CaptureCategory.card,
        jpeg: jpeg,
        filename: filename,
        replace: replace,
      );
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok.path), duration: const Duration(milliseconds: 900)),
      );
    } on UploadExists catch (e) {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already on Mac'),
          content: Text('${e.path} exists. Replace it, or keep both?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Keep both')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'replace'), child: const Text('Replace')),
          ],
        ),
      );
      if (choice == 'replace') {
        await _send(code, jpeg, replace: true, filename: '$code.jpg');
      } else if (choice == 'keep') {
        final name = e.suggested != null ? basenameOfPath(e.suggested!) : '${code}_2.jpg';
        await _send(code, jpeg, filename: name);
      }
    } on UploadFailure catch (e) {
      if (e.network) {
        widget.state.markUnreachable();
        await widget.state.enqueueFailed(
          category: CaptureCategory.card,
          jpeg: jpeg,
          filename: filename,
          replace: replace,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Queued — Mac unreachable')),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _sendDebug(String code, WarpResult result) async {
    final raw = result.raw;
    if (raw == null) return;
    try {
      await widget.state.api.upload(
        deck: widget.state.deck,
        category: CaptureCategory.debug,
        jpeg: raw,
        filename: '$code.src.jpg',
        replace: true,
      );
      final json = result.overlayJson;
      if (json != null) {
        await widget.state.api.upload(
          deck: widget.state.deck,
          category: CaptureCategory.debug,
          jpeg: utf8.encode(json),
          filename: '$code.json',
          replace: true,
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final n = _done.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: StillCamera(
        builder: (context, cam) {
          return LayoutBuilder(builder: (context, constraints) {
            final inset = MediaQuery.paddingOf(context);
            const shutterH = 96.0;
            final topH = inset.top + 48;
            final bottomH = inset.bottom + shutterH;
            final frameArea = Size(
              constraints.maxWidth,
              (constraints.maxHeight - topH - bottomH).clamp(80.0, constraints.maxHeight),
            );
            final hole = cardFrameIn(frameArea, margin: 10).shift(Offset(0, topH));
            return Stack(
              fit: StackFit.expand,
              children: [
                KeyedSubtree(key: _viewKey, child: CameraCover(controller: cam)),
                if (_flash)
                  const IgnorePointer(
                    child: ColoredBox(color: Color(0x88FFFFFF)),
                  ),
                CardHoleOverlay(hole: hole),
                Positioned(
                  left: hole.left,
                  top: hole.top,
                  width: hole.width,
                  height: hole.height,
                  child: KeyedSubtree(key: _frameKey, child: const SizedBox.expand()),
                ),
                Positioned(
                  left: hole.left,
                  top: hole.top,
                  width: hole.width,
                  height: hole.height,
                  child: Column(
                    children: [
                      const SizedBox(height: 6),
                      _SuitRow(
                        selected: _suit,
                        onSelect: (s) => setState(() => _suit = s),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
                          child: _RankPad(
                            suit: _suit,
                            rank: _rank,
                            done: _done,
                            onSelect: (r) => _capture(cam, r),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: inset.top,
                  child: _TopBar(
                    title: '${widget.state.deck}  $n/52',
                    reachable: widget.state.reachable,
                    onBack: () => Navigator.pop(context),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: inset.bottom + 8,
                  child: Center(
                    child: SizedBox(
                      width: 88,
                      height: 88,
                      child: FilledButton(
                        onPressed: null,
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          disabledBackgroundColor: Colors.white24,
                          disabledForegroundColor: Colors.black38,
                        ),
                        child: const Icon(Icons.camera_alt, size: 36),
                      ),
                    ),
                  ),
                ),
              ],
            );
          });
        },
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.reachable,
    required this.onBack,
  });
  final String title;
  final bool reachable;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          Expanded(
            child: Text(
              reachable ? title : '$title  ·  Mac unreachable',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SuitRow extends StatelessWidget {
  const _SuitRow({required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    const labels = {
      'S': ('♠', 'S', Color(0xFFE0E0E0)),
      'H': ('♥', 'H', Color(0xFFFF6B6B)),
      'D': ('♦', 'D', Color(0xFFFF6B6B)),
      'C': ('♣', 'C', Color(0xFFE0E0E0)),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      child: Row(
        children: suits.map((s) {
          final meta = labels[s]!;
          final on = selected == s;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: SizedBox(
                height: 40,
                child: TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: on ? meta.$3.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.35),
                    foregroundColor: on ? Colors.black : meta.$3,
                    side: BorderSide(color: meta.$3, width: on ? 0 : 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => onSelect(s),
                  child: Text('${meta.$1} ${meta.$2}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _RankPad extends StatelessWidget {
  const _RankPad({
    required this.suit,
    required this.rank,
    required this.done,
    required this.onSelect,
  });
  final String suit;
  final String rank;
  final Set<String> done;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['2', '3', '4', '5'],
      ['6', '7', '8', '9'],
      ['10', '', '', ''],
      ['J', 'Q', 'K', 'A'],
    ];
    return Column(
      children: rows.map((row) {
        return Expanded(
          child: Row(
            children: row.map((r) {
              if (r.isEmpty) {
                return const Expanded(child: SizedBox.shrink());
              }
              final code = '$r$suit';
              final isDone = done.contains(code);
              final selected = rank == r;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Material(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.85)
                        : isDone
                            ? const Color(0x992E7D32)
                            : const Color(0x55000000),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.55),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: InkWell(
                      onTap: () => onSelect(r),
                      borderRadius: BorderRadius.circular(8),
                      child: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              r,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: selected ? Colors.black : Colors.white,
                              ),
                            ),
                            if (isDone) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.check, color: selected ? Colors.black : Colors.white, size: 16),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}
