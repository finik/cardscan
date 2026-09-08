import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'pipeline.dart';
import 'settings.dart';
import 'upload_queue.dart';

class AppState extends ChangeNotifier {
  AppState({Settings? settings, UploadQueue? queue})
      : _settings = settings ?? Settings(),
        queue = queue ?? UploadQueue() {
    pipeline = CapturePipeline(
      queue: this.queue,
      apiFor: () => api,
      onDrained: _afterDrain,
      onUnreachable: markUnreachable,
    )..addListener(notifyListeners);
  }

  final Settings _settings;
  final UploadQueue queue;
  late final CapturePipeline pipeline;

  String serverUrl = '';
  String deck = '';
  bool reachable = false;
  String? healthRoot;
  String? lastError;
  DeckListing listing = DeckListing.empty('');
  String? lastUploadedPath;
  String? lastLocalJpegPath;
  bool debugUploads = false;

  CardApi get api => CardApi(serverUrl);

  int get pendingCount => queue.pendingCount;

  /// Stills still being warped plus files still waiting to upload.
  int get inFlight => pipeline.inFlight;

  Future<void> load() async {
    serverUrl = await _settings.serverUrl();
    deck = await _settings.deckName();
    debugUploads = await _settings.debugUploads();
    await queue.load();
    notifyListeners();
  }

  Future<void> saveSetup(String url, String deckName) async {
    serverUrl = url.trim();
    deck = deckName.trim();
    await _settings.save(serverUrl: serverUrl, deckName: deck);
    notifyListeners();
  }

  Future<void> setDebugUploads(bool on) async {
    debugUploads = on;
    await _settings.saveDebugUploads(on);
    notifyListeners();
  }

  Future<bool> checkHealth() async {
    lastError = null;
    try {
      final h = await api.health();
      reachable = h.ok;
      healthRoot = h.root;
    } catch (e) {
      reachable = false;
      lastError = e.toString();
    }
    notifyListeners();
    return reachable;
  }

  Future<void> refreshDeck() async {
    if (deck.isEmpty || !reachable) return;
    try {
      listing = await api.deck(deck);
      lastError = null;
      reachable = true;
    } catch (e) {
      reachable = false;
      lastError = e.toString();
    }
    notifyListeners();
  }

  Future<UploadOk> uploadNow({
    required CaptureCategory category,
    required List<int> jpeg,
    String? filename,
    bool replace = false,
  }) async {
    final result = await api.upload(
      deck: deck,
      category: category,
      jpeg: jpeg,
      filename: filename,
      replace: replace,
    );
    lastUploadedPath = result.path;
    await refreshDeck();
    return result;
  }

  Future<void> enqueueFailed({
    required CaptureCategory category,
    required List<int> jpeg,
    String? filename,
    bool replace = false,
  }) async {
    await queue.enqueue(
      jpeg: jpeg,
      deck: deck,
      category: category,
      filename: filename,
      replace: replace,
    );
    notifyListeners();
  }

  Future<void> pumpQueue() async {
    if (!reachable) {
      final ok = await checkHealth();
      if (!ok) return;
    }
    await pipeline.pumpUploads();
  }

  /// Called once the pipeline has nothing left, rather than after every card.
  Future<void> _afterDrain() async {
    if (!reachable) return;
    await refreshDeck();
  }

  /// Tick a rank the moment the shutter fires, so the pad shows it as shot
  /// while the warp and upload are still running.
  void markCardCapturedLocally(String code) {
    if (listing.completedCardCodes.contains(code)) return;
    listing = DeckListing(
      deck: listing.deck,
      cards: [...listing.cards, '$code.jpg'],
      back: listing.back,
      box: listing.box,
      extras: listing.extras,
    );
    notifyListeners();
  }

  /// Trash every file on the Mac for one card code (`2S.jpg`, `2S_2.jpg`, …)
  /// so the rank can be shot fresh.
  Future<void> deleteCard(String code) async {
    final names =
        listing.cards.where((n) => cardCodeFromFilename(n) == code).toList();
    for (final name in names) {
      await api.deleteFile(deck: deck, filename: name);
    }
    uncheckCardLocally(code);
    await refreshDeck();
  }

  void markUnreachable() {
    reachable = false;
    notifyListeners();
  }

  void uncheckCardLocally(String code) {
    listing = DeckListing(
      deck: listing.deck,
      cards: listing.cards
          .where((n) => cardCodeFromFilename(n) != code)
          .toList(),
      back: listing.back,
      box: listing.box,
      extras: listing.extras,
    );
    notifyListeners();
  }
}
