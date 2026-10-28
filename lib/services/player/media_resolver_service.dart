import 'dart:developer';

import 'package:Bloomee/core/events/global_event_bus.dart';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/plugins/errors/plugin_exceptions.dart';
import 'package:Bloomee/plugins/utils/media_id.dart';
import 'package:Bloomee/services/db/dao/download_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/plugin/plugin_service.dart';
import 'package:Bloomee/services/player/stream_quality_selector.dart';
import 'package:Bloomee/src/rust/api/plugin/commands.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';
import 'package:Bloomee/services/song_cache_service.dart';
import 'package:Bloomee/services/meta_resolver/track_replacement_helper.dart';

class ResolvedMediaSource {
  final Uri uri;
  final bool isOffline;
  final Map<String, String>? headers;

  const ResolvedMediaSource({
    required this.uri,
    required this.isOffline,
    this.headers,
  });
}

/// Resolves a [Track] into a playable [Uri].
///
/// Resolution order:
/// 1. Local downloaded file (offline).
/// 2. Plugin system — asks the owning plugin for stream URIs via [GetStreams].
class MediaResolverService {
  final DownloadDAO _downloadDao;
  final SettingsDAO _settingsDao;
  final PluginService _pluginService;

  MediaResolverService({
    required DownloadDAO downloadDao,
    required SettingsDAO settingsDao,
    required PluginService pluginService,
  })  : _downloadDao = downloadDao,
        _settingsDao = settingsDao,
        _pluginService = pluginService;

  /// Factory that creates its own DAO instances from [DBProvider.db].
  factory MediaResolverService.create(PluginService pluginService) {
    final trackDao = TrackDAO(DBProvider.db);
    final playlistDao = PlaylistDAO(DBProvider.db, trackDao);
    return MediaResolverService(
      downloadDao: DownloadDAO(DBProvider.db, trackDao, playlistDao),
      settingsDao: SettingsDAO(DBProvider.db),
      pluginService: pluginService,
    );
  }

