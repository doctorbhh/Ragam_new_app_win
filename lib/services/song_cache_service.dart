import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:developer';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:isar_community/isar.dart';

class SongCacheService {
  static final SongCacheService _instance = SongCacheService._internal();
  factory SongCacheService() => _instance;
  SongCacheService._internal();

  final Set<String> _downloading = {};
  final StreamController<String> _cacheUpdateController =
      StreamController<String>.broadcast();

  Stream<String> get onCacheUpdated => _cacheUpdateController.stream;

  // ── Playlist-Level Auto-Cache ──────────────────────────────────────────────
  Set<String>? _autoCachePlaylists;
  String? currentPlaybackPlaylist;
  final StreamController<String> _autoCacheUpdateController =
      StreamController<String>.broadcast();

  Stream<String> get onAutoCachePlaylistsChanged =>
      _autoCacheUpdateController.stream;

  Future<Set<String>> getAutoCachePlaylists() async {
    if (_autoCachePlaylists != null) return _autoCachePlaylists!;
    try {
      final raw = await SettingsDAO(DBProvider.db)
          .getSettingStr(SettingKeys.autoCachePlaylists);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List)
            .map((e) => e.toString().trim().toLowerCase())
            .where((s) => s.isNotEmpty)
            .toSet();
        _autoCachePlaylists = list;
        return _autoCachePlaylists!;
      }
    } catch (e) {
      log('Failed to load autoCachePlaylists: $e', name: 'SongCacheService');
    }
    _autoCachePlaylists = <String>{};
    return _autoCachePlaylists!;
  }

  Future<bool> isPlaylistAutoCacheEnabled(String playlistName) async {
    final clean = playlistName.trim().toLowerCase();
    if (clean.isEmpty) return false;
    final set = await getAutoCachePlaylists();
    return set.contains(clean);
  }

  Future<void> setPlaylistAutoCache(String playlistName, bool enabled) async {
    final clean = playlistName.trim().toLowerCase();
    if (clean.isEmpty) return;

    final set = await getAutoCachePlaylists();
    if (enabled) {
      set.add(clean);
    } else {
      set.remove(clean);
    }
    _autoCachePlaylists = set;

    try {
      await SettingsDAO(DBProvider.db).putSettingStr(
        SettingKeys.autoCachePlaylists,
        jsonEncode(set.toList()),
      );
    } catch (e) {
      log('Failed to save autoCachePlaylists: $e', name: 'SongCacheService');
    }

    if (!_autoCacheUpdateController.isClosed) {
      _autoCacheUpdateController.add(playlistName);
    }
  }

  Future<bool> togglePlaylistAutoCache(String playlistName) async {
    final current = await isPlaylistAutoCacheEnabled(playlistName);
    await setPlaylistAutoCache(playlistName, !current);
    return !current;
  }

  Future<bool> shouldCacheTrack(String trackId,
      {String? activePlaylistName}) async {
    // 1. Check if active playlist (or passed playlist) has auto-cache enabled
    final targetPlaylist = activePlaylistName ?? currentPlaybackPlaylist;
    if (targetPlaylist != null &&
        targetPlaylist.trim().isNotEmpty &&
        targetPlaylist.trim().toLowerCase() != 'queue') {
      if (await isPlaylistAutoCacheEnabled(targetPlaylist)) {
        log('shouldCacheTrack: enabled via active playlist "$targetPlaylist" for $trackId',
            name: 'SongCacheService');
        return true;
      }
    }

    // 2. Check if track belongs to any library playlist with auto-cache enabled
    final enabled = await getAutoCachePlaylists();
    if (enabled.isEmpty) return false;

    try {
      final isar = await DBProvider.db;
      final track =
          await isar.trackDBs.filter().mediaIdEqualTo(trackId).findFirst();
      if (track != null) {
        final allPlaylists = await isar.playlistDBs.where().findAll();
        final matchingPlaylists = allPlaylists
            .where((p) => enabled.contains(p.name.trim().toLowerCase()))
            .toList();

        for (final pl in matchingPlaylists) {
          final count = await isar.playlistEntryDBs
              .filter()
              .playlistIdEqualTo(pl.id)
              .and()
              .track((q) => q.idEqualTo(track.id))
              .count();
          if (count > 0) {
            log('shouldCacheTrack: enabled via member playlist "${pl.name}" for $trackId',
                name: 'SongCacheService');
            return true;
          }
        }
      }
    } catch (e) {
      log('Error checking member playlist auto-cache in shouldCacheTrack: $e',
          name: 'SongCacheService');
    }

    return false;
  }

  void _notifyCacheUpdated(String trackId) {
    if (!_cacheUpdateController.isClosed) {
      _cacheUpdateController.add(trackId);
    }
  }

  Future<String> get _cacheDirPath async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/song_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  String _getFileName(String trackId) {
    final bytes = utf8.encode(trackId);
    final base64Str = base64Url.encode(bytes).replaceAll('=', '');
    return '$base64Str.cache';
  }

  String _getMetaFileName(String trackId) {
    final bytes = utf8.encode(trackId);
    final base64Str = base64Url.encode(bytes).replaceAll('=', '');
    return '$base64Str.meta';
  }

  Future<File?> getCachedFile(String trackId) async {
    final path = await _cacheDirPath;
    final file = File('$path/${_getFileName(trackId)}');
    if (await file.exists() && await file.length() > 0) {
      return file;
    }
    return null;
  }

  Future<void> cacheStream(String trackId, String url,
      {Map<String, String>? headers, Track? trackMetadata}) async {
    if (_downloading.contains(trackId)) return;

    final path = await _cacheDirPath;
    final tempFile = File('$path/${_getFileName(trackId)}.part');
    final finalFile = File('$path/${_getFileName(trackId)}');
    final metaFile = File('$path/${_getMetaFileName(trackId)}');

    // If metadata provided, persist it immediately so offline screen has track info
    if (trackMetadata != null) {
      try {
        await metaFile.writeAsString(jsonEncode(_trackToMap(trackMetadata)));
        await TrackDAO(DBProvider.db).upsertTrack(trackMetadata);
      } catch (e) {
        log('Failed to save metadata for track $trackId: $e',
            name: 'SongCacheService');
      }
    }

    if (await finalFile.exists()) {
      try {
        await finalFile.setLastModified(DateTime.now());
        _notifyCacheUpdated(trackId);
      } catch (_) {}
      return; // Already cached
    }

    _downloading.add(trackId);

    try {
      final request = http.Request('GET', Uri.parse(url));
      if (headers != null) request.headers.addAll(headers);

      final response = await http.Client().send(request);
      if (response.statusCode == 200) {
        final sink = tempFile.openWrite();
        await response.stream.pipe(sink);
        await sink.close();

        await tempFile.rename(finalFile.path);
        try {
          await finalFile.setLastModified(DateTime.now());
        } catch (_) {}
        log('Successfully cached track $trackId', name: 'SongCacheService');
        _notifyCacheUpdated(trackId);
      } else {
        log('Failed to cache track $trackId: Status code ${response.statusCode}',
            name: 'SongCacheService');
      }
    } catch (e) {
      log('Failed to cache track $trackId: $e', name: 'SongCacheService');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } finally {
      _downloading.remove(trackId);
    }
  }

  Future<List<String>> getCachedTrackIds() async {
    final path = await _cacheDirPath;
    final dir = Directory(path);
    if (!await dir.exists()) return [];

    final cacheFiles = <File>[];
    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (entity is File && entity.path.endsWith('.cache')) {
        cacheFiles.add(entity);
      }
    }

    // Sort newest cached files first based on file modification timestamp
    cacheFiles.sort((a, b) {
      DateTime timeA;
      DateTime timeB;
      try {
        timeA = a.lastModifiedSync();
      } catch (_) {
        timeA = DateTime.fromMillisecondsSinceEpoch(0);
      }
      try {
        timeB = b.lastModifiedSync();
      } catch (_) {
        timeB = DateTime.fromMillisecondsSinceEpoch(0);
      }
      return timeB.compareTo(timeA);
    });

    final List<String> trackIds = [];
    for (final file in cacheFiles) {
      final normalized = file.path.replaceAll('\\', '/');
      final fileName = normalized.split('/').last;
      final base64Str = fileName.replaceAll('.cache', '');
      var padded = base64Str;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      try {
        final bytes = base64Url.decode(padded);
        final trackId = utf8.decode(bytes);
        trackIds.add(trackId);
      } catch (e) {
        log('Failed to decode cache filename $base64Str: $e',
            name: 'SongCacheService');
      }
    }
    return trackIds;
  }

  Future<Track?> getCachedTrack(String trackId) async {
    try {
      // 1. Check database first
      final trackDao = TrackDAO(DBProvider.db);
      final fromDb = await trackDao.getTrackByMediaId(trackId);
      if (fromDb != null) return fromDb;

      // 2. Check local .meta file
      final path = await _cacheDirPath;
      final metaFile = File('$path/${_getMetaFileName(trackId)}');
      if (await metaFile.exists()) {
        final content = await metaFile.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        final track = _mapToTrack(map);
        // Save back to DB for future queries
        await trackDao.upsertTrack(track);
        return track;
      }
    } catch (e) {
      log('Error reading cached track $trackId: $e', name: 'SongCacheService');
    }

    // 3. Fallback so cached song is never omitted from offline screen
    return Track(
      id: trackId,
      title: trackId.contains('::') ? trackId.split('::').last : trackId,
      artists: const [],
      thumbnail: const Artwork(url: '', layout: ImageLayout.square),
      isExplicit: false,
    );
  }

  Future<int> getTotalCacheSizeBytes() async {
    final path = await _cacheDirPath;
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      final entities = await dir.list().toList();
      for (final entity in entities) {
        if (entity is File && entity.path.endsWith('.cache')) {
          total += await entity.length();
        }
      }
    } catch (e) {
      log('Failed to calculate cache size: $e', name: 'SongCacheService');
    }
    return total;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(0, suffixes.length - 1);
    final val = bytes / math.pow(1024, i);
    return '${val.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> deleteCache(String trackId) async {
    final path = await _cacheDirPath;
    final file = File('$path/${_getFileName(trackId)}');
    final metaFile = File('$path/${_getMetaFileName(trackId)}');
    if (await file.exists()) {
      await file.delete();
      log('Deleted cache for $trackId', name: 'SongCacheService');
    }
    if (await metaFile.exists()) {
      await metaFile.delete();
    }
    if (trackId.contains('::')) {
      final localOnly = trackId.split('::').last;
      final localFile = File('$path/${_getFileName(localOnly)}');
      final localMetaFile = File('$path/${_getMetaFileName(localOnly)}');
      if (await localFile.exists()) {
        await localFile.delete();
        log('Deleted cache for $localOnly', name: 'SongCacheService');
      }
      if (await localMetaFile.exists()) {
        await localMetaFile.delete();
      }
    }
    _notifyCacheUpdated(trackId);
  }

  Map<String, dynamic> _trackToMap(Track track) => {
        'id': track.id,
        'title': track.title,
        'artists':
            track.artists.map((a) => {'id': a.id, 'name': a.name}).toList(),
        'album': track.album != null
            ? {'id': track.album!.id, 'title': track.album!.title}
            : null,
        'durationMs': track.durationMs?.toString(),
        'thumbnail': track.thumbnail.url,
        'isExplicit': track.isExplicit,
      };

  Track _mapToTrack(Map<String, dynamic> map) => Track(
        id: map['id'] as String? ?? '',
        title: map['title'] as String? ?? '',
        artists: (map['artists'] as List?)
                ?.map((a) => ArtistSummary(
                      id: a['id'] as String? ?? '',
                      name: a['name'] as String? ?? '',
                    ))
                .toList() ??
            [],
        album: map['album'] != null
            ? AlbumSummary(
                id: map['album']['id'] as String? ?? '',
                title: map['album']['title'] as String? ?? '',
                artists: const [],
              )
            : null,
        durationMs: map['durationMs'] != null
            ? BigInt.tryParse(map['durationMs'].toString())
            : null,
        thumbnail: Artwork(
            url: map['thumbnail'] as String? ?? '',
            layout: ImageLayout.square),
        isExplicit: map['isExplicit'] as bool? ?? false,
      );
}
