const ranks = ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'];
const suits = ['S', 'H', 'D', 'C'];

enum CaptureCategory { card, box, back, extra, debug }

extension CaptureCategoryX on CaptureCategory {
  String get apiValue => name;
}

class Health {
  Health({required this.ok, required this.root});
  final bool ok;
  final String root;
}

class DeckListing {
  DeckListing({
    required this.deck,
    required this.cards,
    required this.back,
    required this.box,
    required this.extras,
  });

  final String deck;
  final List<String> cards;
  final List<String> back;
  final List<String> box;
  final List<String> extras;

  factory DeckListing.empty(String deck) => DeckListing(
        deck: deck,
        cards: const [],
        back: const [],
        box: const [],
        extras: const [],
      );

  factory DeckListing.fromJson(Map<String, dynamic> json) {
    List<String> strs(String key) =>
        ((json[key] as List?) ?? const []).map((e) => e.toString()).toList();
    return DeckListing(
      deck: json['deck'] as String? ?? '',
      cards: strs('cards'),
      back: strs('back'),
      box: strs('box'),
      extras: strs('extras'),
    );
  }

  int get fileCount =>
      cards.length + back.length + box.length + extras.length;

  Set<String> get completedCardCodes {
    final out = <String>{};
    final re = RegExp(r'^(A|[2-9]|10|J|Q|K)[SHDC]', caseSensitive: false);
    for (final name in cards) {
      final m = re.matchAsPrefix(name);
      if (m != null) out.add(m.group(0)!.toUpperCase());
    }
    return out;
  }
}

class UploadOk {
  UploadOk({required this.path, required this.bytes});
  final String path;
  final int bytes;
}

class UploadExists implements Exception {
  UploadExists({required this.path, this.suggested});
  final String path;
  final String? suggested;
  @override
  String toString() => 'exists $path';
}

class UploadFailure implements Exception {
  UploadFailure(this.message, {this.network = false});
  final String message;
  final bool network;
  @override
  String toString() => message;
}

class PendingJob {
  PendingJob({
    required this.id,
    required this.filePath,
    required this.deck,
    required this.category,
    this.filename,
    this.replace = false,
  });

  final String id;
  final String filePath;
  final String deck;
  final String category;
  final String? filename;
  final bool replace;

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'deck': deck,
        'category': category,
        'filename': filename,
        'replace': replace,
      };

  factory PendingJob.fromJson(Map<String, dynamic> json) => PendingJob(
        id: json['id'] as String,
        filePath: json['filePath'] as String,
        deck: json['deck'] as String,
        category: json['category'] as String,
        filename: json['filename'] as String?,
        replace: json['replace'] as bool? ?? false,
      );
}

String? cardCodeFromFilename(String filename) {
  final re = RegExp(r'^(A|[2-9]|10|J|Q|K)[SHDC]', caseSensitive: false);
  final m = re.matchAsPrefix(filename);
  return m?.group(0)?.toUpperCase();
}

String basenameOfPath(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}
