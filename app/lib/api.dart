import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models.dart';

class CardApi {
  CardApi(String baseUrl) : baseUrl = _normalize(baseUrl);

  final String baseUrl;
  static const _ua = 'card-scan/1.0';

  static String _normalize(String raw) {
    var s = raw.trim();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  http.Client _client() {
    final inner = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 5)
      ..userAgent = _ua;
    return IOClient(inner);
  }

  Future<Health> health() async {
    final client = _client();
    try {
      final resp = await client
          .get(Uri.parse('$baseUrl/health'), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        throw UploadFailure('health ${resp.statusCode}');
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Health(ok: json['ok'] == true, root: json['root'] as String? ?? '');
    } on UploadFailure {
      rethrow;
    } catch (e) {
      throw UploadFailure('unreachable: $e', network: true);
    } finally {
      client.close();
    }
  }

  Future<DeckListing> deck(String name) async {
    final client = _client();
    try {
      final encoded = Uri.encodeComponent(name);
      final resp = await client
          .get(Uri.parse('$baseUrl/deck/$encoded'), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        throw UploadFailure('deck ${resp.statusCode}');
      }
      return DeckListing.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
    } on UploadFailure {
      rethrow;
    } catch (e) {
      throw UploadFailure('unreachable: $e', network: true);
    } finally {
      client.close();
    }
  }

  /// Move a file to the deck's `_trash` so the card can be re-shot.
  Future<void> deleteFile({required String deck, required String filename}) async {
    final client = _client();
    try {
      final resp = await client
          .post(
            Uri.parse('$baseUrl/delete'),
            headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
            body: jsonEncode({'deck': deck, 'filename': filename}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return;
      String message;
      try {
        message = (jsonDecode(resp.body) as Map<String, dynamic>)['error'] as String? ??
            'delete ${resp.statusCode}';
      } catch (_) {
        message = 'delete ${resp.statusCode}';
      }
      throw UploadFailure(message);
    } on UploadFailure {
      rethrow;
    } catch (e) {
      throw UploadFailure('network: $e', network: true);
    } finally {
      client.close();
    }
  }

  Future<UploadOk> upload({
    required String deck,
    required CaptureCategory category,
    required List<int> jpeg,
    String? filename,
    bool replace = false,
  }) async {
    final client = _client();
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/upload'))
        ..headers['User-Agent'] = _ua
        ..fields['deck'] = deck
        ..fields['category'] = category.apiValue
        ..fields['replace'] = replace ? 'true' : 'false'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          jpeg,
          filename: filename ?? 'shot.jpg',
        ));
      if (filename != null && filename.isNotEmpty) {
        req.fields['filename'] = filename;
      }
      final streamed = await client.send(req).timeout(const Duration(seconds: 30));
      final body = await streamed.stream.bytesToString();
      Map<String, dynamic> json;
      try {
        json = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        throw UploadFailure('bad response ${streamed.statusCode}');
      }
      if (streamed.statusCode == 200 && json['ok'] == true) {
        return UploadOk(
          path: json['path'] as String,
          bytes: json['bytes'] as int? ?? jpeg.length,
        );
      }
      if (streamed.statusCode == 409) {
        throw UploadExists(
          path: json['path'] as String? ?? filename ?? '',
          suggested: json['suggested'] as String?,
        );
      }
      throw UploadFailure(json['error'] as String? ?? 'upload failed');
    } on UploadExists {
      rethrow;
    } on UploadFailure {
      rethrow;
    } catch (e) {
      throw UploadFailure('network: $e', network: true);
    } finally {
      client.close();
    }
  }
}
