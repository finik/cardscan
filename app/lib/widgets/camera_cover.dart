import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Full-bleed preview that keeps the camera aspect (no vertical squash).
class CameraCover extends StatelessWidget {
  const CameraCover({super.key, required this.controller});
  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final preview = controller.value.previewSize;
    if (preview == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    // previewSize is the sensor buffer (usually landscape). Give the
    // FittedBox a concrete portrait box so CameraPreview is not 0×0.
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: preview.height,
          height: preview.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

/// Largest 5:7 card rect that fits in [bounds].
Rect cardFrameIn(Size bounds, {double margin = 16}) {
  final maxW = (bounds.width - margin * 2).clamp(1.0, bounds.width);
  final maxH = (bounds.height - margin * 2).clamp(1.0, bounds.height);
  const aspect = 5 / 7;
  double w, h;
  if (maxW / maxH > aspect) {
    h = maxH;
    w = h * aspect;
  } else {
    w = maxW;
    h = w / aspect;
  }
  return Rect.fromCenter(
    center: Offset(bounds.width / 2, bounds.height / 2),
    width: w,
    height: h,
  );
}

class CardHoleOverlay extends StatelessWidget {
  const CardHoleOverlay({super.key, required this.hole});
  final Rect hole;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _HolePainter(hole), size: Size.infinite);
  }
}

class _HolePainter extends CustomPainter {
  _HolePainter(this.hole);
  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Path()..addRect(Offset.zero & size);
    final cut = Path()..addRRect(RRect.fromRectXY(hole, 10, 10));
    canvas.drawPath(
      Path.combine(PathOperation.difference, overlay, cut),
      Paint()..color = const Color(0xFF000000),
    );
    canvas.drawRRect(
      RRect.fromRectXY(hole, 10, 10),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_HolePainter old) => old.hole != hole;
}
