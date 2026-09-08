import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'models.dart';

class UploadQueue {
  UploadQueue();

  final List<PendingJob> _jobs = [];
  Directory? _dir;
  bool _pumping = false;

  static const maxAttempts = 3;

  /// Last server-side rejection, for the UI to show.
  String? lastError;

  int get pendingCount => _jobs.length;
  List<PendingJob> get jobs => List.unmodifiable(_jobs);

  /// Scans the server kept rejecting. Kept as files so nothing is lost; they
  /// can be re-uploaded by hand.
  Future<Directory> _failedDir() async {
    final dir = await _ensureDir();
    return Directory('${dir.path}/failed')..createSync(recursive: true);
  }

  Future<void> _setAside(PendingJob job) async {
    try {
      final dir = await _failedDir();
      final name = job.filename ?? '${job.id}.jpg';
      File(job.filePath).renameSync('${dir.path}/${job.id}-$name');
    } catch (_) {}
  }

  /// Directory the warp worker writes into, so a finished JPEG is already in
  /// the queue's storage and only has to be registered.
  Future<Directory> stagingDir() => _ensureDir();

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final root = await getApplicationSupportDirectory();
    _dir = Directory('${root.path}/pending')..createSync(recursive: true);
    return _dir!;
  }

  Future<void> load() async {
    final dir = await _ensureDir();
    final file = File('${dir.path}/queue.json');
    if (!file.existsSync()) return;
    try {
      final list = jsonDecode(file.readAsStringSync()) as List;
      _jobs
        ..clear()
        ..addAll(list.map((e) => PendingJob.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      _jobs.clear();
    }
  }

  Future<void> _save() async {
    final dir = await _ensureDir();
    final file = File('${dir.path}/queue.json');
    file.writeAsStringSync(jsonEncode(_jobs.map((j) => j.toJson()).toList()));
  }

  Future<PendingJob> enqueue({
    required List<int> jpeg,
    required String deck,
    required CaptureCategory category,
    String? filename,
    bool replace = false,
  }) async {
    final dir = await _ensureDir();
    final id = newJobId();
    final path = '${dir.path}/$id.jpg';
    File(path).writeAsBytesSync(jpeg);
    return enqueueFile(
      path: path,
      deck: deck,
      category: category,
      filename: filename,
      replace: replace,
      id: id,
    );
  }

  /// Register a file that is already on disk (written by the warp worker)
  /// without copying its bytes through memory.
  Future<PendingJob> enqueueFile({
    required String path,
    required String deck,
    required CaptureCategory category,
    String? filename,
    bool replace = false,
    String? id,
  }) async {
    final job = PendingJob(
      id: id ?? newJobId(),
      filePath: path,
      deck: deck,
      category: category.apiValue,
      filename: filename,
      replace: replace,
    );
    _jobs.add(job);
    await _save();
    return job;
  }

  static int _seq = 0;

  static String newJobId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_seq++}';

  /// Uploads everything queued. Returns false if it stopped early because the
  /// Mac was unreachable, leaving the remaining jobs on disk for a later try.
  Future<bool> pump(CardApi api, {void Function()? onChanged}) async {
    if (_pumping) return true;
    _pumping = true;
    var ok = true;
    try {
      while (_jobs.isNotEmpty) {
        final job = _jobs.first;
        final file = File(job.filePath);
        if (!file.existsSync()) {
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
          continue;
        }
        try {
          final cat = CaptureCategory.values.firstWhere((c) => c.name == job.category);
          final bytes = file.readAsBytesSync();
          try {
            await api.upload(
              deck: job.deck,
              category: cat,
              jpeg: bytes,
              filename: job.filename,
              replace: job.replace,
            );
          } on UploadExists catch (e) {
            // Nothing here can ask the operator anything — they have moved on
            // to the next card. Keep both rather than drop the shot; the
            // screens ask about replacing before the shutter, when it is still
            // a decision the operator is making.
            if (e.suggested == null) rethrow;
            await api.upload(
              deck: job.deck,
              category: cat,
              jpeg: bytes,
              filename: basenameOfPath(e.suggested!),
            );
          }
          try {
            file.deleteSync();
          } catch (_) {}
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
        } on UploadExists {
          // Already on the server under a name we cannot improve on.
          try {
            file.deleteSync();
          } catch (_) {}
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
        } on UploadFailure catch (e) {
          if (e.network) {
            ok = false;
            break;
          }
          // A server-side error (a 500 from a busy destination, say) is not a
          // reason to destroy the only copy of a scan. Retry a few times, then
          // set it aside on disk — never delete it.
          lastError = e.message;
          job.attempts += 1;
          await _save();
          onChanged?.call();
          if (job.attempts < maxAttempts) {
            ok = false;
            break;
          }
          await _setAside(job);
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
        }
      }
    } finally {
      _pumping = false;
    }
    return ok;
  }
}
