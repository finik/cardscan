import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class StillCamera extends StatefulWidget {
  const StillCamera({super.key, required this.builder});

  final Widget Function(BuildContext context, CameraController controller)
      builder;

  @override
  State<StillCamera> createState() => _StillCameraState();
}

class _StillCameraState extends State<StillCamera> {
  CameraController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final cameras = await availableCameras();
      // ignore: avoid_print
      print('cscan cameras: ${cameras.map((c) => '${c.name}/${c.lensDirection.name}').join(', ')}');
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        // The card occupies roughly two thirds of the frame, so a 1080p still
        // gave a ~680x950 card region that then had to be scaled *up* to the
        // 1000x1400 output — the sharpness ceiling. ultraHigh (~2160p) makes
        // that region large enough to downsample into the output instead.
        // _viewRectToQuad now handles a still whose aspect differs from the
        // preview's, so this no longer has to match 16:9 by luck.
        ResolutionPreset.ultraHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      // ignore: avoid_print
      final preview = controller.value.previewSize;
      print('cscan using ${back.name} '
          'preview=${preview?.width.round()}x${preview?.height.round()}');
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}
      // Focus is left alone here: the capture screens call primeFocus() once
      // they know where the guide is, and lock it there.
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Camera error: $_error', textAlign: TextAlign.center),
        ),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return widget.builder(context, c);
  }
}
