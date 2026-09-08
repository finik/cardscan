import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  static const _urlKey = 'server_url';
  static const _deckKey = 'deck_name';
  static const _debugKey = 'debug_uploads';

  Future<String> serverUrl() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_urlKey) ?? 'http://192.168.1.12:8080';
  }

  Future<String> deckName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_deckKey) ?? '';
  }

  /// Upload the full-resolution original still and the guide geometry next to
  /// every card, under <deck>/_debug. On by default: without the original
  /// there is no way to work out after the fact why a crop went wrong, and
  /// that costs far more than the extra bytes.
  Future<bool> debugUploads() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_debugKey) ?? true;
  }

  Future<void> saveDebugUploads(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_debugKey, on);
  }

  Future<void> save({required String serverUrl, required String deckName}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_urlKey, serverUrl.trim());
    await p.setString(_deckKey, deckName.trim());
  }
}
