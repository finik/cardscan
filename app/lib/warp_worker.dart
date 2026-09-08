import 'dart:async';
import 'dart:isolate';

import 'warp.dart';

/// Long-lived isolate that warps stills.
///
/// `compute()` spawns a fresh isolate per call, which on a 12 MP still costs
/// isolate startup plus a full copy of the JPEG in and out. This keeps one
/// worker alive for the session and passes file paths instead of bytes.
class WarpWorker {
  Isolate? _isolate;
  SendPort? _send;
  Future<SendPort>? _starting;

  Future<SendPort> _ensure() {
    final ready = _send;
    if (ready != null) return Future.value(ready);
    return _starting ??= _spawn();
  }

  Future<SendPort> _spawn() async {
    final ready = ReceivePort();
    try {
      _isolate = await Isolate.spawn(
        _warpWorkerMain,
        ready.sendPort,
        debugName: 'warp-worker',
      );
      final port = await ready.first as SendPort;
      _send = port;
      return port;
    } finally {
      ready.close();
      _starting = null;
    }
  }

  /// Warp `args['srcPath']` into `args['outPath']`; returns `[outPath, warped]`.
  Future<List<dynamic>> crop(Map<Object?, Object?> args) async {
    final port = await _ensure();
    final reply = ReceivePort();
    try {
      port.send([reply.sendPort, args]);
      final res = await reply.first;
      if (res is List && res.length == 2 && res[0] == _errorTag) {
        throw StateError(res[1] as String);
      }
      return res as List<dynamic>;
    } catch (_) {
      // A dead worker cannot be reused; drop it so the next job respawns.
      dispose();
      rethrow;
    } finally {
      reply.close();
    }
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _starting = null;
  }
}

const _errorTag = '_warp_error';

void _warpWorkerMain(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((message) {
    final msg = message as List;
    final reply = msg[0] as SendPort;
    final args = (msg[1] as Map).cast<Object?, Object?>();
    try {
      reply.send(cropFileToFrame(args));
    } catch (e) {
      reply.send([_errorTag, e.toString()]);
    }
  });
}
