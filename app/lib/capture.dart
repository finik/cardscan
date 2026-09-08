import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Where the on-screen guide sits inside the camera preview, in preview
/// fractions. Read on the UI isolate at shutter time and carried along with the
/// still so the warp can happen later, off the capture path.
class FrameGeometry {
  const FrameGeometry({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.viewW,
    required this.viewH,
    required this.previewW,
    required this.previewH,
    required this.portrait,
  });

  final double left, top, right, bottom, viewW, viewH;

  /// The preview stream's size as laid out on screen (portrait). The still can
  /// have a different aspect ratio, and therefore a different field of view,
  /// than the preview the guide was measured against — the warp needs both to
  /// map the guide onto the captured frame.
  final double previewW, previewH;

  final bool portrait;

  double get centerX => ((left + right) / 2).clamp(0.05, 0.95);
  double get centerY => ((top + bottom) / 2).clamp(0.05, 0.95);

  Map<String, Object?> toArgs() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'viewW': viewW,
        'viewH': viewH,
        'previewW': previewW,
        'previewH': previewH,
        'portrait': portrait,
      };

  String toOverlayJson() => jsonEncode(toArgs());
}

/// Measure the guide against the preview. Returns null when the render tree is
/// not laid out yet, in which case the still is kept whole.
FrameGeometry? readFrameGeometry({
  required GlobalKey viewKey,
  required GlobalKey frameKey,
  required CameraController controller,
  bool portrait = true,
}) {
  final view = viewKey.currentContext?.findRenderObject() as RenderBox?;
  final frame = frameKey.currentContext?.findRenderObject() as RenderBox?;
  if (view == null || frame == null || !view.hasSize || !frame.hasSize) {
    return null;
  }
  final vw = view.size.width;
  final vh = view.size.height;
  if (vw < 1 || vh < 1) return null;
  // previewSize is the sensor buffer, usually landscape; CameraCover lays it
  // out rotated, so swap it here to match.
  final preview = controller.value.previewSize;
  final origin = view.globalToLocal(frame.localToGlobal(Offset.zero));
  return FrameGeometry(
    previewW: preview?.height ?? 0,
    previewH: preview?.width ?? 0,
    left: (origin.dx / vw).clamp(0.0, 1.0),
    top: (origin.dy / vh).clamp(0.0, 1.0),
    right: ((origin.dx + frame.size.width) / vw).clamp(0.0, 1.0),
    bottom: ((origin.dy + frame.size.height) / vh).clamp(0.0, 1.0),
    viewW: vw,
    viewH: vh,
    portrait: portrait,
  );
}

/// Focus and meter on the guide once, then lock.
///
/// Measured on a Pixel 10 Pro, doing this per shot cost 580-5335 ms in the
/// three platform-channel calls alone — the single biggest source of shutter
/// lag, and enough for a hand to still be in frame. The guide never moves and
/// the card is always the same distance away, so this runs once when the
/// preview appears and again only when the operator asks to refocus.
Future<void> primeFocus(
  CameraController controller,
  FrameGeometry geometry,
) async {
  final sw = Stopwatch()..start();
  try {
    final point = Offset(geometry.centerX, geometry.centerY);
    await controller.setFocusMode(FocusMode.auto);
    await controller.setFocusPoint(point);
    await controller.setExposurePoint(point);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    // Locked, or CameraX cancels the metering region after a few seconds and
    // drifts back to continuous autofocus.
    await controller.setFocusMode(FocusMode.locked);
    // ignore: avoid_print
    print('cscan PRIME ${sw.elapsedMilliseconds}ms');
  } catch (e) {
    // ignore: avoid_print
    print('cscan PRIME failed after ${sw.elapsedMilliseconds}ms: $e');
  }
}

/// Take the still. This is the only thing the operator waits for: focus is
/// already locked, so nothing here touches the camera beyond the shutter.
Future<XFile> captureStill({required CameraController controller}) async {
  final sw = Stopwatch()..start();
  final shot = await controller.takePicture();
  // ignore: avoid_print
  print('cscan SHUTTER ${sw.elapsedMilliseconds}ms');
  return shot;
}
