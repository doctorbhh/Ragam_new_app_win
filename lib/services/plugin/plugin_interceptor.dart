import 'dart:developer';
import 'package:Bloomee/src/rust/api/plugin/events.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:Bloomee/src/rust/api/plugin/commands.dart';
import 'package:Bloomee/services/spotify_auth_service.dart';
import 'package:Bloomee/services/spotify_gql_service.dart';
import 'package:Bloomee/services/ytmusic_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';
import 'package:Bloomee/plugins/utils/media_id.dart';

class PluginInterceptor {
  static Future<PluginResponse?> intercept(String pluginId, PluginRequest request) async {
    if (pluginId != 'spotify' && pluginId != 'ytmusic') return null;
    
    final response = await request.when(
      contentResolver: (cmd) => _handleContentResolver(pluginId, cmd),
      chartProvider: (_) async => null,
      lyricsProvider: (_) async => null,
      searchSuggestionProvider: (_) async => null,
      contentImporter: (_) async => null,
    );

    if (response != null) return response;

    if (pluginId == 'spotify' || pluginId == 'ytmusic') {
      return request.when(
        contentResolver: (cmd) => cmd.when(
          search: (_, __, ___) => PluginResponse.search(PagedMediaItems(items: [])),
          getAlbumDetails: (_) => PluginResponse.albumDetails(AlbumDetails(summary: AlbumSummary(id: '', title: '', artists: [], thumbnail: Artwork(url: '', layout: ImageLayout.square)), tracks: PagedTracks(items: []))),
          getArtistDetails: (_) => PluginResponse.artistDetails(ArtistDetails(summary: ArtistSummary(id: '', name: '', thumbnail: Artwork(url: '', layout: ImageLayout.circular)), albums: PagedAlbums(items: []), topTracks: [], relatedArtists: [])),
          getPlaylistDetails: (_) => PluginResponse.playlistDetails(PlaylistDetails(summary: PlaylistSummary(id: '', title: '', thumbnail: Artwork(url: '', layout: ImageLayout.square)), tracks: PagedTracks(items: []))),
          getStreams: (_) => null,
          moreAlbumTracks: (_, __) => PluginResponse.moreTracks(PagedTracks(items: [])),
          moreArtistAlbums: (_, __) => PluginResponse.moreAlbums(PagedAlbums(items: [])),
          morePlaylistTracks: (_, __) => PluginResponse.moreTracks(PagedTracks(items: [])),
          getHomeSections: () => PluginResponse.homeSections([]),
          loadMore: (_, __) => PluginResponse.loadMoreItems([]),
          getRadioTracks: (_, __) => PluginResponse.moreTracks(PagedTracks(items: [])),
          getTrackDetails: (_) => PluginResponse.trackDetails(Track(id: '', title: '', durationMs: BigInt.zero, artists: [], thumbnail: Artwork(url: '', layout: ImageLayout.square), isExplicit: false)),
          getSegmentsForTrack: (_) => PluginResponse.segments([]),
        ),
        chartProvider: (_) => PluginResponse.charts([]),
        lyricsProvider: (_) => PluginResponse.ack(),
        searchSuggestionProvider: (_) => PluginResponse.suggestions([]),
        contentImporter: (_) => PluginResponse.ack(),
      );
    }
    
    return null;
  }

  static Future<PluginResponse?> _handleContentResolver(String pluginId, ContentResolverCommand cmd) async {
    return cmd.when(
      search: (query, filter, pageToken) => _search(pluginId, query, filter, pageToken),
      getAlbumDetails: (id) => _getAlbumDetails(pluginId, id),
      getArtistDetails: (id) => _getArtistDetails(pluginId, id),
      getPlaylistDetails: (id) => _getPlaylistDetails(pluginId, id),
      getStreams: (id) async => null, // Handled separately in MediaResolverService
      moreAlbumTracks: (id, pageToken) async => null,
      moreArtistAlbums: (id, pageToken) async => null,
      morePlaylistTracks: (id, pageToken) async => null,
      getHomeSections: () => _getHomeSections(pluginId),
      loadMore: (id, moreLink) async => null,
      getRadioTracks: (trackId, pageToken) async => null,
      getTrackDetails: (id) => _getTrackDetails(pluginId, id),
      getSegmentsForTrack: (id) async => null,
    );
  }

