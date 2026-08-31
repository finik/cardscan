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
  Uint8List? _lastThumb;
  String? _lastPath;
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

  Future<void> _shutter(CameraController cam) async {
    if (_busy || cam.value.isTakingPicture) return;
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    try {
      final result = await captureToFrame(
        controller: cam,
        viewKey: _viewKey,
        frameKey: _frameKey,
        portrait: widget.category != CaptureCategory.box,
      );
      await _send(result.jpeg);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(Uint8List jpeg, {bool replace = false, String? filename}) async {
    try {
      if (widget.category == CaptureCategory.back &&
          widget.state.listing.back.contains('back.jpg') &&
          !replace &&
          filename == null) {
        final choice = await _backConflict();
        if (choice == null) return;
        replace = choice == 'replace';
        if (choice == 'keep') filename = 'back_2.jpg';
      }
      final ok = await widget.state.uploadNow(
        category: widget.category,
        jpeg: jpeg,
        filename: filename,
        replace: replace,
      );
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      setState(() {
        _lastThumb = jpeg;
        _lastPath = ok.path;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok.path)));
    } on UploadExists catch (e) {
      if (!mounted) return;
      final choice = await _existsDialog(e);
      if (choice == 'replace') {
        await _send(jpeg, replace: true, filename: filename ?? basenameOfPath(e.path));
      } else if (choice == 'keep' && e.suggested != null) {
        await _send(jpeg, filename: basenameOfPath(e.suggested!));
      }
    } on UploadFailure catch (e) {
      if (e.network) {
        widget.state.markUnreachable();
        await widget.state.enqueueFailed(
          category: widget.category,
          jpeg: jpeg,
          filename: filename,
          replace: replace,
        );
        if (mounted) {
          setState(() => _lastThumb = jpeg);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Queued — Mac unreachable')),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
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

  Future<String?> _existsDialog(UploadExists e) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('File exists'),
        content: Text('${e.path} already exists.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Keep both')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'replace'), child: const Text('Replace')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StillCamera(
        builder: (context, cam) {
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
                        if (_lastThumb != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(_lastThumb!, width: 48, height: 68, fit: BoxFit.cover),
                          )
                        else
                          const SizedBox(width: 48, height: 68),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _lastPath ?? 'Line it up in the frame',
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
