import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'warp.dart';

Future<WarpResult> captureToFrame({
  required CameraController controller,
  required GlobalKey viewKey,
  required GlobalKey frameKey,
  bool portrait = true,
}) async {
  final view = viewKey.currentContext?.findRenderObject() as RenderBox?;
  final frame = frameKey.currentContext?.findRenderObject() as RenderBox?;

  double left = 0, top = 0, right = 1, bottom = 1, vw = 1, vh = 1;
  if (view != null && frame != null && view.hasSize && frame.hasSize) {
    final origin = view.globalToLocal(frame.localToGlobal(Offset.zero));
    vw = view.size.width;
    vh = view.size.height;
    if (vw >= 1 && vh >= 1) {
      left = (origin.dx / vw).clamp(0.0, 1.0);
      top = (origin.dy / vh).clamp(0.0, 1.0);
      right = ((origin.dx + frame.size.width) / vw).clamp(0.0, 1.0);
      bottom = ((origin.dy + frame.size.height) / vh).clamp(0.0, 1.0);
      try {
        final fx = ((left + right) / 2).clamp(0.05, 0.95);
        final fy = ((top + bottom) / 2).clamp(0.05, 0.95);
        await controller.setFocusMode(FocusMode.auto);
        await controller.setFocusPoint(Offset(fx, fy));
        await controller.setExposurePoint(Offset(fx, fy));
        await Future<void>.delayed(const Duration(milliseconds: 180));
      } catch (_) {}
    }
  }

  final shot = await controller.takePicture();
  final bytes = Uint8List.fromList(await shot.readAsBytes());
  if (view == null || frame == null || vw < 1 || vh < 1) {
    return WarpResult(jpeg: bytes, warped: false, raw: bytes);
  }
  final args = <Object?, Object?>{
    'jpeg': Uint8List.fromList(bytes),
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'viewW': vw,
    'viewH': vh,
    'portrait': portrait,
  };
  final list = await compute(cropToFrameIsolate, args);
  return WarpResult(
    jpeg: list[0] as Uint8List,
    warped: list[1] as bool,
    raw: bytes,
    overlayJson: jsonEncode({
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'viewW': vw,
      'viewH': vh,
      'portrait': portrait,
    }),
  );
}
