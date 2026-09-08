import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'capture.dart';
import 'models.dart';
import 'upload_queue.dart';
import 'warp_worker.dart';

/// A still that has been taken and is waiting to be warped.
class _WarpJob {
  _WarpJob({
    required this.id,
    required this.srcPath,
    required this.geometry,
    required this.deck,
    required this.category,
    required this.filename,
    required this.replace,
    required this.debug,
    required this.debugName,
  });

  final String id;
  final String srcPath;
  final FrameGeometry? geometry;
  final String deck;
  final CaptureCategory category;
  final String? filename;
  final bool replace;
  final bool debug;
  final String? debugName;
}

/// Everything that happens after the shutter: warp, then upload.
///
/// The capture screens hand a still to [submit] and return immediately, so the
/// next card can be shot while this one is still being processed. Warping runs
/// one-at-a-time in a persistent isolate (a 12 MP decode is memory-hungry, and
/// several at once would thrash), and uploading runs as an independent loop
/// over the durable [UploadQueue], so a slow network never stalls the warps.
class CapturePipeline extends ChangeNotifier {
  CapturePipeline({
    required this.queue,
    required this.apiFor,
    this.onDrained,
    this.onUnreachable,
  });

  final UploadQueue queue;
  final CardApi Function() apiFor;

  /// Called when an upload could not reach the Mac. Nothing is lost — the job
  /// stays on disk and the pipeline retries on its own.
  final void Function()? onUnreachable;

  /// Called when nothing is left to warp or upload — a good moment to refresh
  /// the deck listing once, instead of after every single card.
  final Future<void> Function()? onDrained;

  final WarpWorker _worker = WarpWorker();
  final List<_WarpJob> _warping = [];
  bool _draining = false;
  bool _uploading = false;
  Timer? _retry;
  static const _retryDelay = Duration(seconds: 5);

  /// A copy of the most recent warped card, kept for the on-screen thumbnail.
  /// The queued file itself is deleted once it reaches the Mac.
  String? lastWarpedPath;
  String? lastError;

  /// Stills taken but not yet warped, plus files warped but not yet uploaded.
  int get inFlight => _warping.length + queue.pendingCount;
  int get warpingCount => _warping.length;

  /// Take ownership of a still. Returns as soon as the job is recorded.
  Future<void> submit({
    required String srcPath,
    required FrameGeometry? geometry,
    required String deck,
    required CaptureCategory category,
    String? filename,
    bool replace = false,
    bool debug = false,
    String? debugName,
  }) async {
    _warping.add(_WarpJob(
      id: UploadQueue.newJobId(),
      srcPath: srcPath,
      geometry: geometry,
      deck: deck,
      category: category,
      filename: filename,
      replace: replace,
      debug: debug,
      debugName: debugName,
    ));
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_warping.isNotEmpty) {
        final job = _warping.first;
        try {
          await _process(job);
        } catch (e) {
          lastError = '$e';
        }
        _warping.removeAt(0);
        notifyListeners();
        unawaited(_pumpUploads());
      }
    } finally {
      _draining = false;
    }
    await _maybeDrained();
  }

  Future<void> _process(_WarpJob job) async {
    final dir = await queue.stagingDir();
    final outPath = '${dir.path}/${job.id}.jpg';
    final geometry = job.geometry;

    if (geometry == null) {
      // No usable guide geometry — keep the still as shot.
      File(job.srcPath).copySync(outPath);
    } else {
      try {
        final res = await _worker.crop({
          'srcPath': job.srcPath,
          'outPath': outPath,
          ...geometry.toArgs(),
        });
        assert(res[0] == outPath);
      } catch (e) {
        lastError = 'warp failed: $e';
        File(job.srcPath).copySync(outPath);
      }
    }
    _keepPreview(outPath, dir.path, job.id);

    await queue.enqueueFile(
      path: outPath,
      deck: job.deck,
      category: job.category,
      filename: job.filename,
      replace: job.replace,
    );

    if (job.debug && geometry != null && job.debugName != null) {
      await _enqueueDebug(job, geometry);
    }
    try {
      File(job.srcPath).deleteSync();
    } catch (_) {}
  }

  void _keepPreview(String outPath, String dirPath, String id) {
    final previous = lastWarpedPath;
    final preview = '$dirPath/preview_$id.jpg';
    try {
      File(outPath).copySync(preview);
      lastWarpedPath = preview;
      if (previous != null) File(previous).deleteSync();
    } catch (_) {}
  }

  Future<void> _enqueueDebug(_WarpJob job, FrameGeometry geometry) async {
    try {
      await queue.enqueue(
        jpeg: File(job.srcPath).readAsBytesSync(),
        deck: job.deck,
        category: CaptureCategory.debug,
        filename: '${job.debugName}.src.jpg',
        replace: true,
      );
      await queue.enqueue(
        jpeg: utf8.encode(geometry.toOverlayJson()),
        deck: job.deck,
        category: CaptureCategory.debug,
        filename: '${job.debugName}.json',
        replace: true,
      );
    } catch (_) {}
  }

  Future<void> _pumpUploads() async {
    if (_uploading) return;
    _uploading = true;
    var ok = true;
    try {
      ok = await queue.pump(apiFor(), onChanged: notifyListeners);
    } catch (e) {
      lastError = '$e';
      ok = false;
    } finally {
      _uploading = false;
      notifyListeners();
    }
    if (!ok) {
      onUnreachable?.call();
      _scheduleRetry();
    }
    await _maybeDrained();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(_retryDelay, () {
      if (queue.pendingCount > 0) unawaited(_pumpUploads());
    });
  }

  /// Retry whatever is still queued (called when the Mac comes back).
  Future<void> pumpUploads() => _pumpUploads();

  Future<void> _maybeDrained() async {
    if (_draining || _uploading || inFlight > 0) return;
    await onDrained?.call();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _worker.dispose();
    super.dispose();
  }
}