  /// Resolve [track] into a playable URI.
  Future<ResolvedMediaSource> resolve(Track track,
      {String? activePlaylistName}) async {
    // 0. Intercept track if smart replaced
    try {
      final map = await TrackReplacementHelper.loadReplacementsMap(_settingsDao);
      final effectiveTrack = TrackReplacementHelper.applyReplacementToTrack(track, map);
      if (effectiveTrack.id != track.id) {
        log('MediaResolverService: Swapped replaced track ${track.id} -> ${effectiveTrack.id} (${track.title})',
            name: 'MediaResolverService');
        // Delete any obsolete cache of original track
        await SongCacheService().deleteCache(track.id);
        track = effectiveTrack;
      }
    } catch (e) {
      log('Error checking trackReplacements in MediaResolverService: $e',
          name: 'MediaResolverService');
    }

    // 1. Check for an offline/downloaded version.
    try {
      final down = await _downloadDao.getDownloadRecord(track.id);
      if (down != null) {
        log('Playing Offline: ${track.title}', name: 'MediaResolverService');
        return ResolvedMediaSource(
          uri: Uri.file('${down.filePath}/${down.fileName}'),
          isOffline: true,
        );
      }
    } catch (e) {
      log('Download check failed: $e', name: 'MediaResolverService');
      // Non-fatal — continue to online resolution
    }

    // 1.5 Check song cache
    try {
      final cached = await SongCacheService().getCachedFile(track.id);
      if (cached != null) {
        log('Playing from Cache: ${track.title}', name: 'MediaResolverService');
        return ResolvedMediaSource(
          uri: Uri.file(cached.path),
          isOffline: true,
        );
      }
    } catch (e) {
      log('Cache check failed: $e', name: 'MediaResolverService');
    }

    // 2. Plugin-based stream resolution.
    final parts = tryParseMediaId(track.id);
    if (parts == null) {
      GlobalEventBus.instance.emitError(
        AppError.malformedMediaId(rawId: track.id),
      );
      throw Exception(
        'Cannot resolve stream for "${track.title}" — '
        'malformed media ID: "${track.id}"',
      );
    }

    if (parts.pluginId == 'local') {
      throw Exception(
        'Local file not found for "${track.title}" — '
        'it may have been deleted or moved.',
      );
    }

    String resolvePluginId = parts.pluginId;
    String resolveLocalId = parts.localId;

    final loadedIds = _pluginService.getLoadedPlugins();
    log('Stream resolution starting. Original Plugin: ${parts.pluginId}, Local ID: ${parts.localId}. Loaded Plugins: $loadedIds', name: 'MediaResolverService');

    if (parts.pluginId == 'ytmusic') {
      log('Detected ytmusic. Is ytmusic native loaded? ${loadedIds.contains('ytmusic')}', name: 'MediaResolverService');
    }

    if (parts.pluginId == 'ytmusic') {
      // Prioritize 'youtube' or 'piped' for ytmusic streams since they share the same video ID format.
      final availablePlugins = await _pluginService.getAvailablePlugins();
      
      print('--- DEBUG: Stream Resolution for YT Music ---');
      print('Available plugins: ${availablePlugins.map((p) => p.manifest.id).toList()}');
      print('Loaded IDs: $loadedIds');
      
      var fallbackPlugin;
      try {
        // Find ytmusic first, then ytvideo/youtube/piped
        fallbackPlugin = availablePlugins.firstWhere(
          (p) => p.pluginType == PluginType.contentResolver && loadedIds.contains(p.manifest.id) && p.manifest.id.contains('ytmusic'),
          orElse: () => availablePlugins.firstWhere(
            (p) => p.pluginType == PluginType.contentResolver && 
                   loadedIds.contains(p.manifest.id) && 
                   (p.manifest.id.contains('ytvideo') || p.manifest.id.contains('youtube') || p.manifest.id.contains('piped')),
          ),
        );
      } catch (_) {
        fallbackPlugin = availablePlugins.firstWhere(
          (p) => p.pluginType == PluginType.contentResolver && 
                 loadedIds.contains(p.manifest.id) && 
                 !p.manifest.id.contains('spotify') && 
                 !p.manifest.id.contains('jisaavn'),
          orElse: () {
            print('--- DEBUG: No native content resolver found! ---');
            throw Exception('No native content resolver available for stream fallback.');
          },
        );
      }
      
      resolvePluginId = fallbackPlugin.manifest.id;
      resolveLocalId = parts.localId;
      print('--- DEBUG: Chose fallback plugin: $resolvePluginId with ID: $resolveLocalId ---');
      log('Direct YTMusic resolution using fallback plugin: $resolvePluginId for local ID: $resolveLocalId', name: 'MediaResolverService');
    } else if (parts.pluginId == 'spotify') {
      final artistNames = track.artists.map((a) => a.name).join(', ');
      log('Stream fallback: Searching for "${track.title} - $artistNames" to resolve stream', name: 'MediaResolverService');
      
      // Get all loaded plugins and find a content resolver that is NOT spotify/ytmusic
      final availablePlugins = await _pluginService.getAvailablePlugins();
      
      final fallbackPlugin = availablePlugins.firstWhere(
        (p) => p.pluginType == PluginType.contentResolver && loadedIds.contains(p.manifest.id) && p.manifest.id != 'spotify' && p.manifest.id != 'ytmusic',
        orElse: () => throw Exception('No native content resolver available for stream fallback.'),
      );
      
      log('Stream fallback chosen plugin: ${fallbackPlugin.manifest.id}', name: 'MediaResolverService');

      final searchResponse = await _pluginService.execute(
        pluginId: fallbackPlugin.manifest.id,
        request: PluginRequest.contentResolver(
          ContentResolverCommand.search(
            query: "${track.title} $artistNames".trim(),
            filter: ContentSearchFilter.track,
          ),
        ),
      );

      final fallbackTrackId = searchResponse.maybeWhen(
        search: (results) => results.items.firstOrNull?.maybeWhen(track: (t) => t.id, orElse: () => null),
        orElse: () => null,
      );
      
      log('Stream fallback search yielded ID: $fallbackTrackId', name: 'MediaResolverService');

      if (fallbackTrackId == null) {
        throw Exception('Stream fallback failed: Could not find matching track on ${fallbackPlugin.name}.');
      }

      final fallbackParts = tryParseMediaId(fallbackTrackId);
      if (fallbackParts == null) throw Exception('Stream fallback failed: Malformed ID from ${fallbackPlugin.name}');

      resolvePluginId = fallbackParts.pluginId;
      resolveLocalId = fallbackParts.localId;
    }

    log(
        'Resolving streams for "${track.title}" '
        '(plugin: $resolvePluginId, id: $resolveLocalId)',
        name: 'MediaResolverService');

    PluginResponse response;
    try {
      response = await _pluginService.execute(
        pluginId: resolvePluginId,
        request: PluginRequest.contentResolver(
          ContentResolverCommand.getStreams(id: resolveLocalId),
        ),
      );
    } on PluginException catch (e) {
      if (e is PluginNotLoadedException) {
        GlobalEventBus.instance.emitError(
          AppError.pluginNotLoaded(pluginId: resolvePluginId, mediaId: track.id),
        );
      } else {
        GlobalEventBus.instance.emitError(
          AppError.pluginError(
            pluginId: resolvePluginId,
            message: e.message,
          ),
        );
      }
      rethrow;
    }

    return response.when(
      streams: (streams) async {
        if (streams.isEmpty) {
          throw Exception('No streams returned for "${track.title}"');
        }

        final storedQuality = await _settingsDao.getSettingStr(
          SettingKeys.strmQuality,
        );
        final normalizedQuality = normalizeStoredStreamQualityLabel(
          storedQuality,
          fallback: AudioStreamQualityPreference.high.label,
        );
        if (storedQuality != normalizedQuality) {
          await _settingsDao.putSettingStr(
            SettingKeys.strmQuality,
            normalizedQuality,
          );
        }
        final preference = AudioStreamQualityPreferenceX.fromStored(
          normalizedQuality,
        );
        final selectedStream = StreamQualitySelector.selectPlaybackStream(
          streams,
          preference: preference,
        );
        final streamUrl = selectedStream?.url.trim();

        if (streamUrl == null || streamUrl.isEmpty) {
          throw Exception(
            'Streams returned for "${track.title}" contain no playable URL',
          );
        }

        final uri = Uri.tryParse(streamUrl);
        if (uri == null ||
            uri.scheme.isEmpty ||
            (uri.scheme != 'http' &&
                uri.scheme != 'https' &&
                uri.scheme != 'file')) {
          throw Exception(
            'Invalid stream URL for "${track.title}": $streamUrl',
          );
        }

        final headersMap = selectedStream == null
            ? null
            : streamHeadersToMap(selectedStream.headers);

        // Start caching in the background if enabled globally OR for this playlist/track
        final globalCache =
            await _settingsDao.getSettingBool(SettingKeys.cacheAudio) ?? true;
        final playlistCache = await SongCacheService().shouldCacheTrack(
          track.id,
          activePlaylistName: activePlaylistName ??
              SongCacheService().currentPlaybackPlaylist,
        );
        final shouldCache = globalCache || playlistCache;
        if (shouldCache) {
          SongCacheService().cacheStream(track.id, streamUrl,
              headers: headersMap, trackMetadata: track);
        }

        log('Resolved stream: $streamUrl', name: 'MediaResolverService');
        return ResolvedMediaSource(
          uri: uri,
          isOffline: false,
          headers: headersMap,
        );
      },
      trackDetails: (_) =>
          throw Exception('Unexpected response type: trackDetails'),
      albumDetails: (_) =>
          throw Exception('Unexpected response type: albumDetails'),
      artistDetails: (_) =>
          throw Exception('Unexpected response type: artistDetails'),
      playlistDetails: (_) =>
          throw Exception('Unexpected response type: playlistDetails'),
      search: (_) => throw Exception('Unexpected response type: search'),
      moreTracks: (_) =>
          throw Exception('Unexpected response type: moreTracks'),
      moreAlbums: (_) =>
          throw Exception('Unexpected response type: moreAlbums'),
      homeSections: (_) =>
          throw Exception('Unexpected response type: homeSections'),
      loadMoreItems: (_) =>
          throw Exception('Unexpected response type: loadMoreItems'),
      charts: (_) => throw Exception('Unexpected response type: charts'),
      chartDetails: (_) =>
          throw Exception('Unexpected response type: chartDetails'),
      segments: (_) => throw Exception('Unexpected response type: segments'),
      lyricsResult: (_) =>
          throw Exception('Unexpected response type: lyricsResult'),
      lyricsSearchResults: (_) =>
          throw Exception('Unexpected response type: lyricsSearchResults'),
      lyricsById: (_, __) =>
          throw Exception('Unexpected response type: lyricsById'),
      suggestions: (_) =>
          throw Exception('Unexpected response type: suggestions'),
      canHandle: (_) => throw Exception('Unexpected response type: canHandle'),
      collectionInfo: (_) =>
          throw Exception('Unexpected response type: collectionInfo'),
      importTracks: (_) =>
          throw Exception('Unexpected response type: importTracks'),
      ack: () => throw Exception('Unexpected response type: ack'),
    );
  }
}
