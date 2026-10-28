// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/events/global_event_bus.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/services/db/dao/library_dao.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:Bloomee/services/db/mappers/media_item_mapper.dart';
import 'package:Bloomee/services/db/mappers/playlist_mapper.dart';
import 'package:equatable/equatable.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Bloomee/services/spotify_auth_service.dart';
import 'package:Bloomee/services/spotify_gql_service.dart';
part 'library_items_state.dart';

/// Manages the user's library: local playlists and saved remote collections.
///
/// Combines data from [PlaylistDAO] (user playlists) and [LibraryDAO] (saved
/// remote collections). Emits view-model state using only domain types — no
/// DB types leak into the state layer.
class LibraryItemsCubit extends Cubit<LibraryItemsState> {
  StreamSubscription? _playlistWatcher;
  StreamSubscription? _refreshSub;
  StreamSubscription? _spotifyAuthSub;
  bool _isFetchingFreshSpotify = false;
  final PlaylistDAO _playlistDao;
  final LibraryDAO _libraryDao;

  LibraryItemsCubit({
    required PlaylistDAO playlistDao,
    required LibraryDAO libraryDao,
  })  : _playlistDao = playlistDao,
        _libraryDao = libraryDao,
        super(LibraryItemsLoading()) {
    _initialize();
  }

  @override
  Future<void> close() {
    _playlistWatcher?.cancel();
    _refreshSub?.cancel();
    _spotifyAuthSub?.cancel();
    return super.close();
  }

  Future<void> _initialize() async {
    await _playlistDao.purgeBrokenPlaylistEntries();
    await _fetchPlaylists();
    _setupWatchers();
  }

  Future<void> _setupWatchers() async {
    _playlistWatcher = (await _playlistDao.watchAllPlaylists()).listen((_) {
      _fetchPlaylists();
    });

    _refreshSub = GlobalEventBus.instance.refreshEvents.listen((_) {
      _fetchPlaylists();
    });

    _spotifyAuthSub = SpotifyAuthService().authStateStream.listen((event) {
      if (event == 'logout') {
        _clearCachedSpotifyPlaylists();
        final localOnly = state.playlists
            .where((p) =>
                !p.storageKey.startsWith('spotify:') &&
                !p.storageKey.startsWith('spotify::'))
            .toList();
        emit(state.copyWith(playlists: localOnly));
      } else {
        _fetchPlaylists();
      }
    });
  }

  static const _systemPlaylists = {
    SettingKeys.recentlyPlayedPlaylist,
    SettingKeys.downloadPlaylist,
    SettingKeys.localMusicPlaylist,
  };

  static const String _cachedSpotifyKey = 'cached_spotify_playlists';

  Future<List<PlaylistItemProperties>> _loadCachedSpotifyPlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_cachedSpotifyKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> list = jsonDecode(jsonStr);
        return list
            .map((item) =>
                PlaylistItemProperties.fromJson(item as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      log('Error loading cached Spotify playlists: $e',
          name: 'LibraryItemsCubit');
    }
    return [];
  }

