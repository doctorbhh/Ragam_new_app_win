import 'dart:convert';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';

class TrackReplacementHelper {
  /// Normalize a string by removing parenthetical clauses (e.g. "(feat. ...)", "[Remix]"),
  /// punctuation, and redundant whitespace.
  static String normalize(String? value) {
    if (value == null || value.trim().isEmpty) return '';
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Returns all lookup keys that can identify [track].
  static List<String> getLookupKeys(Track track) {
    final keys = <String>{};
    if (track.id.trim().isNotEmpty) {
      final id = track.id.trim();
      keys.add(id);
      if (id.contains('::')) {
        keys.add(id.split('::').last.trim());
      }
    }

    final rawTitle = track.title.trim().toLowerCase();
    final rawArtist = track.artists.firstOrNull?.name.trim().toLowerCase() ?? '';
    if (rawTitle.isNotEmpty) {
      if (rawArtist.isNotEmpty) {
        keys.add('$rawTitle:::$rawArtist');
      }
      keys.add(rawTitle);
    }

    final normTitle = normalize(track.title);
    final normArtist = normalize(track.artists.firstOrNull?.name);
    if (normTitle.isNotEmpty) {
      if (normArtist.isNotEmpty) {
        keys.add('$normTitle:::$normArtist');
      }
      keys.add(normTitle);
    }

    return keys.toList(growable: false);
  }

  /// Looks up a replacement ID for [track] from [map].
  static String? findReplacementId(Map<String, dynamic> map, Track track) {
    final keys = getLookupKeys(track);
    for (final k in keys) {
      if (map.containsKey(k)) {
        final val = map[k];
        if (val is String && val.trim().isNotEmpty) {
          return val.trim();
        }
      }
    }
    return null;
  }

  /// Loads the replacements map from settings.
  static Future<Map<String, dynamic>> loadReplacementsMap([SettingsDAO? dao]) async {
    try {
      final settingsDao = dao ?? SettingsDAO(DBProvider.db);
      final str = await settingsDao.getSettingStr(SettingKeys.trackReplacements);
      if (str != null && str.isNotEmpty) {
        return jsonDecode(str) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  /// Saves a replacement mapping for [originalTrack] to [newReplacementId].
  static Future<void> saveReplacement(
    Track originalTrack,
    String newReplacementId, [
    SettingsDAO? dao,
  ]) async {
    final settingsDao = dao ?? SettingsDAO(DBProvider.db);
    final map = await loadReplacementsMap(settingsDao);

    final keys = getLookupKeys(originalTrack);
    for (final k in keys) {
      map[k] = newReplacementId;
    }

    await settingsDao.putSettingStr(
      SettingKeys.trackReplacements,
      jsonEncode(map),
    );
  }

  /// Applies replacement to a track if mapped, preserving all original metadata.
  static Track applyReplacementToTrack(Track track, Map<String, dynamic> map) {
    final newId = findReplacementId(map, track);
    if (newId != null && newId != track.id) {
      return Track(
        id: newId,
        title: track.title,
        artists: track.artists,
        album: track.album,
        durationMs: track.durationMs,
        thumbnail: track.thumbnail,
        url: null, // Force re-resolve with new ID
        isExplicit: track.isExplicit,
        lyrics: track.lyrics,
      );
    }
    return track;
  }
}
