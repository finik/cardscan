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

  int get pendingCount => _jobs.length;
  List<PendingJob> get jobs => List.unmodifiable(_jobs);

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
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final path = '${dir.path}/$id.jpg';
    File(path).writeAsBytesSync(jpeg);
    final job = PendingJob(
      id: id,
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

  Future<void> pump(CardApi api, {void Function()? onChanged}) async {
    if (_pumping) return;
    _pumping = true;
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
          await api.upload(
            deck: job.deck,
            category: cat,
            jpeg: file.readAsBytesSync(),
            filename: job.filename,
            replace: job.replace,
          );
          try {
            file.deleteSync();
          } catch (_) {}
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
        } on UploadExists {
          // File is already on the server; drop the pending copy.
          try {
            file.deleteSync();
          } catch (_) {}
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
        } on UploadFailure catch (e) {
          if (e.network) break;
          try {
            file.deleteSync();
          } catch (_) {}
          _jobs.removeAt(0);
          await _save();
          onChanged?.call();
        }
      }
    } finally {
      _pumping = false;
    }
  }
}