  Future<void> _saveCachedSpotifyPlaylists(
      List<PlaylistItemProperties> spotifyPlaylists) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr =
          jsonEncode(spotifyPlaylists.map((p) => p.toJson()).toList());
      await prefs.setString(_cachedSpotifyKey, jsonStr);
    } catch (e) {
      log('Error saving cached Spotify playlists: $e',
          name: 'LibraryItemsCubit');
    }
  }

  Future<void> _clearCachedSpotifyPlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachedSpotifyKey);
    } catch (e) {
      log('Error clearing cached Spotify playlists: $e',
          name: 'LibraryItemsCubit');
    }
  }

  /// Fetch all playlists (user + remote collections) and emit as domain items.
  Future<void> _fetchPlaylists() async {
    try {
      final allPlaylists = await _playlistDao.getAllPlaylists();
      allPlaylists.removeWhere((p) => _systemPlaylists.contains(p.name));
      // Guard against orphan rows with an empty name.
      allPlaylists.removeWhere((p) => p.name.trim().isEmpty);
      final localItems = await _toItemProperties(allPlaylists);

      // Immediately load cached Spotify playlists from storage
      final cachedSpotify = await _loadCachedSpotifyPlaylists();

      // Emit local items + cached Spotify playlists immediately so user sees them with 0 delay!
      final combined = <PlaylistItemProperties>[...localItems, ...cachedSpotify];
      emit(state.copyWith(playlists: combined));

      // Trigger background refresh for fresh Spotify playlists
      unawaited(_fetchFreshSpotifyPlaylists(cachedSpotify));
    } catch (e) {
      log('Error fetching playlists: $e', name: 'LibraryItemsCubit');
      emit(const LibraryItemsError('Failed to load your playlists.'));
    }
  }

  Future<void> _fetchFreshSpotifyPlaylists(
      List<PlaylistItemProperties> cachedSpotify) async {
    if (_isFetchingFreshSpotify) return;
    _isFetchingFreshSpotify = true;

    try {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.ensureInitialized();

      if (!spotifyAuth.hasStoredSession && !spotifyAuth.isAuthenticated) {
        // User is definitely not logged in to Spotify.
        if (cachedSpotify.isNotEmpty) {
          await _clearCachedSpotifyPlaylists();
          final localOnly = state.playlists
              .where((p) =>
                  !p.storageKey.startsWith('spotify:') &&
                  !p.storageKey.startsWith('spotify::'))
              .toList();
          emit(state.copyWith(playlists: localOnly));
        }
        return;
      }

      final token = await spotifyAuth.getValidAccessToken();
      if (token == null) {
        log('Spotify access token unavailable, keeping cached playlists',
            name: 'LibraryItemsCubit');
        return;
      }

      final spotify = SpotifyGqlService(spotifyAuth);
      final freshSpotifyItems = <PlaylistItemProperties>[];
      int currentOffset = 0;
      bool hasMore = true;

      while (hasMore) {
        final savedPlaylists = await spotify.getSavedPlaylists(
            offset: currentOffset, limit: 50);
        final spotifyItems = savedPlaylists['items'] as List? ?? [];
        final total = savedPlaylists['total'] as int? ?? 0;

        for (var item in spotifyItems) {
          final playlistName = item['name'] ?? 'Spotify Playlist';
          freshSpotifyItems.add(PlaylistItemProperties(
            playlistName: playlistName,
            storageKey: 'spotify::playlist:${item['id']}',
            coverImgUrl: (item['images'] as List?)?.firstOrNull?['url'],
            subTitle: 'Spotify Playlist',
            type: PlaylistType.remotePlaylist,
          ));
        }

        currentOffset += 50;
        hasMore = currentOffset < total && spotifyItems.isNotEmpty;
      }

      // Persist fresh items to cache
      await _saveCachedSpotifyPlaylists(freshSpotifyItems);

      // Merge with current local playlists in state
      final currentLocal = state.playlists
          .where((p) =>
              !p.storageKey.startsWith('spotify:') &&
              !p.storageKey.startsWith('spotify::'))
          .toList();
      emit(state.copyWith(playlists: [...currentLocal, ...freshSpotifyItems]));
    } catch (e) {
      log('Error fetching fresh Spotify playlists: $e (keeping cached playlists)',
          name: 'LibraryItemsCubit');
      // On error, cached playlists are preserved!
    } finally {
      _isFetchingFreshSpotify = false;
    }
  }

  /// Manually trigger a refresh of all playlists (e.g. pull-to-refresh or on tab focus)
  Future<void> refreshPlaylists() async {
    await _fetchPlaylists();
  }

  /// Convert DB rows to view-model items using only domain types.
  Future<List<PlaylistItemProperties>> _toItemProperties(
      List<PlaylistDB> dbs) async {
    final items = <PlaylistItemProperties>[];

    for (final p in dbs) {
      // Map using the playlist mapper to get a domain Playlist.
      final domainPlaylist = playlistDBToPlaylist(p);

      String? subtitle;
      if (domainPlaylist.subtitle != null &&
          domainPlaylist.subtitle!.trim().isNotEmpty) {
        subtitle = domainPlaylist.subtitle!.trim();
      } else if (domainPlaylist.type == PlaylistType.userPlaylist) {
        final trackCount = (await _playlistDao.getPlaylistTracks(p.id)).length;
        subtitle = '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}';
      }

      final coverUrl = await _resolveCoverUrl(p);

      items.add(
        PlaylistItemProperties(
          playlistName: domainPlaylist.title,
          storageKey: p.name,
          subTitle: subtitle,
          coverImgUrl: coverUrl,
          type: domainPlaylist.type,
          isPinned: p.isPinned,
          sortOrder: p.sortOrder,
          playlistId: p.id,
        ),
      );
    }

    return items;
  }

  /// Resolve a cover image URL: direct thumbnail for remote, first track for user.
  Future<String?> _resolveCoverUrl(PlaylistDB playlist) async {
    // Try direct thumbnail first (works for all types).
    final thumb = playlist.thumbnail;
    if (thumb != null && thumb.url.isNotEmpty) {
      return thumb.url;
    }

    // For artists, try embedded artist thumbnail.
    if (playlist.type == PlaylistTypeDB.artist &&
        playlist.artists != null &&
        playlist.artists!.isNotEmpty) {
      final artistThumb = playlist.artists!.first.thumbnail;
      if (artistThumb != null && artistThumb.url.isNotEmpty) {
        return artistThumb.url;
      }
    }

    // For user playlists, use first track's artwork.
    if (playlist.type == PlaylistTypeDB.userPlaylist) {
      final tracks = await _playlistDao.getPlaylistTracks(playlist.id);
      if (tracks.isNotEmpty) {
        final trackUrl = tracks.first.thumbnail?.url;
        if (trackUrl != null && trackUrl.isNotEmpty) return trackUrl;
      }
    }

    return null;
  }

  // ── Playlist CRUD ──────────────────────────────────────────────────────────

  /// Create a new empty playlist.
  Future<void> createPlaylist(String name) async {
    await _playlistDao.createPlaylist(name);
    SnackbarService.showMessage("Playlist '$name' created!");
  }

  /// Delete a playlist by its Isar id.
  void removePlaylistById(int playlistId) {
    _playlistDao.deletePlaylist(playlistId);
    SnackbarService.showMessage('Playlist removed');
  }

  /// Delete a playlist by name.
  void removePlaylistByName(String name) {
    if (name.isNotEmpty && name != 'Null') {
      _playlistDao.deletePlaylistByName(name);
      SnackbarService.showMessage('Playlist "$name" removed');
    }
  }

  // ── Track management ───────────────────────────────────────────────────────

  /// Add a [Track] to a named playlist.
  Future<void> addToPlaylist(Track track, String playlistName,
      {bool showSnackbar = true}) async {
    if (playlistName == 'Null' || playlistName.isEmpty) return;
    try {
      await _playlistDao.addTrackToPlaylistByName(playlistName, track);
      if (showSnackbar) {
        SnackbarService.showMessage('${track.title} added to $playlistName');
      }
    } catch (e) {
      log('Failed to add "${track.title}" to "$playlistName": $e',
          name: 'LibraryItemsCubit');
      if (showSnackbar) {
        SnackbarService.showMessage(
            'Failed to add to playlist: ${e.toString().split('\n').first}');
      }
    }
  }

  /// Remove a [Track] from a named playlist.
  Future<void> removeFromPlaylist(Track track, String playlistName,
      {bool showSnackbar = true}) async {
    if (playlistName == 'Null' || playlistName.isEmpty) return;
    final playlist = await _playlistDao.getPlaylistByName(playlistName);
    if (playlist == null) return;
    await _playlistDao.removeTrackFromPlaylist(playlist.id, track.id);
    if (showSnackbar) {
      SnackbarService.showMessage('${track.title} removed from $playlistName');
    }
  }

  /// Get all tracks in a named playlist.
  Future<List<Track>?> getPlaylistTracks(String playlistName) async {
    try {
      final playlist = await _playlistDao.getPlaylistByName(playlistName);
      if (playlist == null) return null;
      final trackDBs = await _playlistDao.getPlaylistTracks(playlist.id);
      return trackDBs.map(trackDBToTrack).toList();
    } catch (e) {
      log('Error getting playlist: $e', name: 'LibraryItemsCubit');
      return null;
    }
  }

  // ── Like helpers ───────────────────────────────────────────────────────────

  /// Check if a track is in the "Liked" playlist.
  Future<bool> isTrackLiked(Track track) async {
    return _playlistDao.isTrackLiked(track.id);
  }

  /// Like or unlike a track.
  Future<void> setTrackLiked(Track track, bool liked) async {
    await _playlistDao.setTrackLiked(track, liked);
  }

  /// Get all playlist names containing a given track.
  Future<Set<String>> getPlaylistsContainingTrack(String mediaId) async {
    final names = await _playlistDao.getPlaylistsContainingTrack(mediaId);
    return names.toSet();
  }

  /// Load a full [Playlist] domain model by name.
  Future<Playlist?> getPlaylistByName(String name) async {
    final playlistDB = await _playlistDao.getPlaylistByName(name);
    if (playlistDB == null) return null;
    return _playlistDao.loadPlaylist(name);
  }

  // ── Remote collection save (delegates to LibraryDAO) ───────────────────────

  Future<void> saveRemoteArtist(
      {required ArtistSummary artist,
      required String sourceName,
      bool showSnackbar = true}) async {
    await _libraryDao.saveArtist(artist, sourceName: sourceName);
    if (showSnackbar) {
      SnackbarService.showMessage('Artist "${artist.name}" saved to library');
    }
  }

  Future<void> saveRemoteAlbum(
      {required AlbumSummary album,
      required String sourceName,
      bool showSnackbar = true}) async {
    await _libraryDao.saveAlbum(album, sourceName: sourceName);
    if (showSnackbar) {
      SnackbarService.showMessage('Album "${album.title}" saved to library');
    }
  }

  Future<void> saveRemotePlaylist(
      {required PlaylistSummary playlist,
      required String sourceName,
      bool showSnackbar = true}) async {
    await _libraryDao.saveRemotePlaylist(playlist, sourceName: sourceName);
    if (showSnackbar) {
      SnackbarService.showMessage(
          'Playlist "${playlist.title}" saved to library');
    }
  }

  /// Check if a remote collection is already saved (by mediaId).
  Future<bool> isRemoteSaved(String mediaId, PlaylistType type) {
    return _libraryDao.isSaved(mediaId, type);
  }

  /// Remove a saved remote collection by mediaId.
  Future<void> removeRemoteSaved(String mediaId, PlaylistType type) async {
    final dbType = playlistTypeToPlaylistTypeDB(type);
    await _libraryDao.removeByMediaId(mediaId, dbType);
    SnackbarService.showMessage('Removed from library');
  }

  // ── Navigation target resolution ──────────────────────────────────────────

  /// Resolve a library item by storage key into a domain [Playlist] for navigation.
  ///
  /// The returned [Playlist] carries embedded artist/album/remotePlaylist
  /// domain objects. Returns null if not found.
  Future<Playlist?> resolveLibraryItem(String storageKey) async {
    if (storageKey.startsWith('spotify::playlist:') ||
        storageKey.startsWith('spotify:playlist:') ||
        storageKey.startsWith('spotify:')) {
      final item = state.playlists
          .where((p) => p.storageKey == storageKey)
          .firstOrNull;
      if (item != null) {
        final resolvedId = storageKey.startsWith('spotify::')
            ? storageKey
            : 'spotify::${storageKey.replaceFirst('spotify:', '')}';
        return Playlist(
          tracks: const [],
          title: item.playlistName,
          type: PlaylistType.remotePlaylist,
          remotePlaylist: PlaylistSummary(
            id: resolvedId,
            title: item.playlistName,
            thumbnail: Artwork(
                url: item.coverImgUrl ?? '', layout: ImageLayout.square),
          ),
        );
      }
    }
    return _libraryDao.resolveByStorageKey(storageKey);
  }

  // ── Search helper for LibrarySearchCubit ──────────────────────────────────

  /// Search tracks by query, returning domain [Track] objects.
  Future<List<Track>> searchTracks(String query) async {
    final results = await _playlistDao.searchLibrary(query);
    return results.map((r) => trackDBToTrack(r.$1)).toList();
  }

  // ── Library Arrangement ─────────────────────────────────────────────────

  /// Toggle pin state for a playlist.
  Future<void> togglePin(int playlistId) async {
    final item =
        state.playlists.where((p) => p.playlistId == playlistId).firstOrNull;
    if (item == null) return;
    await _playlistDao.setPinned(playlistId, !item.isPinned);
  }

  /// Reorder library playlists.
  ///
  /// Called after a drag-and-drop reorder. [oldIndex] and [newIndex] are
  /// positions within the displayed (filtered) list.
  Future<void> reorderLibrary(int oldIndex, int newIndex) async {
    final current = List<PlaylistItemProperties>.from(state.playlists);
    if (oldIndex < newIndex) newIndex -= 1;
    final item = current.removeAt(oldIndex);
    current.insert(newIndex, item);
    // Optimistic UI update.
    emit(state.copyWith(playlists: current));
    // Persist new order.
    await _playlistDao.reorderPlaylists(
      current.map((p) => p.playlistId).toList(),
    );
  }
}
