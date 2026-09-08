import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../capture.dart';
import '../models.dart';
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
  bool _focusing = false;
  bool _focusLocked = false;
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

  /// Focus once when the preview is laid out; after that the shutter path
  /// never touches focus.
  void _primeOnce(CameraController cam) {
    if (_focusLocked || _focusing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refocus(cam));
  }

  Future<void> _refocus(CameraController cam) async {
    if (_focusing) return;
    final geometry =
        readFrameGeometry(viewKey: _viewKey, frameKey: _frameKey, controller: cam);
    if (geometry == null) return;
    setState(() => _focusing = true);
    await primeFocus(cam, geometry);
    if (!mounted) return;
    setState(() {
      _focusing = false;
      _focusLocked = true;
    });
  }

  Future<void> _capture(CameraController cam, String rank) async {
    if (_shooting || cam.value.isTakingPicture) return;
    if (!_focusLocked) {
      // Priming takes seconds on this device; shooting through it produces
      // unfocused cards, so make the wait visible instead of silent.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Focusing…'), duration: Duration(milliseconds: 700)),
      );
      return;
    }
    final code = '$rank$_suit';

    // Ask before the shutter, not after the upload: by the time the upload
    // lands the operator is already shooting the next card, and a dialog then
    // would be both surprising and in the way. A conflict the listing did not
    // know about is kept as a second file rather than replacing anything.
    var replace = false;
    if (_done.contains(code)) {
      final choice = await _existsDialog(code);
      if (choice == null || !mounted) return;
      if (choice == 'delete') {
        await _delete(code);
        return;
      }
      replace = choice == 'replace';
    }

    setState(() {
      _rank = rank;
      _shooting = true;
      _flash = true;
    });
    HapticFeedback.selectionClick();
    Timer(const Duration(milliseconds: 60), () {
      if (mounted) setState(() => _flash = false);
    });

    try {
      final geometry =
          readFrameGeometry(viewKey: _viewKey, frameKey: _frameKey, controller: cam);
      final shot = await captureStill(controller: cam);
      HapticFeedback.mediumImpact();
      widget.state.markCardCapturedLocally(code);
      // Hand the still off and go: warping and uploading run in the
      // background, so the next rank can be shot right now.
      unawaited(widget.state.pipeline.submit(
        srcPath: shot.path,
        geometry: geometry,
        deck: widget.state.deck,
        category: CaptureCategory.card,
        filename: '$code.jpg',
        replace: replace,
        debug: widget.state.debugUploads,
        debugName: code,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<String?> _existsDialog(String code) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$code already shot'),
        content: Text('Replace $code.jpg on the Mac, keep both, or delete it?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('Delete'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Keep both')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'replace'), child: const Text('Replace')),
        ],
      ),
    );
  }

  /// Long-press a shot rank to throw it away and start over. The file is moved
  /// to the deck's `_trash` on the Mac, not unlinked.
  Future<void> _delete(String code) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $code?'),
        content: const Text('Moves it to _trash on the Mac so you can shoot it again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.state.deleteCard(code);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$code deleted'), duration: const Duration(milliseconds: 900)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _done.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: StillCamera(
        builder: (context, cam) {
          _primeOnce(cam);
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
                            enabled: _focusLocked,
                            onSelect: (r) => _capture(cam, r),
                            onDelete: (r) => _delete('$r$_suit'),
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
                    inFlight: widget.state.inFlight,
                    reachable: widget.state.reachable,
                    focusing: _focusing,
                    onBack: () => Navigator.pop(context),
                    onRefocus: () => _refocus(cam),
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
                        onPressed: _focusing ? null : () => _refocus(cam),
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          disabledBackgroundColor: Colors.white24,
                          disabledForegroundColor: Colors.black38,
                        ),
                        child: Icon(
                          _focusLocked ? Icons.center_focus_strong : Icons.camera_alt,
                          size: 36,
                        ),
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
    required this.inFlight,
    required this.reachable,
    required this.focusing,
    required this.onBack,
    required this.onRefocus,
  });
  final String title;
  final int inFlight;
  final bool reachable;
  final bool focusing;
  final VoidCallback onBack;
  final VoidCallback onRefocus;

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
          IconButton(
            onPressed: focusing ? null : onRefocus,
            tooltip: 'Refocus on the guide',
            icon: Icon(
              focusing ? Icons.hourglass_top : Icons.center_focus_strong,
              color: focusing ? Colors.white38 : Colors.white,
            ),
          ),
          if (inFlight > 0) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
            ),
            const SizedBox(width: 6),
            Text(
              '$inFlight',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(width: 10),
          ],
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
    required this.enabled,
    required this.onSelect,
    required this.onDelete,
  });
  final String suit;
  final String rank;
  final Set<String> done;
  final bool enabled;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onDelete;

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
                    color: !enabled
                        ? const Color(0x33000000)
                        : selected
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
                      onLongPress: isDone ? () => onDelete(r) : null,
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
