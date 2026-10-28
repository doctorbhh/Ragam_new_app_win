import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:Bloomee/blocs/explore/cubit/home_addons_state.dart';
import 'package:Bloomee/services/spotify_auth_service.dart';
import 'package:Bloomee/services/spotify_api_service.dart';
import 'package:Bloomee/services/spotify_gql_service.dart';
import 'package:Bloomee/services/ytmusic_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Bloomee/plugins/utils/media_id.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'dart:developer';

class HomeAddonsCubit extends Cubit<HomeAddonsState> {
  HomeAddonsCubit() : super(HomeAddonsInitial());

  Future<void> loadHomeData() async {
    emit(HomeAddonsLoading());
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Check YT Music first
      final ytmSapisid = prefs.getString('ytm_sapisid');
      final ytmCookie = prefs.getString('ytm_cookie');
      
      if (ytmSapisid != null && ytmCookie != null) {
        log('Loading home data from YouTube Music...', name: 'HomeAddons');
        final yt = YTMusicService();
        final rawSections = await yt.getHome(ytmSapisid, ytmCookie, limit: 10);
        final sections = _mapYtmToSections(rawSections);
        emit(HomeAddonsLoaded(sections, source: 'ytmusic'));
        return;
      }

      // Fallback to Spotify
      final spotifyAuth = SpotifyAuthService();
      await spotifyAuth.initializeFromStorage();
      
      if (spotifyAuth.isAuthenticated && spotifyAuth.credentials?.sapisid == null) {
        log('Loading home data from Spotify...', name: 'HomeAddons');
        final spotify = SpotifyGqlService(spotifyAuth);
        final rawSections = await spotify.getHome(limit: 10);
        
        final sections = _mapSpotifyToSections(rawSections);
        emit(HomeAddonsLoaded(sections, source: 'spotify'));
        return;
      }
      
      log('No streaming service credentials found, falling back to plugin', name: 'HomeAddons');
      // Neither is logged in, tell UI to fall back to plugin
      emit(HomeAddonsInitial());
    } catch (e, stack) {
      log('Error loading home addons: $e\n$stack', name: 'HomeAddons');
      emit(HomeAddonsError(e.toString()));
    }
  }

  List<Section> _mapYtmToSections(List<Map<String, dynamic>> rawSections) {
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
            artists: (item['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('ytmusic', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (item['images'] as List?)?.lastOrNull?['url'] ?? '',
              layout: ImageLayout.square,
            ),
            isExplicit: false,
            durationMs: BigInt.from(item['duration_ms'] ?? 0),
          )));
        } else if (objType == 'Playlist') {
          items.add(MediaItem.playlist(PlaylistSummary(
            id: buildMediaId('ytmusic', item['id'] ?? ''),
            title: item['name'] ?? '',
            owner: item['owner']?['display_name'],
            thumbnail: Artwork(
              url: (item['images'] as List?)?.lastOrNull?['url'] ?? '',
              layout: ImageLayout.square,
            ),
          )));
        } else if (objType == 'Album') {
          items.add(MediaItem.album(AlbumSummary(
            id: buildMediaId('ytmusic', item['id'] ?? ''),
            title: item['name'] ?? '',
            artists: (item['artists'] as List?)?.map((a) => ArtistSummary(
              id: buildMediaId('ytmusic', a['id'] ?? ''),
              name: a['name'] ?? '',
            )).toList() ?? [],
            thumbnail: Artwork(
              url: (item['images'] as List?)?.lastOrNull?['url'] ?? '',
              layout: ImageLayout.square,
            ),
          )));
        } else if (objType == 'Artist') {
          items.add(MediaItem.artist(ArtistSummary(
            id: buildMediaId('ytmusic', item['id'] ?? ''),
            name: item['name'] ?? '',
            thumbnail: Artwork(
              url: (item['images'] as List?)?.lastOrNull?['url'] ?? '',
              layout: ImageLayout.circular,
            ),
          )));
        }
      }
      
      if (items.isNotEmpty) {
        sections.add(Section(
          id: raw['id'] ?? raw['title'] ?? 'unknown',
          title: raw['title'] ?? 'Section',
          cardType: CardType.carousel,
          items: items,
        ));
      }
    }
    return sections;
  }

  List<Section> _mapSpotifyToSections(List<dynamic> rawSections) {
    final sections = <Section>[];
    for (var raw in rawSections) {
      final title = raw['title'] ?? 'Home';
      final itemsRaw = raw['items'] as List?;
      if (itemsRaw == null || itemsRaw.isEmpty) continue;
      
      final items = <MediaItem>[];
      for (var itemNode in itemsRaw) {
        final typename = (itemNode['objectType'] ?? itemNode['type'] ?? itemNode['album_type'] ?? '').toString().toLowerCase();
        final id = itemNode['id'] ?? '';
        final name = itemNode['name'] ?? '';
        
        String imageUrl = '';
        if (itemNode['images'] != null && (itemNode['images'] as List).isNotEmpty) {
          imageUrl = itemNode['images'].first['url'] ?? itemNode['images'].first['sources']?.firstOrNull?['url'] ?? '';
        }

        if (typename == 'playlist') {
          items.add(MediaItem.playlist(PlaylistSummary(
            id: buildMediaId('spotify', id),
            title: name,
            thumbnail: Artwork(url: imageUrl, layout: ImageLayout.square),
            owner: itemNode['owner']?['display_name'],
          )));
        } else if (typename == 'album') {
          final artistsRaw = itemNode['artists'] as List?;
          final artists = artistsRaw?.map((a) => ArtistSummary(
            id: buildMediaId('spotify', a['id'] ?? ''),
            name: a['name'] ?? '',
          )).toList() ?? [];

          items.add(MediaItem.album(AlbumSummary(
            id: buildMediaId('spotify', id),
            title: name,
            artists: artists,
            thumbnail: Artwork(url: imageUrl, layout: ImageLayout.square),
            year: null,
          )));
        } else if (typename == 'artist') {
          items.add(MediaItem.artist(ArtistSummary(
            id: buildMediaId('spotify', id),
            name: name,
            thumbnail: Artwork(url: imageUrl, layout: ImageLayout.square),
          )));
        }
      }
      
      if (items.isNotEmpty) {
        sections.add(Section(
          id: raw['uri'] ?? title,
          title: title,
          cardType: CardType.carousel,
          items: items,
        ));
      }
    }
    return sections;
  }
}
