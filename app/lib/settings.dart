import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  static const _urlKey = 'server_url';
  static const _deckKey = 'deck_name';

  Future<String> serverUrl() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_urlKey) ?? 'http://192.168.1.12:8080';
  }

  Future<String> deckName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_deckKey) ?? '';
  }

  Future<void> save({required String serverUrl, required String deckName}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_urlKey, serverUrl.trim());
    await p.setString(_deckKey, deckName.trim());
  }
}
