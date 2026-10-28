import 'dart:convert';
import 'dart:developer';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// YouTube Music Service for searching and streaming from YT Music
class YTMusicService {
  static YTMusicService? _instance;

  static const String _httpsYtmDomain = 'https://music.youtube.com';
  static const String _baseApiEndpoint = '/youtubei/v1/';
  static const String _ytmParams =
      '?alt=json&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';

  Map<String, String> _headers = {};
  Map<String, dynamic> _context = {};
  String? _visitorId;

  bool _isInitialized = false;

  YTMusicService._();

  factory YTMusicService() {
    _instance ??= YTMusicService._();
    return _instance!;
  }

  /// Initialize the service
  Future<void> init() async {
    if (_isInitialized) return;

    _headers = _initializeHeaders();
    _context = _initializeContext();

    if (!_headers.containsKey('X-Goog-Visitor-Id')) {
      _visitorId = await _getVisitorId();
      if (_visitorId != null) {
        _headers['X-Goog-Visitor-Id'] = _visitorId!;
      }
    }

    _isInitialized = true;
    print('✅ YT Music service initialized');
  }

  Map<String, String> _initializeHeaders() {
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Encoding': 'gzip, deflate',
      'Content-Type': 'application/json',
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'Cookie': 'CONSENT=YES+1',
      'Accept-Language': 'en',
    };
  }

  Map<String, dynamic> _initializeContext() {
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';

    return {
      'context': {
        'client': {
          'hl': 'en',
          'gl': 'IN',
          'clientName': 'WEB_REMIX',
          'clientVersion': '1.$date.01.00',
        },
        'user': {}
      }
    };
  }

  Future<String?> _getVisitorId() async {
    try {
      final response = await http.get(
        Uri.parse(_httpsYtmDomain),
        headers: _headers,
      );

      final reg = RegExp(r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;');
      final match = reg.firstMatch(response.body);

      if (match != null) {
        final ytcfg = json.decode(match.group(1)!);
        return ytcfg['VISITOR_DATA']?.toString();
      }
    } catch (e) {
      log('Failed to get visitor ID: $e', name: 'YTMusic');
    }
    return null;
  }

  /// Send a request to YT Music API
  Future<Map<String, dynamic>> _sendRequest(
    String endpoint,
    Map<String, dynamic> body, {
    String additionalParams = '',
    String? sapisid,
    String? cookieString,
    String? ctoken,
  }) async {
    await init();

    final requestBody = {...body, ..._context};

    String urlStr =
        '$_httpsYtmDomain$_baseApiEndpoint$endpoint$_ytmParams$additionalParams';
    if (ctoken != null) {
      urlStr += '&ctoken=$ctoken&continuation=$ctoken&type=next';
    }
    final uri = Uri.parse(urlStr);

    final reqHeaders = Map<String, String>.from(_headers);
    if (sapisid != null && cookieString != null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final message = '$timestamp $sapisid $_httpsYtmDomain';
      final hash = sha1.convert(utf8.encode(message)).toString();
      reqHeaders['Authorization'] = 'SAPISIDHASH ${timestamp}_$hash';
      reqHeaders['Cookie'] = cookieString;
    }

    try {
      final response = await http.post(
        uri,
        headers: reqHeaders,
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      log('YTMusic request failed: $e', name: 'YTMusic');
    }

    return {};
  }

  /// Get home page sections for authenticated user.
  /// Follows continuation tokens to fetch ALL sections (like ytmusicapi get_home).
  Future<List<Map<String, dynamic>>> getHome(
      String sapisid, String cookieString,
      {int limit = 100}) async {
    final allSections = <Map<String, dynamic>>[];

    // First request
    final response = await _sendRequest(
        'browse',
        {
          'browseId': 'FEmusic_home',
        },
        sapisid: sapisid,
        cookieString: cookieString);

    // Parse initial response
    final tabs = _nav(
            response, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs'])
        as List?;
    final content = tabs?.firstWhere((tab) => tab['tabRenderer'] != null,
        orElse: () => {})['tabRenderer']?['content'];
    if (content == null) return allSections;

    final sectionList = content['sectionListRenderer'];
    final initialContents = sectionList?['contents'] as List?;
    if (initialContents != null) {
      allSections.addAll(_parseSectionList(initialContents));
    }

    // Follow continuations to get all sections
    var continuations = sectionList?['continuations'] as List?;
    int page = 0;
    while (continuations != null &&
        continuations.isNotEmpty &&
        allSections.length < limit &&
        page < 15) {
      page++;
      final ctoken =
          continuations[0]['nextContinuationData']?['continuation'] as String?;
      if (ctoken == null) break;

      final contResponse = await _sendRequest('browse', {},
          sapisid: sapisid, cookieString: cookieString, ctoken: ctoken);

      // Continuation data can be in two places:
      // 1) continuationContents.sectionListContinuation
      final sectionListCont =
          contResponse['continuationContents']?['sectionListContinuation'];
      if (sectionListCont != null) {
        final contSections = sectionListCont['contents'] as List?;
        if (contSections != null) {
          allSections.addAll(_parseSectionList(contSections));
        }
        continuations = sectionListCont['continuations'] as List?;
        continue;
      }

      // 2) contents.singleColumnBrowseResultsRenderer (reloaded full page)
      final tabs2 = _nav(contResponse,
          ['contents', 'singleColumnBrowseResultsRenderer', 'tabs']) as List?;
      if (tabs2 != null) {
        // Find tabs with actual content
        for (var tab in tabs2) {
          final tabContent = tab['tabRenderer']?['content'];
          if (tabContent != null) {
            final sl2 = tabContent['sectionListRenderer'];
            final contSections2 = sl2?['contents'] as List?;
            if (contSections2 != null) {
              allSections.addAll(_parseSectionList(contSections2));
            }
            continuations = sl2?['continuations'] as List?;
            break;
          }
        }
        // If no tab had content, check appendContinuationItemsAction
        if (allSections.length <= (initialContents?.length ?? 0)) {
          final onResp = contResponse['onResponseReceivedActions'] as List?;
          if (onResp != null) {
            for (var action in onResp) {
              final items = action['appendContinuationItemsAction']
                  ?['continuationItems'] as List?;
              if (items != null) {
                allSections.addAll(_parseSectionList(items));
              }
            }
          }
          break;
        }
      } else {
        break;
      }
    }

    log('YTMusic Home: loaded ${allSections.length} sections over ${page + 1} pages',
        name: 'YTMusic');
    return allSections;
  }

  /// Parse a raw list of section items into structured section data.
  /// Matches the ytmusicapi Python pattern for extracting home shelves.
  List<Map<String, dynamic>> _parseSectionList(List sections) {
    final result = <Map<String, dynamic>>[];
    try {
      for (var section in sections) {
        var shelf = section['musicCarouselShelfRenderer'];
        shelf ??= section['musicImmersiveCarouselShelfRenderer'];
        if (shelf == null) continue;

        final headerRenderer = shelf['header']
                ?['musicCarouselShelfBasicHeaderRenderer'] ??
            shelf['header']?['musicImmersiveCarouselShelfBasicHeaderRenderer'];
        final titleRuns = headerRenderer?['title']?['runs'] as List?;
        final sectionTitle =
            titleRuns?.firstOrNull?['text'] as String? ?? 'Home';

        final items = shelf['contents'] as List?;
        if (items == null) continue;

        final parsedItems = <Map<String, dynamic>>[];
        for (var item in items) {
          Map<String, dynamic>? parsed;
          if (item.containsKey('musicTwoRowItemRenderer')) {
            parsed = _parseTwoRowItem(item['musicTwoRowItemRenderer']);
          } else if (item.containsKey('musicResponsiveListItemRenderer')) {
            parsed = _parseFlatSong(item['musicResponsiveListItemRenderer']);
          }
          if (parsed != null) {
            parsedItems.add(parsed);
          }
        }

        if (parsedItems.isNotEmpty) {
          result.add({
            'id': sectionTitle.replaceAll(' ', '_'),
            'uri': sectionTitle.replaceAll(' ', '_'),
            'title': sectionTitle,
            'items': parsedItems,
          });
        }
      }
    } catch (e) {
      log('YTMusic parse sections error: $e', name: 'YTMusic');
    }
    return result;
  }

  /// Parse a musicTwoRowItemRenderer (albums, playlists, artists, videos).
  /// Uses pageType from browseEndpoint for reliable type detection.
  Map<String, dynamic>? _parseTwoRowItem(Map<String, dynamic> renderer) {
    final titleRun = _nav(renderer, ['title', 'runs', 0]);
    if (titleRun == null) return null;

    final itemName = titleRun['text'] as String? ?? '';
    final navEndpoint =
        renderer['navigationEndpoint'] ?? titleRun['navigationEndpoint'];

    // Detect type using pageType (most reliable, matches ytmusicapi Python)
    final pageType = _nav(navEndpoint, [
      'browseEndpoint',
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType'
    ]) as String?;
    final watchVideoId =
        _nav(navEndpoint, ['watchEndpoint', 'videoId']) as String?;
    final watchPlaylistId =
        _nav(navEndpoint, ['watchPlaylistEndpoint', 'playlistId']) as String?;
    final browseId =
        _nav(navEndpoint, ['browseEndpoint', 'browseId']) as String? ?? '';

    String objectType;
    String id;

    if (watchVideoId != null) {
      // Song or music video
      objectType = 'Track';
      id = watchVideoId;
    } else if (watchPlaylistId != null &&
        (pageType == null || pageType.isEmpty)) {
      // Watch playlist (radio/mix) — no pageType means it's not a browsable playlist
      objectType = 'Playlist';
      id = watchPlaylistId;
    } else if (pageType == 'MUSIC_PAGE_TYPE_PLAYLIST') {
      objectType = 'Playlist';
      id = browseId.startsWith('VL') ? browseId.substring(2) : browseId;
    } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
        pageType == 'MUSIC_PAGE_TYPE_AUDIOBOOK') {
      objectType = 'Album';
      id = browseId;
    } else if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
        pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
      objectType = 'Artist';
      id = browseId;
    } else if (browseId.startsWith('VL') ||
        browseId.startsWith('RD') ||
        browseId.startsWith('PL')) {
      objectType = 'Playlist';
      id = browseId;
    } else if (browseId.startsWith('MPRE')) {
      objectType = 'Album';
      id = browseId;
    } else if (browseId.startsWith('UC')) {
      objectType = 'Artist';
      id = browseId;
    } else {
      objectType = 'Unknown';
      id = browseId;
    }

    if (id.isEmpty) return null;

    final images = _getThumbnails(renderer);
    final subRuns = _nav(renderer, ['subtitle', 'runs']) as List? ?? [];
    final description = subRuns.map((r) => r['text'] as String).join('');

    // Extract artists from subtitle runs
    final artists = <Map<String, dynamic>>[];
    for (var run in subRuns) {
      final runBrowseId =
          _nav(run, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
              as String?;
      if (runBrowseId != null &&
          (runBrowseId.startsWith('UC') || runBrowseId.startsWith('FE'))) {
        artists
            .add({'id': runBrowseId, 'uri': runBrowseId, 'name': run['text']});
      }
    }

    return {
      'objectType': objectType,
      'id': id,
      'uri': id,
      'name': itemName,
      'description': description,
      'images': images,
      if (objectType == 'Playlist')
        'owner': {'id': '', 'display_name': description, 'images': []},
      if (artists.isNotEmpty) 'artists': artists,
      if (objectType == 'Track') 'videoId': id,
    };
  }

  /// Parse a musicResponsiveListItemRenderer (flat song in Quick Picks etc).
  /// Matches the ytmusicapi parseFlatSong pattern.
  Map<String, dynamic>? _parseFlatSong(Map<String, dynamic> renderer) {
    final flexColumns = renderer['flexColumns'] as List? ?? [];

    // Extract title
    final title = _nav(flexColumns.firstOrNull, [
          'musicResponsiveListItemFlexColumnRenderer',
          'text',
          'runs',
          0,
          'text'
        ]) as String? ??
        '';

    // Extract videoId from multiple locations
    String videoId = '';
    videoId = _nav(flexColumns.firstOrNull, [
          'musicResponsiveListItemFlexColumnRenderer',
          'text',
          'runs',
          0,
          'navigationEndpoint',
          'watchEndpoint',
          'videoId'
        ]) as String? ??
        '';
    if (videoId.isEmpty) {
      videoId = renderer['playlistItemData']?['videoId'] as String? ?? '';
    }
    if (videoId.isEmpty) {
      videoId = _nav(renderer, [
            'overlay',
            'musicItemThumbnailOverlayRenderer',
            'content',
            'musicPlayButtonRenderer',
            'playNavigationEndpoint',
            'watchEndpoint',
            'videoId'
          ]) as String? ??
          '';
    }

    if (videoId.isEmpty && title.isEmpty) return null;

    // Parse artists from flex column 1
    final artistRuns = _nav(flexColumns.length > 1 ? flexColumns[1] : null, [
          'musicResponsiveListItemFlexColumnRenderer',
          'text',
          'runs'
        ]) as List? ??
        [];

    final artists = <Map<String, dynamic>>[];
    for (var run in artistRuns) {
      final aBrowseId =
          _nav(run, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
              as String?;
      if (aBrowseId != null && run['text'] != null) {
        artists.add({'id': aBrowseId, 'uri': aBrowseId, 'name': run['text']});
      }
    }
    final subtitle = artistRuns.map((r) => r['text'] as String).join('');

    // If no artists found, use full subtitle
    if (artists.isEmpty && subtitle.isNotEmpty) {
      final firstPart = subtitle.split(' • ').first.split(' & ').first;
      artists.add({'id': '', 'uri': '', 'name': firstPart});
    }

    // Parse album from flex column 2
    Map<String, dynamic>? album;
    if (flexColumns.length > 2) {
      final albumRun = _nav(flexColumns[2],
          ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs', 0]);
      if (albumRun != null) {
        album = {
          'name': albumRun['text'] ?? '',
          'id': _nav(albumRun, [
                'navigationEndpoint',
                'browseEndpoint',
                'browseId'
              ]) as String? ??
              '',
        };
      }
    }

    // Thumbnails
    final images = _nav(renderer, [
          'thumbnail',
          'musicThumbnailRenderer',
          'thumbnail',
          'thumbnails'
        ]) as List? ??
        [];

    // Duration
    final durationText = _nav(renderer, [
      'fixedColumns',
      0,
      'musicResponsiveListItemFixedColumnRenderer',
      'text',
      'runs',
      0,
      'text'
    ]) as String?;
    int durationMs = 0;
    if (durationText != null) {
      durationMs = _parseDuration(durationText);
    }

    return {
      'objectType': 'Track',
      'id': videoId.isNotEmpty ? videoId : title.hashCode.toString(),
      'uri': videoId,
      'name': title,
      'description': subtitle,
      'videoId': videoId,
      'duration_ms': durationMs,
      'images': images
          .map((img) => {
                'url': img['url'] ?? '',
                'width': img['width'] ?? 0,
                'height': img['height'] ?? 0,
              })
          .toList(),
      if (artists.isNotEmpty) 'artists': artists,
      if (album != null)
        'album': {
          'id': album['id'],
          'name': album['name'],
          'images': images
              .map((img) => {
                    'url': img['url'] ?? '',
                    'width': img['width'] ?? 0,
                    'height': img['height'] ?? 0,
                  })
              .toList(),
        },
    };
  }

  /// Get thumbnails from a renderer (handles both thumbnailRenderer and thumbnail paths)
  List<Map<String, dynamic>> _getThumbnails(Map<String, dynamic> renderer) {
    List? raw;
    if (renderer.containsKey('thumbnailRenderer')) {
      raw = _nav(renderer, [
        'thumbnailRenderer',
        'musicThumbnailRenderer',
        'thumbnail',
        'thumbnails'
      ]) as List?;
    } else if (renderer.containsKey('thumbnail')) {
      raw = _nav(renderer, [
        'thumbnail',
        'musicThumbnailRenderer',
        'thumbnail',
        'thumbnails'
      ]) as List?;
    }
    raw ??= [];
    return raw
        .map((img) => <String, dynamic>{
              'url': img['url'] ?? '',
              'width': img['width'] ?? 0,
              'height': img['height'] ?? 0,
            })
        .toList();
  }

  /// Get playlist, album, or artist tracks
  Future<Map<String, dynamic>> getPlaylist(String browseId,
      {String? sapisid, String? cookieString}) async {
    // UC browseIds are artist/channel pages — fetch their top songs instead
    if (browseId.startsWith('UC')) {
      log('YTMusic getPlaylist: routing UC browseId to artist songs',
          name: 'YTMusic');
      return _getArtistSongs(browseId,
          sapisid: sapisid, cookieString: cookieString);
    }

    String reqId = browseId;
    // Only add VL prefix for actual playlist IDs, NOT album browseIds
    final isAlbumBrowseId = reqId.startsWith('MPRE');
    if (!isAlbumBrowseId &&
        !reqId.startsWith('VL') &&
        !reqId.startsWith('OLAK')) {
      reqId = 'VL$reqId';
    }

    log('YTMusic getPlaylist: browseId=$browseId reqId=$reqId',
        name: 'YTMusic');

    final response = await _sendRequest(
        'browse',
        {
          'browseId': reqId,
        },
        sapisid: sapisid,
        cookieString: cookieString);

    return _parsePlaylistContents(response, browseId);
  }

  /// Browse an artist/channel page and extract their songs
  /// Matches TypeScript extractChannelSongs: checks both musicShelfRenderer
  /// (flat song lists) and musicCarouselShelfRenderer (carousel two-row items)
  Future<Map<String, dynamic>> _getArtistSongs(String channelId,
      {String? sapisid, String? cookieString}) async {
    final response = await _sendRequest(
        'browse',
        {
          'browseId': channelId,
        },
        sapisid: sapisid,
        cookieString: cookieString);

    try {
      // Extract artist name from header
      final header = response['header']?['musicImmersiveHeaderRenderer'] ??
          response['header']?['musicVisualHeaderRenderer'] ??
          response['header']?['musicHeaderRenderer'] ??
          response['header']?['musicResponsiveHeaderRenderer'];
      final artistName =
          _nav(header, ['title', 'runs', 0, 'text']) as String? ?? 'Artist';
      final headerThumbs = _nav(header, [
            'thumbnail',
            'musicThumbnailRenderer',
            'thumbnail',
            'thumbnails'
          ]) as List? ??
          [];
      final imageUrl = headerThumbs.lastOrNull?['url'] as String?;

      // Find sections from singleColumnBrowseResultsRenderer
      final tabs = _nav(response,
          ['contents', 'singleColumnBrowseResultsRenderer', 'tabs']) as List?;

      final tracks = <Map<String, dynamic>>[];

      if (tabs != null) {
        for (var tab in tabs) {
          final sectionList = _nav(tab, [
            'tabRenderer',
            'content',
            'sectionListRenderer',
            'contents'
          ]) as List?;
          if (sectionList == null) continue;

          for (var section in sectionList) {
            // 1. musicShelfRenderer: flat song lists (top songs)
            final musicShelf = section['musicShelfRenderer'];
            if (musicShelf != null) {
              final contents = musicShelf['contents'] as List? ?? [];
              for (var item in contents) {
                final renderer = item['musicResponsiveListItemRenderer'];
                if (renderer == null) continue;
                final track = _parseChannelTrack(
                    renderer, channelId, artistName, imageUrl);
                if (track != null) tracks.add(track);
              }
            }

            // 2. musicCarouselShelfRenderer: carousel with two-row items
            final carousel = section['musicCarouselShelfRenderer'];
            if (carousel != null) {
              final contents = carousel['contents'] as List? ?? [];
              for (var item in contents) {
                // Two-row items (songs, videos, albums)
                final twoRow = item['musicTwoRowItemRenderer'];
                if (twoRow != null) {
                  final parsed = _parseTwoRowItem(twoRow);
                  if (parsed != null && parsed['objectType'] == 'Track') {
                    tracks.add({
                      'id': parsed['id'],
                      'uri': parsed['id'],
                      'name': parsed['name'],
                      'duration_ms': parsed['duration_ms'] ?? 0,
                      'album': {
                        'id': channelId,
                        'name': artistName,
                        'images': parsed['images'] ?? [],
                      },
                      'artists': parsed['artists'] ??
                          [
                            {'id': channelId, 'name': artistName}
                          ],
                    });
                  }
                }

                // Also try flat list items inside carousels
                final listItem = item['musicResponsiveListItemRenderer'];
                if (listItem != null) {
                  final track = _parseChannelTrack(
                      listItem, channelId, artistName, imageUrl);
                  if (track != null) tracks.add(track);
                }
              }
            }
          }
        }
      }

      log('YTMusic artist $artistName: ${tracks.length} songs extracted',
          name: 'YTMusic');

      return {
        'items': tracks,
        'total': tracks.length,
        'offset': 0,
        'limit': tracks.length,
      };
    } catch (e) {
      log('YTMusic parse artist error: $e', name: 'YTMusic');
      return {'items': [], 'total': 0, 'offset': 0, 'limit': 0};
    }
  }

  /// Parse a single track from a channel/artist musicResponsiveListItemRenderer
  Map<String, dynamic>? _parseChannelTrack(Map<String, dynamic> renderer,
      String channelId, String artistName, String? fallbackImageUrl) {
    String? videoId;
    videoId = renderer['playlistItemData']?['videoId'] as String?;
    videoId ??= _nav(renderer, [
      'overlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchEndpoint',
      'videoId'
    ]) as String?;
    videoId ??= _nav(renderer, [
      'flexColumns',
      0,
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
      0,
      'navigationEndpoint',
      'watchEndpoint',
      'videoId'
    ]) as String?;
    if (videoId == null) return null;

    final flexColumns = renderer['flexColumns'] as List? ?? [];
    final trackName = _nav(flexColumns.firstOrNull, [
          'musicResponsiveListItemFlexColumnRenderer',
          'text',
          'runs',
          0,
          'text'
        ]) as String? ??
        'Unknown';

    // Artist from subtitle runs
    String artist = artistName;
    if (flexColumns.length > 1) {
      final artistRuns = _nav(flexColumns[1], [
            'musicResponsiveListItemFlexColumnRenderer',
            'text',
            'runs'
          ]) as List? ??
          [];
      final names = <String>[];
      for (var run in artistRuns) {
        final browseId =
            _nav(run, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
                as String?;
        if (browseId != null && browseId.startsWith('UC')) {
          names.add(run['text'] as String);
        }
      }
      if (names.isNotEmpty) artist = names.join(', ');
    }

    // Duration from fixedColumns
    int durationMs = 0;
    final durationText = _nav(renderer, [
      'fixedColumns',
      0,
      'musicResponsiveListItemFixedColumnRenderer',
      'text',
      'runs',
      0,
      'text'
    ]) as String?;
    if (durationText != null && RegExp(r'^\d+:\d+').hasMatch(durationText)) {
      durationMs = _parseDuration(durationText);
    }

    final trackImages = _nav(renderer, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails'
    ]) as List?;
    final trackImageUrl =
        trackImages?.lastOrNull?['url'] as String? ?? fallbackImageUrl;

    return {
      'id': videoId,
      'uri': videoId,
      'name': trackName,
      'duration_ms': durationMs,
      'album': {
        'id': channelId,
        'name': artistName,
        'images': trackImageUrl != null
            ? [
                {'url': trackImageUrl}
              ]
            : [],
      },
      'artists': [
        {'id': channelId, 'name': artist}
      ],
    };
  }

  Map<String, dynamic> _parsePlaylistContents(
      Map<String, dynamic> data, String browseId) {
    try {
      // --- Extract header from multiple possible renderer types ---
      // 1. musicDetailHeaderRenderer (standard playlists)
      var header = data['header']?['musicDetailHeaderRenderer'];
      // 2. Editable playlist header
      header ??= data['header']?['musicEditablePlaylistDetailHeaderRenderer']
          ?['header']?['musicDetailHeaderRenderer'];
      // 3. musicImmersiveHeaderRenderer (albums)
      header ??= data['header']?['musicImmersiveHeaderRenderer'];
      // 4. musicVisualHeaderRenderer (some albums)
      header ??= data['header']?['musicVisualHeaderRenderer'];
      // 5. musicResponsiveHeaderRenderer (albums in twoColumn layout)
      if (header == null) {
        final twoCol = data['contents']?['twoColumnBrowseResultsRenderer'];
        final headerSection = _nav(twoCol, [
          'tabs',
          0,
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
          0
        ]);
        header = headerSection?['musicResponsiveHeaderRenderer'] ??
            headerSection?['musicEditablePlaylistDetailHeaderRenderer']
                ?['header']?['musicResponsiveHeaderRenderer'];
      }
      // 6. Top-level musicResponsiveHeaderRenderer
      header ??= data['header']?['musicResponsiveHeaderRenderer'];

      final title =
          _nav(header, ['title', 'runs', 0, 'text']) as String? ?? 'Playlist';

      // Extract thumbnails from various header shapes
      final thumbnails = _nav(header, [
            'thumbnail',
            'croppedSquareThumbnailRenderer',
            'thumbnail',
            'thumbnails'
          ]) as List? ??
          _nav(header, [
            'thumbnail',
            'musicThumbnailRenderer',
            'thumbnail',
            'thumbnails'
          ]) as List? ??
          _nav(header, [
            'foregroundThumbnail',
            'musicThumbnailRenderer',
            'thumbnail',
            'thumbnails'
          ]) as List? ??
          [];
      final imageUrl = thumbnails.lastOrNull?['url'] as String?;

      // --- Extract tracks from multiple possible response structures ---
      List? contentsRaw;

      // Path 1: singleColumn → musicPlaylistShelfRenderer
      contentsRaw = _nav(data, [
        'contents',
        'singleColumnBrowseResultsRenderer',
        'tabs',
        0,
        'tabRenderer',
        'content',
        'sectionListRenderer',
        'contents',
        0,
        'musicPlaylistShelfRenderer',
        'contents'
      ]) as List?;

      // Path 2: singleColumn → musicShelfRenderer (used by albums)
      contentsRaw ??= _nav(data, [
        'contents',
        'singleColumnBrowseResultsRenderer',
        'tabs',
        0,
        'tabRenderer',
        'content',
        'sectionListRenderer',
        'contents',
        0,
        'musicShelfRenderer',
        'contents'
      ]) as List?;

      // Path 3: twoColumn → secondaryContents (community playlists)
      if (contentsRaw == null) {
        final secondaryContents = _nav(data, [
          'contents',
          'twoColumnBrowseResultsRenderer',
          'secondaryContents',
          'sectionListRenderer',
          'contents'
        ]) as List?;

        if (secondaryContents != null) {
          for (var section in secondaryContents) {
            final shelf = section['musicPlaylistShelfRenderer'] ??
                section['musicShelfRenderer'];
            if (shelf != null && shelf['contents'] != null) {
              contentsRaw = shelf['contents'] as List;
              break;
            }
          }
        }
      }

      // Path 4: twoColumn → tabs (albums in twoColumn layout)
      if (contentsRaw == null) {
        final twoColTabs =
            _nav(data, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs'])
                as List?;
        if (twoColTabs != null) {
          for (var tab in twoColTabs) {
            final sectionList = _nav(tab, [
              'tabRenderer',
              'content',
              'sectionListRenderer',
              'contents'
            ]) as List?;
            if (sectionList == null) continue;
            for (var section in sectionList) {
              final shelf = section['musicShelfRenderer'] ??
                  section['musicPlaylistShelfRenderer'];
              if (shelf != null && shelf['contents'] != null) {
                contentsRaw = shelf['contents'] as List;
                break;
              }
            }
            if (contentsRaw != null) break;
          }
        }
      }

      final tracks = <Map<String, dynamic>>[];
      if (contentsRaw != null) {
        for (var item in contentsRaw) {
          final renderer = item['musicResponsiveListItemRenderer'];
          if (renderer == null) continue;

          // Extract videoId from multiple locations
          String? videoId;
          videoId = renderer['playlistItemData']?['videoId'] as String?;
          videoId ??= _nav(renderer, [
            'overlay',
            'musicItemThumbnailOverlayRenderer',
            'content',
            'musicPlayButtonRenderer',
            'playNavigationEndpoint',
            'watchEndpoint',
            'videoId'
          ]) as String?;
          if (videoId == null) continue;

          final flexColumns = renderer['flexColumns'] as List? ?? [];
          final trackName = _nav(flexColumns.firstOrNull, [
                'musicResponsiveListItemFlexColumnRenderer',
                'text',
                'runs',
                0,
                'text'
              ]) as String? ??
              'Unknown';

          String artist = '';
          int durationMs = 0;
          if (flexColumns.length > 1) {
            final subRuns = _nav(flexColumns[1], [
                  'musicResponsiveListItemFlexColumnRenderer',
                  'text',
                  'runs'
                ]) as List? ??
                [];
            artist = subRuns
                .where((r) =>
                    r['navigationEndpoint'] != null &&
                    _nav(r, [
                          'navigationEndpoint',
                          'browseEndpoint',
                          'browseId'
                        ])?.toString().startsWith('UC') ==
                        true)
                .map((r) => r['text'] as String)
                .join(', ');
            if (artist.isEmpty) {
              artist = subRuns.firstOrNull?['text'] as String? ?? 'Unknown';
            }
          }

          // Duration from fixedColumns (more reliable) or flex column runs
          final durationText = _nav(renderer, [
            'fixedColumns',
            0,
            'musicResponsiveListItemFixedColumnRenderer',
            'text',
            'runs',
            0,
            'text'
          ]) as String?;
          if (durationText != null &&
              RegExp(r'^\d+:\d+').hasMatch(durationText)) {
            durationMs = _parseDuration(durationText);
          } else if (flexColumns.length > 1) {
            final subRuns = _nav(flexColumns[1], [
                  'musicResponsiveListItemFlexColumnRenderer',
                  'text',
                  'runs'
                ]) as List? ??
                [];
            final durStr = subRuns.lastOrNull?['text'] as String?;
            if (durStr != null && RegExp(r'^\d+:\d+').hasMatch(durStr)) {
              durationMs = _parseDuration(durStr);
            }
          }

          List? trackImages;
          if (renderer.containsKey('thumbnail')) {
            trackImages = _nav(renderer, [
              'thumbnail',
              'musicThumbnailRenderer',
              'thumbnail',
              'thumbnails'
            ]) as List?;
          }
          final trackImageUrl =
              trackImages?.lastOrNull?['url'] as String? ?? imageUrl;

          tracks.add({
            'id': videoId,
            'uri': videoId,
            'name': trackName,
            'duration_ms': durationMs,
            'album': {
              'id': browseId,
              'name': title,
              'images': trackImageUrl != null
                  ? [
                      {'url': trackImageUrl}
                    ]
                  : [],
            },
            'artists': [
              {'id': '', 'name': artist}
            ],
          });
        }
      }

      log('YTMusic parsed ${tracks.length} tracks from $browseId',
          name: 'YTMusic');

      return {
        'title': title,
        'thumbnails': thumbnails,
        'items': tracks,
        'total': tracks.length,
        'offset': 0,
        'limit': tracks.length,
      };
    } catch (e) {
      log('YTMusic parse playlist error: $e', name: 'YTMusic');
      return {'items': [], 'total': 0, 'offset': 0, 'limit': 0};
    }
  }

  /// Search for songs on YT Music
  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    await init();

    final results = await _sendRequest('search', {
      'query': query,
      'params': 'EgWKAQIIAWoKEAMQBBAKEAkQBQ%3D%3D', // Songs filter
    });

    return _parseSearchResults(results);
  }

  /// Search with match for track + artist
  Future<String?> searchTrack(String trackName, String artistName,
      {int? durationMs}) async {
    await init();

    final query = '$trackName $artistName';
    final songs = await searchSongs(query);

    if (songs.isEmpty) return null;

    // Try to find best match based on duration if provided
    if (durationMs != null) {
      for (final song in songs) {
        final songDuration = song['duration_ms'] as int? ?? 0;
        // Allow 5 second difference
        if ((songDuration - durationMs).abs() < 5000) {
          return song['videoId'] as String?;
        }
      }
    }

    // Return first result
    return songs.firstOrNull?['videoId'] as String?;
  }

  List<Map<String, dynamic>> _parseSearchResults(Map<String, dynamic> data) {
    final songs = <Map<String, dynamic>>[];

    try {
      final contents = _nav(data, [
        'contents',
        'tabbedSearchResultsRenderer',
        'tabs',
        0,
        'tabRenderer',
        'content',
        'sectionListRenderer',
        'contents',
      ]) as List?;

      if (contents == null) return songs;

      for (final section in contents) {
        final items = _nav(section, [
          'musicShelfRenderer',
          'contents',
        ]) as List?;

        if (items == null) continue;

        for (final item in items) {
          try {
            final songData = _parseSongItem(item);
            if (songData != null) {
              songs.add(songData);
            }
          } catch (e) {
            log('Parse song error: $e', name: 'YTMusic');
          }
        }
      }
    } catch (e) {
      log('Parse results error: $e', name: 'YTMusic');
    }

    return songs;
  }

  Map<String, dynamic>? _parseSongItem(Map<String, dynamic> item) {
    final renderer = item['musicResponsiveListItemRenderer'];
    if (renderer == null) return null;

    final flexColumns = renderer['flexColumns'] as List?;
    if (flexColumns == null || flexColumns.isEmpty) return null;

    // Get video ID
    final overlay = renderer['overlay'];
    final playNavigationEndpoint = _nav(overlay, [
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
    ]) as Map?;

    final videoId = _nav(playNavigationEndpoint, [
      'watchEndpoint',
      'videoId',
    ]) as String?;

    if (videoId == null) return null;

    // Get title
    final titleRuns = _nav(flexColumns, [
      0,
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]) as List?;
    final title = titleRuns?.firstOrNull?['text'] as String? ?? '';

    // Get artist
    String artist = '';
    if (flexColumns.length > 1) {
      final artistRuns = _nav(flexColumns, [
        1,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]) as List?;

      if (artistRuns != null && artistRuns.isNotEmpty) {
        artist = artistRuns.map((r) => r['text']).join('');
      }
    }

    // Get thumbnail
    final thumbnails = _nav(renderer, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]) as List?;
    final thumbnail = thumbnails?.lastOrNull?['url'] as String?;

    // Get duration
    final durationText = _nav(flexColumns, [
      1,
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]) as List?;

    int durationMs = 0;
    if (durationText != null) {
      for (final run in durationText) {
        final text = run['text'] as String? ?? '';
        if (RegExp(r'^\d+:\d+').hasMatch(text)) {
          durationMs = _parseDuration(text);
          break;
        }
      }
    }

    return {
      'videoId': videoId,
      'title': title,
      'artist': artist,
      'thumbnail': thumbnail,
      'duration_ms': durationMs,
      'perma_url': 'https://music.youtube.com/watch?v=$videoId',
    };
  }

  int _parseDuration(String duration) {
    final parts = duration.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length == 2) {
      return (parts[0] * 60 + parts[1]) * 1000;
    } else if (parts.length == 3) {
      return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000;
    }
    return 0;
  }

  dynamic _nav(dynamic root, List<dynamic> items) {
    try {
      for (final k in items) {
        root = root?[k];
      }
      return root;
    } catch (e) {
      return null;
    }
  }

  /// Get related songs for a video
  Future<List<Map<String, dynamic>>> getRelatedSongs(String videoId) async {
    await init();

    final results = await _sendRequest('next', {
      'videoId': videoId,
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
    });

    return _parseRelatedSongs(results);
  }

  List<Map<String, dynamic>> _parseRelatedSongs(Map<String, dynamic> data) {
    final songs = <Map<String, dynamic>>[];

    try {
      final tabs = _nav(data, [
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer',
        'tabs',
      ]) as List?;

      if (tabs == null) return songs;

      for (final tab in tabs) {
        final content = _nav(tab, [
          'tabRenderer',
          'content',
          'musicQueueRenderer',
          'content',
          'playlistPanelRenderer',
          'contents',
        ]) as List?;

        if (content == null) continue;

        for (final item in content) {
          final renderer = item['playlistPanelVideoRenderer'];
          if (renderer == null) continue;

          final videoId = renderer['videoId'] as String?;
          if (videoId == null) continue;

          final title =
              _nav(renderer, ['title', 'runs', 0, 'text']) as String? ?? '';

          final longText = _nav(renderer, ['longBylineText', 'runs']) as List?;
          String artist = '';
          if (longText != null) {
            artist = longText.map((r) => r['text']).join('');
          }

          final thumbnails =
              _nav(renderer, ['thumbnail', 'thumbnails']) as List?;
          final thumbnail = thumbnails?.lastOrNull?['url'] as String?;

          songs.add({
            'videoId': videoId,
            'title': title,
            'artist': artist,
            'thumbnail': thumbnail,
            'perma_url': 'https://music.youtube.com/watch?v=$videoId',
          });
        }
      }
    } catch (e) {
      log('Parse related error: $e', name: 'YTMusic');
    }

    return songs;
  }

  /// Get watch playlist data for a video (matches ytmusicapi get_watch_playlist).
  /// Returns Up Next tracks, playlistId, and browseIds for lyrics/related tabs.
  Future<Map<String, dynamic>> getWatchPlaylist(String videoId,
      {String? playlistId, int limit = 25}) async {
    await init();

    final body = <String, dynamic>{
      'videoId': videoId,
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      'playlistId': playlistId ?? 'RDAMVM$videoId',
    };

    final results = await _sendRequest('next', body);

    final watchPlaylist = <String, dynamic>{
      'tracks': <Map<String, dynamic>>[],
      'playlistId': null,
      'lyrics': null,
      'related': null,
    };

    try {
      final tabs = _nav(results, [
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer',
        'tabs',
      ]) as List?;
      if (tabs == null) return watchPlaylist;

      // Extract lyrics and related browseIds from tab endpoints
      for (int i = 0; i < tabs.length; i++) {
        final tabRenderer = tabs[i]['tabRenderer'];
        if (tabRenderer == null) continue;
        final browseId =
            _nav(tabRenderer, ['endpoint', 'browseEndpoint', 'browseId'])
                as String?;
        if (browseId == null) continue;
        if (browseId.startsWith('MPLYt')) {
          watchPlaylist['lyrics'] = browseId;
        } else if (browseId.startsWith('MPRE') ||
            browseId.contains('related')) {
          watchPlaylist['related'] = browseId;
        } else {
          // The related tab usually is the last one with a browseId
          watchPlaylist['related'] ??= browseId;
        }
      }

      // Extract Up Next tracks from first tab (queue)
      final queueContent = _nav(tabs.first, [
        'tabRenderer',
        'content',
        'musicQueueRenderer',
        'content',
        'playlistPanelRenderer',
      ]) as Map<String, dynamic>?;

      if (queueContent != null) {
        watchPlaylist['playlistId'] = queueContent['playlistId'] as String?;

        final contents = queueContent['contents'] as List? ?? [];
        int count = 0;
        for (final item in contents) {
          if (count >= limit) break;
          final renderer = item['playlistPanelVideoRenderer'];
          if (renderer == null) continue;

          final vid = renderer['videoId'] as String?;
          if (vid == null) continue;

          final title =
              _nav(renderer, ['title', 'runs', 0, 'text']) as String? ?? '';
          final longText = _nav(renderer, ['longBylineText', 'runs']) as List?;
          String artist = '';
          if (longText != null) {
            artist = longText.map((r) => r['text']).join('');
          }
          final thumbnails =
              _nav(renderer, ['thumbnail', 'thumbnails']) as List?;
          final thumbnail = thumbnails?.lastOrNull?['url'] as String?;
          final lengthText =
              _nav(renderer, ['lengthText', 'runs', 0, 'text']) as String?;
          int durationMs = 0;
          if (lengthText != null) durationMs = _parseDuration(lengthText);

          watchPlaylist['tracks'].add({
            'videoId': vid,
            'title': title,
            'artist': artist,
            'thumbnail': thumbnail,
            'duration_ms': durationMs,
          });
          count++;
        }
      }

      log(
          'YTMusic watchPlaylist: ${(watchPlaylist['tracks'] as List).length} tracks, '
          'related=${watchPlaylist['related']}',
          name: 'YTMusic');
    } catch (e) {
      log('getWatchPlaylist error: $e', name: 'YTMusic');
    }
    return watchPlaylist;
  }

  /// Get related content for a song (matches ytmusicapi get_song_related).
  /// Uses the browseId from getWatchPlaylist['related'].
  /// Returns sections: songs, playlists, artists, about.
  Future<List<Map<String, dynamic>>> getSongRelated(String browseId) async {
    await init();

    final response = await _sendRequest('browse', {
      'browseId': browseId,
    });

    final sections = <Map<String, dynamic>>[];

    try {
      final sectionList =
          _nav(response, ['contents', 'sectionListRenderer', 'contents'])
              as List?;
      if (sectionList == null) return sections;

      for (final section in sectionList) {
        // Carousel shelf (songs, playlists, artists, albums)
        final carousel = section['musicCarouselShelfRenderer'];
        if (carousel != null) {
          final headerRuns = _nav(carousel, [
            'header',
            'musicCarouselShelfBasicHeaderRenderer',
            'title',
            'runs'
          ]) as List?;
          final sectionTitle = headerRuns?.map((r) => r['text']).join('') ?? '';

          final items = <Map<String, dynamic>>[];
          final contents = carousel['contents'] as List? ?? [];
          for (final item in contents) {
            // Two-row items (songs, albums, playlists, artists)
            final twoRow = item['musicTwoRowItemRenderer'];
            if (twoRow != null) {
              final parsed = _parseTwoRowItem(twoRow);
              if (parsed != null) items.add(parsed);
              continue;
            }
            // Responsive list items (flat songs)
            final listItem = item['musicResponsiveListItemRenderer'];
            if (listItem != null) {
              final parsed = _parseFlatSong(listItem);
              if (parsed != null) items.add(parsed);
            }
          }

          sections.add({
            'title': sectionTitle,
            'contents': items,
          });
          continue;
        }

        // Description shelf (about the artist)
        final descShelf = section['musicDescriptionShelfRenderer'];
        if (descShelf != null) {
          final title =
              _nav(descShelf, ['header', 'runs', 0, 'text']) as String? ?? '';
          final description =
              _nav(descShelf, ['description', 'runs', 0, 'text']) as String? ??
                  '';
          sections.add({
            'title': title,
            'contents': description,
          });
        }
      }

      log('YTMusic songRelated: ${sections.length} sections', name: 'YTMusic');
    } catch (e) {
      log('getSongRelated error: $e', name: 'YTMusic');
    }

    return sections;
  }
}
