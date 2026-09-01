/// Settings, persisted as a JSON file in app-private storage.
///
/// Not shared_preferences. Every package this project has added for something
/// this small has cost more than it saved — one wanted an API level Google's
/// own tooling cannot install, another wanted a native CMake build to report a
/// directory path. This is a map, a file, and the MethodChannel we already have.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class Settings {
  static const _channel = MethodChannel('omi_capture/service');

  /// Where finished audio is sent. A `tailscale serve` URL by default, which
  /// works from any network the phone happens to be on and needs nothing opened
  /// on the host.
  String serverUrl;

  /// Silence the pendant for this long on a double press.
  int pauseMinutes;

  /// How long the pendant may be unreachable before the app says so out loud.
  int linkAlertMinutes;

  Settings({
    this.serverUrl = 'https://laptop-6r23fikn.tailaf1550.ts.net',
    this.pauseMinutes = 60,
    this.linkAlertMinutes = 5,
  });

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'pauseMinutes': pauseMinutes,
        'linkAlertMinutes': linkAlertMinutes,
      };

  static Settings fromJson(Map<String, dynamic> j) => Settings(
        serverUrl: (j['serverUrl'] as String?)?.trim().isNotEmpty == true
            ? (j['serverUrl'] as String).trim()
            : Settings().serverUrl,
        pauseMinutes: (j['pauseMinutes'] as num?)?.toInt() ?? 60,
        linkAlertMinutes: (j['linkAlertMinutes'] as num?)?.toInt() ?? 5,
      );

  static Future<File> _file() async {
    final base = await _channel.invokeMethod<String>('filesDir');
    return File('$base/settings.json');
  }

  static Future<Settings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return Settings();
      return Settings.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // A corrupt settings file must not stop the app recording. Defaults are
      // better than a crash loop.
      return Settings();
    }
  }

  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode(toJson()));
  }

  /// Rejects anything that is not an absolute http(s) URL, and strips a
  /// trailing slash so paths do not end up doubled.
  static String? validateUrl(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Required';
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Needs to look like https://host or http://host:port';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'Only http and https';
    }
    return null;
  }

  static String normaliseUrl(String value) {
    var v = value.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
