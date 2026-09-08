import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../capture.dart';
import '../models.dart';
import '../widgets/camera_cover.dart';
import '../widgets/still_camera.dart';

class SimpleCaptureScreen extends StatefulWidget {
  const SimpleCaptureScreen({
    super.key,
    required this.state,
    required this.category,
  });

  final AppState state;
  final CaptureCategory category;

  @override
  State<SimpleCaptureScreen> createState() => _SimpleCaptureScreenState();
}

class _SimpleCaptureScreenState extends State<SimpleCaptureScreen> {
  bool _busy = false;
  bool _focusing = false;
  bool _focusLocked = false;
  final _viewKey = GlobalKey();
  final _frameKey = GlobalKey();

  String get _title {
    switch (widget.category) {
      case CaptureCategory.box:
        return 'Box';
      case CaptureCategory.back:
        return 'Back';
      case CaptureCategory.extra:
        return 'Extras';
      case CaptureCategory.card:
        return 'Card';
      case CaptureCategory.debug:
        return 'Debug';
    }
  }

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  FrameGeometry? _geometry(CameraController cam) => readFrameGeometry(
        viewKey: _viewKey,
        frameKey: _frameKey,
        controller: cam,
        portrait: widget.category != CaptureCategory.box,
      );

  /// Focus once when the preview is laid out, so the shutter path is only
  /// takePicture().
  void _primeOnce(CameraController cam) {
    if (_focusLocked || _focusing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refocus(cam));
  }

  Future<void> _refocus(CameraController cam) async {
    if (_focusing) return;
    final geometry = _geometry(cam);
    if (geometry == null) return;
    setState(() => _focusing = true);
    await primeFocus(cam, geometry);
    if (!mounted) return;
    setState(() {
      _focusing = false;
      _focusLocked = true;
    });
  }

  Future<void> _shutter(CameraController cam) async {
    if (_busy || cam.value.isTakingPicture) return;

    // Only back.jpg has a fixed name that can collide; box and extras are
    // numbered by the server. Ask before the shutter so nothing has to
    // interrupt the operator once the shot is on its way.
    var replace = false;
    String? filename;
    if (widget.category == CaptureCategory.back &&
        widget.state.listing.back.contains('back.jpg')) {
      final choice = await _backConflict();
      if (choice == null || !mounted) return;
      replace = choice == 'replace';
      if (choice == 'keep') filename = 'back_2.jpg';
    }

    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    try {
      final geometry = _geometry(cam);
      final shot = await captureStill(controller: cam);
      HapticFeedback.mediumImpact();
      unawaited(widget.state.pipeline.submit(
        srcPath: shot.path,
        geometry: geometry,
        deck: widget.state.deck,
        category: widget.category,
        filename: filename,
        replace: replace,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _backConflict() {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('back.jpg exists'),
        content: const Text('Replace the existing back, or save as back_2.jpg?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Save as next')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'replace'), child: const Text('Replace')),
        ],
      ),
    );
  }

  String get _statusLine {
    if (_focusing) return 'Focusing…';
    final n = widget.state.inFlight;
    if (n > 0) return '$n processing…';
    if (!widget.state.reachable) return 'Mac unreachable — shots are queued';
    return 'Line it up in the frame';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StillCamera(
        builder: (context, cam) {
          _primeOnce(cam);
          return LayoutBuilder(builder: (context, constraints) {
            final inset = MediaQuery.paddingOf(context);
            final hole = cardFrameIn(
              Size(constraints.maxWidth, constraints.maxHeight),
              margin: 12,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                KeyedSubtree(key: _viewKey, child: CameraCover(controller: cam)),
                CardHoleOverlay(hole: hole),
                Positioned(
                  left: hole.left,
                  top: hole.top,
                  width: hole.width,
                  height: hole.height,
                  child: KeyedSubtree(key: _frameKey, child: const SizedBox.expand()),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: inset.top,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          '$_title · ${widget.state.deck}',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        onPressed: _focusing ? null : () => _refocus(cam),
                        tooltip: 'Refocus on the guide',
                        icon: Icon(
                          _focusing ? Icons.hourglass_top : Icons.center_focus_strong,
                          color: _focusing ? Colors.white38 : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: inset.bottom,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        _LastShotThumb(path: widget.state.pipeline.lastWarpedPath),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _statusLine,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        SizedBox(
                          width: 76,
                          height: 76,
                          child: FilledButton(
                            onPressed: _busy ? null : () => _shutter(cam),
                            style: FilledButton.styleFrom(shape: const CircleBorder()),
                            child: Icon(
                              Icons.camera_alt,
                              size: 32,
                              color: _busy ? Colors.white38 : Colors.white,
                            ),
                          ),
                        ),
                      ],
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

class _LastShotThumb extends StatelessWidget {
  const _LastShotThumb({required this.path});
  final String? path;

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p == null || !File(p).existsSync()) {
      return const SizedBox(width: 48, height: 68);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(p),
        key: ValueKey(p),
        width: 48,
        height: 68,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }
}