  static Future<PluginResponse?> _search(String pluginId, String query, ContentSearchFilter filter, String? pageToken) async {
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final items = <MediaItem>[];
      
      if (filter == ContentSearchFilter.all || filter == ContentSearchFilter.track) {
        final raw = filter == ContentSearchFilter.track 
          ? await spotify.searchTracks(query, limit: 20)
          : (await spotify.searchAll(query, limit: 20))['tracks'] ?? {'items': []};
        final trackItems = filter == ContentSearchFilter.track ? raw['items'] as List? ?? [] : raw as List? ?? [];
        for (var t in trackItems) {
          items.add(MediaItem.track(Track(
            id: buildMediaId('spotify', t['id'] ?? ''),
            title: t['name'] ?? '',
            artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('spotify', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (t['album']?['images'] as List?)?.firstOrNull?['url'] ?? '',
              layout: ImageLayout.square,
            ),
            url: 'https://open.spotify.com/track/${t['id']}',
            isExplicit: t['is_explicit'] == true,
            durationMs: BigInt.from(t['duration_ms'] ?? 0),
          )));
        }
      }
      
      if (filter == ContentSearchFilter.all || filter == ContentSearchFilter.album) {
        final raw = filter == ContentSearchFilter.album 
          ? await spotify.searchAlbums(query, limit: 20)
          : (await spotify.searchAll(query, limit: 20))['albums'] ?? {'items': []};
        final albumItems = filter == ContentSearchFilter.album ? raw['items'] as List? ?? [] : raw as List? ?? [];
        for (var a in albumItems) {
          items.add(MediaItem.album(AlbumSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            title: a['name'] ?? '',
            artists: (a['artists'] as List?)?.map((ar) => ArtistSummary(id: buildMediaId('spotify', ar['id'] ?? ''), name: ar['name'] ?? '')).toList() ?? [],
            thumbnail: Artwork(url: (a['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square),
          )));
        }
      }
      
      if (filter == ContentSearchFilter.all || filter == ContentSearchFilter.playlist) {
        final raw = filter == ContentSearchFilter.playlist 
          ? await spotify.searchPlaylists(query, limit: 20)
          : (await spotify.searchAll(query, limit: 20))['playlists'] ?? {'items': []};
        final playlistItems = filter == ContentSearchFilter.playlist ? raw['items'] as List? ?? [] : raw as List? ?? [];
        for (var p in playlistItems) {
          items.add(MediaItem.playlist(PlaylistSummary(
            id: buildMediaId('spotify', p['id'] ?? ''),
            title: p['name'] ?? '',
            owner: p['owner']?['display_name'],
            thumbnail: Artwork(url: (p['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square),
          )));
        }
      }
      
      if (filter == ContentSearchFilter.all || filter == ContentSearchFilter.artist) {
        final raw = filter == ContentSearchFilter.artist 
          ? await spotify.searchArtists(query, limit: 20)
          : (await spotify.searchAll(query, limit: 20))['artists'] ?? {'items': []};
        final artistItems = filter == ContentSearchFilter.artist ? raw['items'] as List? ?? [] : raw as List? ?? [];
        for (var ar in artistItems) {
          items.add(MediaItem.artist(ArtistSummary(
            id: buildMediaId('spotify', ar['id'] ?? ''),
            name: ar['name'] ?? '',
            thumbnail: Artwork(url: (ar['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.circular),
          )));
        }
      }
      
      return PluginResponse.search(PagedMediaItems(items: items));
    } else if (pluginId == 'ytmusic') {
      // User requested to remove YouTube Music from search
      return PluginResponse.search(PagedMediaItems(items: []));
    }
    
    return PluginResponse.search(PagedMediaItems(items: []));
  }

  static Future<PluginResponse?> _getAlbumDetails(String pluginId, String id) async {
    final actualId = localIdOf(id) ?? id;
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final rawAlbum = await spotify.getAlbum(actualId);
      final rawTracks = await spotify.getAlbumTracks(actualId, limit: 50);
      
      final tracks = <Track>[];
      for (var t in (rawTracks['items'] as List? ?? [])) {
        tracks.add(Track(
          id: buildMediaId('spotify', t['id'] ?? ''),
          title: t['name'] ?? '',
          artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(
            url: (rawAlbum['images'] as List?)?.firstOrNull?['url'] ?? '',
            layout: ImageLayout.square,
          ),
          url: 'https://open.spotify.com/track/${t['id']}',
          isExplicit: t['explicit'] == true,
          durationMs: BigInt.from(t['duration_ms'] ?? 0),
        ));
      }
      
      return PluginResponse.albumDetails(AlbumDetails(
        summary: AlbumSummary(
          id: buildMediaId('spotify', actualId),
          title: rawAlbum['name'] ?? 'Album',
          artists: (rawAlbum['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(url: (rawAlbum['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square),
        ),
        tracks: PagedTracks(items: tracks),
      ));
    } else if (pluginId == 'ytmusic') {
      final prefs = await SharedPreferences.getInstance();
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      
      final yt = YTMusicService();
      final raw = await yt.getPlaylist(actualId, sapisid: ytmSapisid, cookieString: ytmCookie);
      final tracks = <Track>[];
      for (var t in (raw['items'] as List? ?? [])) {
        tracks.add(Track(
          id: buildMediaId('ytmusic', t['id'] ?? ''),
          title: t['name'] ?? '',
          artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('ytmusic', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(
            url: (t['album']?['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '',
            layout: ImageLayout.square,
          ),
          url: 'https://music.youtube.com/watch?v=${t['id']}',
          isExplicit: false,
          durationMs: BigInt.from((t['duration_ms'] ?? 0)),
        ));
      }
      return PluginResponse.albumDetails(AlbumDetails(
        summary: AlbumSummary(
          id: buildMediaId('ytmusic', actualId),
          title: raw['title'] ?? 'Album',
          artists: (raw['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('ytmusic', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(url: (raw['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square),
        ),
        tracks: PagedTracks(items: tracks),
      ));
    }
    
    return PluginResponse.albumDetails(AlbumDetails(
      summary: AlbumSummary(id: id, title: 'Loading...', artists: [], thumbnail: Artwork(url: '', layout: ImageLayout.square)),
      tracks: PagedTracks(items: []),
    ));
  }

  static Future<PluginResponse?> _getArtistDetails(String pluginId, String id) async {
    final actualId = localIdOf(id) ?? id;
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final rawArtist = await spotify.getArtist(actualId);
      final rawTopTracks = await spotify.getArtistTopTracks(actualId);
      
      final topTracks = <Track>[];
      for (var t in rawTopTracks) {
        topTracks.add(Track(
          id: buildMediaId('spotify', t['id'] ?? ''),
          title: t['name'] ?? '',
          artists: (t['album']?['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(
            url: (t['album']?['images'] as List?)?.firstOrNull?['url'] ?? '',
            layout: ImageLayout.square,
          ),
          url: 'https://open.spotify.com/track/${t['id']}',
          isExplicit: false,
          durationMs: BigInt.from(t['duration_ms'] ?? 0),
        ));
      }
      
      return PluginResponse.artistDetails(ArtistDetails(
        summary: ArtistSummary(
          id: buildMediaId('spotify', actualId),
          name: rawArtist['name'] ?? 'Artist',
          thumbnail: Artwork(
            url: (rawArtist['images'] as List?)?.firstOrNull?['url'] ?? '',
            layout: ImageLayout.circular,
          ),
        ),
        topTracks: topTracks,
        albums: PagedAlbums(items: []),
        relatedArtists: [],
      ));
    } else if (pluginId == 'ytmusic') {
      final prefs = await SharedPreferences.getInstance();
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      
      final yt = YTMusicService();
      try {
        final raw = await yt.getPlaylist(actualId, sapisid: ytmSapisid, cookieString: ytmCookie);
        final topTracks = <Track>[];
        for (var t in (raw['items'] as List? ?? [])) {
          topTracks.add(Track(
            id: buildMediaId('ytmusic', t['id'] ?? ''),
            title: t['name'] ?? '',
            artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('ytmusic', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (t['album']?['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '',
              layout: ImageLayout.square,
            ),
            url: 'https://music.youtube.com/watch?v=${t['id']}',
            isExplicit: false,
            durationMs: BigInt.from((t['duration_ms'] ?? 0)),
          ));
        }
        
        return PluginResponse.artistDetails(ArtistDetails(
          summary: ArtistSummary(
            id: buildMediaId('ytmusic', actualId),
            name: raw['title'] ?? 'Artist',
            thumbnail: Artwork(url: (raw['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.circular),
          ),
          topTracks: topTracks,
          albums: PagedAlbums(items: []),
          relatedArtists: [],
        ));
      } catch (e) {
        log('Error getting ytmusic artist details: $e');
      }
    }
    
    return PluginResponse.artistDetails(ArtistDetails(
      summary: ArtistSummary(id: id, name: 'Unknown Artist', thumbnail: Artwork(url: '', layout: ImageLayout.circular)),
      topTracks: [],
      albums: PagedAlbums(items: []),
      relatedArtists: [],
    ));
  }

  static Future<PluginResponse?> _getTrackDetails(String pluginId, String id) async {
    final actualId = localIdOf(id) ?? id;
    if (pluginId == 'spotify') {
      try {
        final spotifyAuth = SpotifyAuthService();
        await spotifyAuth.initializeFromStorage();
        if (!spotifyAuth.isAuthenticated) return null;
        
        final spotify = SpotifyGqlService(spotifyAuth);
        final raw = await spotify.getTrack(actualId);
        
        return PluginResponse.trackDetails(Track(
          id: buildMediaId('spotify', raw['id'] ?? actualId),
          title: raw['name'] ?? 'Unknown Track',
          artists: (raw['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(
            url: (raw['album']?['images'] as List?)?.firstOrNull?['url'] ?? '',
            layout: ImageLayout.square,
          ),
          url: 'https://open.spotify.com/track/$actualId',
          durationMs: BigInt.from(raw['duration_ms'] ?? 0),
          isExplicit: false,
        ));
      } catch (e) {
        log('Error getting spotify track details: $e');
      }
    } else if (pluginId == 'ytmusic') {
      try {
        final yt = YTMusicService();
        final raw = await yt.getWatchPlaylist(actualId);
        final trackInfo = (raw['tracks'] as List?)?.firstOrNull;
        if (trackInfo != null) {
          return PluginResponse.trackDetails(Track(
            id: buildMediaId('ytmusic', trackInfo['videoId'] ?? actualId),
            title: trackInfo['title'] ?? 'Unknown Track',
            artists: [
              ArtistSummary(id: buildMediaId('ytmusic', 'unknown'), name: trackInfo['artist'] ?? 'Unknown')
            ],
            thumbnail: Artwork(
              url: trackInfo['thumbnail'] ?? '',
              layout: ImageLayout.square,
            ),
            url: 'https://music.youtube.com/watch?v=$actualId',
            durationMs: BigInt.from(trackInfo['duration_ms'] ?? 0),
            isExplicit: false,
          ));
        }
      } catch (e) {
        log('Error getting ytmusic track details: $e');
      }
    }
    
    return PluginResponse.trackDetails(Track(
      id: id,
      title: 'Unknown Track',
      durationMs: BigInt.zero,
      artists: [],
      thumbnail: Artwork(url: '', layout: ImageLayout.square),
      isExplicit: false,
    ));
  }

  static Future<PluginResponse?> _getPlaylistDetails(String pluginId, String id) async {
    String actualId = localIdOf(id) ?? id;
    if (actualId.startsWith('playlist:')) {
      actualId = actualId.replaceFirst('playlist:', '');
    }
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final raw = await spotify.getPlaylistTracks(actualId, limit: 50);
      
      final tracks = <Track>[];
      for (var t in (raw['items'] as List? ?? [])) {
        tracks.add(Track(
          id: buildMediaId('spotify', t['id'] ?? ''),
          title: t['name'] ?? '',
          artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(
            url: (t['album']?['images'] as List?)?.firstOrNull?['url'] ?? '',
            layout: ImageLayout.square,
          ),
          url: 'https://open.spotify.com/track/${t['id']}',
          isExplicit: false,
          durationMs: BigInt.from((t['duration_ms'] ?? 0)),
        ));
      }
      return PluginResponse.playlistDetails(PlaylistDetails(
        summary: PlaylistSummary(
          id: buildMediaId('spotify', actualId),
          title: raw['name'] ?? 'Playlist',
          thumbnail: Artwork(url: (raw['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square)
        ),
        tracks: PagedTracks(items: tracks),
      ));
    } else if (pluginId == 'ytmusic') {
      final prefs = await SharedPreferences.getInstance();
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      
      final yt = YTMusicService();
      final raw = await yt.getPlaylist(actualId, sapisid: ytmSapisid, cookieString: ytmCookie);
      final tracks = <Track>[];
      for (var t in (raw['items'] as List? ?? [])) {
        tracks.add(Track(
          id: buildMediaId('ytmusic', t['id'] ?? ''),
          title: t['name'] ?? '',
          artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
            id: buildMediaId('ytmusic', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [],
          thumbnail: Artwork(
            url: (t['album']?['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '',
            layout: ImageLayout.square,
          ),
          url: 'https://music.youtube.com/watch?v=${t['id']}',
          isExplicit: false,
          durationMs: BigInt.from((t['duration_ms'] ?? 0)),
        ));
      }
      return PluginResponse.playlistDetails(PlaylistDetails(
        summary: PlaylistSummary(
          id: buildMediaId('ytmusic', actualId),
          title: raw['title'] ?? 'Playlist',
          thumbnail: Artwork(url: (raw['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square)
        ),
        tracks: PagedTracks(items: tracks),
      ));
    }
    
    return PluginResponse.playlistDetails(PlaylistDetails(
      summary: PlaylistSummary(id: id, title: 'Loading...', thumbnail: Artwork(url: '', layout: ImageLayout.square)),
      tracks: PagedTracks(items: []),
    ));
  }

  static Future<PluginResponse?> _getHomeSections(String pluginId) async {
    if (pluginId == 'ytmusic') {
      final prefs = await SharedPreferences.getInstance();
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      if (ytmSapisid == null || ytmCookie == null) return null;
      
      final yt = YTMusicService();
      final rawSections = await yt.getHome(ytmSapisid, ytmCookie, limit: 10);
      final sections = <Section>[];
      
      for (var raw in rawSections) {
        if (raw['items'] == null || (raw['items'] as List).isEmpty) continue;
        final items = <MediaItem>[];
        for (var item in raw['items']) {
          final objType = item['objectType'];
          if (objType == 'Track') {
            items.add(MediaItem.track(Track(
              id: buildMediaId('ytmusic', item['id'] ?? ''),
              title: item['name'] ?? '',
              artists: (item['artists'] as List?)?.map((a) => ArtistSummary(id: buildMediaId('ytmusic', a['id'] ?? ''), name: a['name'] ?? '')).toList() ?? [],
              thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square),
              url: 'https://music.youtube.com/watch?v=${item['id']}',
              isExplicit: false,
              durationMs: BigInt.from(item['duration_ms'] ?? 0),
            )));
          } else if (objType == 'Playlist') {
            items.add(MediaItem.playlist(PlaylistSummary(
              id: buildMediaId('ytmusic', item['id'] ?? ''),
              title: item['name'] ?? '',
              owner: item['owner']?['display_name'],
              thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square),
            )));
          } else if (objType == 'Album') {
            items.add(MediaItem.album(AlbumSummary(
              id: buildMediaId('ytmusic', item['id'] ?? ''),
              title: item['name'] ?? '',
              artists: (item['artists'] as List?)?.map((a) => ArtistSummary(id: buildMediaId('ytmusic', a['id'] ?? ''), name: a['name'] ?? '')).toList() ?? [],
              thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square),
            )));
          } else if (objType == 'Artist') {
            items.add(MediaItem.artist(ArtistSummary(
              id: buildMediaId('ytmusic', item['id'] ?? ''),
              name: item['name'] ?? '',
              thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.circular),
            )));
          }
        }
        if (items.isNotEmpty) {
          sections.add(Section(id: raw['id'] ?? raw['title'] ?? 'unknown', title: raw['title'] ?? 'Section', cardType: CardType.carousel, items: items));
        }
      }
      return PluginResponse.homeSections(sections);
    } else if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final rawSections = await spotify.getHome(limit: 10);
      final sections = <Section>[];
      
      for (var raw in rawSections) {
        if (raw['items'] == null || (raw['items'] as List).isEmpty) continue;
        final items = <MediaItem>[];
        for (var item in raw['items']) {
          final objType = item['objectType'];
          if (objType == 'Playlist') {
            items.add(MediaItem.playlist(PlaylistSummary(
              id: buildMediaId('spotify', item['id'] ?? ''),
              title: item['name'] ?? '',
              thumbnail: Artwork(url: (item['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square),
              owner: item['owner']?['display_name'],
            )));
          } else if (objType == 'Album') {
            final artists = (item['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('spotify', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [];
            items.add(MediaItem.album(AlbumSummary(
              id: buildMediaId('spotify', item['id'] ?? ''),
              title: item['name'] ?? '',
              artists: artists,
              thumbnail: Artwork(url: (item['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square),
            )));
          } else if (objType == 'Artist') {
            items.add(MediaItem.artist(ArtistSummary(
              id: buildMediaId('spotify', item['id'] ?? ''),
              name: item['name'] ?? '',
              thumbnail: Artwork(url: (item['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.circular),
            )));
          }
        }
        if (items.isNotEmpty) {
          sections.add(Section(id: raw['id'] ?? raw['title'] ?? 'unknown', title: raw['title'] ?? 'Section', cardType: CardType.carousel, items: items));
        }
      }
      return PluginResponse.homeSections(sections);
    }
    return null;
  }
}
