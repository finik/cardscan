import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'settings.dart';
import 'upload_queue.dart';

class AppState extends ChangeNotifier {
  AppState({Settings? settings, UploadQueue? queue})
      : _settings = settings ?? Settings(),
        queue = queue ?? UploadQueue();

  final Settings _settings;
  final UploadQueue queue;

  String serverUrl = '';
  String deck = '';
  bool reachable = false;
  String? healthRoot;
  String? lastError;
  DeckListing listing = DeckListing.empty('');
  String? lastUploadedPath;
  String? lastLocalJpegPath;

  CardApi get api => CardApi(serverUrl);

  int get pendingCount => queue.pendingCount;

  Future<void> load() async {
    serverUrl = await _settings.serverUrl();
    deck = await _settings.deckName();
    await queue.load();
    notifyListeners();
  }

  Future<void> saveSetup(String url, String deckName) async {
    serverUrl = url.trim();
    deck = deckName.trim();
    await _settings.save(serverUrl: serverUrl, deckName: deck);
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
    await queue.pump(api, onChanged: notifyListeners);
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
