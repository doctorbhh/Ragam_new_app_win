import re

with open('lib/services/plugin/plugin_interceptor.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Fix 1: Spotify search track image
content = content.replace(
    "url: (t['images'] as List?)?.firstOrNull?['url'] ?? '',",
    "url: (t['album']?['images'] as List?)?.firstOrNull?['url'] ?? '',"
)

# Fix 2: YTMusic search thumbnail
content = content.replace(
    "url: (t['thumbnails'] as List?)?.lastOrNull?['url'] ?? '',",
    "url: (t['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '',"
)

# Fix 3: _getAlbumDetails replacement
old_album = '''  static Future<PluginResponse?> _getAlbumDetails(String pluginId, String id) async {
    // Basic implementation for now, enough to not crash.
    return PluginResponse.albumDetails(AlbumDetails(
      summary: AlbumSummary(id: id, title: 'Loading...', artists: [], thumbnail: Artwork(url: '', layout: ImageLayout.square)),
      tracks: PagedTracks(items: []),
    ));
  }'''

new_album = '''  static Future<PluginResponse?> _getAlbumDetails(String pluginId, String id) async {
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final rawAlbum = await spotify.getAlbum(id);
      final rawTracks = await spotify.getAlbumTracks(id, limit: 50);
      
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
          isExplicit: t['explicit'] == true,
          durationMs: BigInt.from(t['duration_ms'] ?? 0),
        ));
      }
      
      return PluginResponse.albumDetails(AlbumDetails(
        summary: AlbumSummary(
          id: buildMediaId('spotify', id),
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
      if (ytmSapisid != null && ytmCookie != null) {
        final yt = YTMusicService();
        final raw = await yt.getAlbum(id, sapisid: ytmSapisid, cookieString: ytmCookie);
        final tracks = <Track>[];
        for (var t in (raw['tracks'] as List? ?? [])) {
          tracks.add(Track(
            id: buildMediaId('ytmusic', t['videoId'] ?? ''),
            title: t['title'] ?? '',
            artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('ytmusic', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (raw['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '',
              layout: ImageLayout.square,
            ),
            isExplicit: t['isExplicit'] == true,
            durationMs: BigInt.from((t['duration_seconds'] ?? 0) * 1000),
          ));
        }
        return PluginResponse.albumDetails(AlbumDetails(
          summary: AlbumSummary(
            id: buildMediaId('ytmusic', id),
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
    }
    
    return PluginResponse.albumDetails(AlbumDetails(
      summary: AlbumSummary(id: id, title: 'Loading...', artists: [], thumbnail: Artwork(url: '', layout: ImageLayout.square)),
      tracks: PagedTracks(items: []),
    ));
  }'''

content = content.replace(old_album, new_album)

# Fix 4: _getPlaylistDetails replacement
old_playlist = '''  static Future<PluginResponse?> _getPlaylistDetails(String pluginId, String id) async {
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final raw = await spotify.getPlaylistTracks(id, limit: 50);
      
      final tracks = <Track>[];
      final items = raw['data']?['playlistV2']?['content']?['items'] as List?;
      if (items != null) {
        for (var item in items) {
          final trackData = item['itemV2']?['data'];
          if (trackData == null || trackData['__typename'] != 'TrackResponseWrapper') continue;
          final t = trackData['track'];
          if (t == null) continue;
          
          tracks.add(Track(
            id: buildMediaId('spotify', (t['uri'] as String?)?.split(':').last ?? ''),
            title: t['name'] ?? '',
            artists: (t['artists']?['items'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('spotify', (a['uri'] as String?)?.split(':').last ?? ''),
              name: a['profile']?['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: t['albumOfTrack']?['coverArt']?['sources']?.firstOrNull?['url'] ?? '',
              layout: ImageLayout.square,
            ),
            isExplicit: t['contentRating']?['label'] == 'EXPLICIT',
            durationMs: BigInt.from(t['duration']?['totalMilliseconds'] ?? 0),
          ));
        }
      }
      
      return PluginResponse.playlistDetails(PlaylistDetails(
        summary: PlaylistSummary(id: buildMediaId('spotify', id), title: raw['data']?['playlistV2']?['name'] ?? 'Playlist', thumbnail: Artwork(url: '', layout: ImageLayout.square)),
        tracks: PagedTracks(items: tracks),
      ));
    } else if (pluginId == 'ytmusic') {
      final prefs = await SharedPreferences.getInstance();
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      if (ytmSapisid != null && ytmCookie != null) {
        final yt = YTMusicService();
        final raw = await yt.getPlaylist(id, sapisid: ytmSapisid, cookieString: ytmCookie);
        final tracks = <Track>[];
        for (var t in (raw['tracks'] as List? ?? [])) {
          tracks.add(Track(
            id: buildMediaId('ytmusic', t['videoId'] ?? ''),
            title: t['title'] ?? '',
            artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('ytmusic', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (t['thumbnails'] as List?)?.lastOrNull?['url'] ?? '',
              layout: ImageLayout.square,
            ),
            isExplicit: t['isExplicit'] == true,
            durationMs: BigInt.from((t['duration_seconds'] ?? 0) * 1000),
          ));
        }
        return PluginResponse.playlistDetails(PlaylistDetails(
          summary: PlaylistSummary(id: buildMediaId('ytmusic', id), title: raw['title'] ?? 'Playlist', thumbnail: Artwork(url: '', layout: ImageLayout.square)),
          tracks: PagedTracks(items: tracks),
        ));
      }
    }
    
    return PluginResponse.playlistDetails(PlaylistDetails(
      summary: PlaylistSummary(id: id, title: 'Loading...', thumbnail: Artwork(url: '', layout: ImageLayout.square)),
      tracks: PagedTracks(items: []),
    ));
  }'''

new_playlist = '''  static Future<PluginResponse?> _getPlaylistDetails(String pluginId, String id) async {
    if (pluginId == 'spotify') {
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      if (!spotifyAuth.isAuthenticated) return null;
      
      final spotify = SpotifyGqlService(spotifyAuth);
      final raw = await spotify.getPlaylistTracks(id, limit: 50);
      
      final tracks = <Track>[];
      final items = raw['items'] as List?;
      if (items != null) {
        for (var t in items) {
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
            isExplicit: t['explicit'] == true,
            durationMs: BigInt.from(t['duration_ms'] ?? 0),
          ));
        }
      }
      
      return PluginResponse.playlistDetails(PlaylistDetails(
        summary: PlaylistSummary(
          id: buildMediaId('spotify', id),
          title: raw['name'] ?? 'Playlist',
          thumbnail: Artwork(url: (raw['images'] as List?)?.firstOrNull?['url'] ?? '', layout: ImageLayout.square)
        ),
        tracks: PagedTracks(items: tracks),
      ));
    } else if (pluginId == 'ytmusic') {
      final prefs = await SharedPreferences.getInstance();
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      if (ytmSapisid != null && ytmCookie != null) {
        final yt = YTMusicService();
        final raw = await yt.getPlaylist(id, sapisid: ytmSapisid, cookieString: ytmCookie);
        final tracks = <Track>[];
        for (var t in (raw['tracks'] as List? ?? [])) {
          tracks.add(Track(
            id: buildMediaId('ytmusic', t['videoId'] ?? ''),
            title: t['title'] ?? '',
            artists: (t['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('ytmusic', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (t['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '',
              layout: ImageLayout.square,
            ),
            isExplicit: t['isExplicit'] == true,
            durationMs: BigInt.from((t['duration_seconds'] ?? 0) * 1000),
          ));
        }
        return PluginResponse.playlistDetails(PlaylistDetails(
          summary: PlaylistSummary(
            id: buildMediaId('ytmusic', id),
            title: raw['title'] ?? 'Playlist',
            thumbnail: Artwork(url: (raw['thumbnails'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square)
          ),
          tracks: PagedTracks(items: tracks),
        ));
      }
    }
    
    return PluginResponse.playlistDetails(PlaylistDetails(
      summary: PlaylistSummary(id: id, title: 'Loading...', thumbnail: Artwork(url: '', layout: ImageLayout.square)),
      tracks: PagedTracks(items: []),
    ));
  }'''

content = content.replace(old_playlist, new_playlist)

# High quality yt music home thumbnails
content = content.replace(
    "thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url'] ?? '', layout: ImageLayout.square),",
    "thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.square),"
)
content = content.replace(
    "thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url'] ?? '', layout: ImageLayout.circular),",
    "thumbnail: Artwork(url: (item['images'] as List?)?.lastOrNull?['url']?.toString().replaceAll('=w60-h60', '=w544-h544') ?? '', layout: ImageLayout.circular),"
)

with open('lib/services/plugin/plugin_interceptor.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print('Success')
