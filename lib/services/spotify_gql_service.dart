import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'package:http/http.dart' as http;
import 'spotify_auth_service.dart';

/// Spotify API Service using GraphQL
/// Uses Web Player cookie authentication with partner API
class SpotifyGqlService {
  final SpotifyAuthService _authService;

  static const String _gqlEndpoint =
      'https://api-partner.spotify.com/pathfinder/v2/query';

  /// GraphQL query hashes
  static const _hashes = {
    'searchDesktop':
        '4801118d4a100f756e833d33984436a3899cff359c532f8fd3aaf174b60b3b49',
    'searchTracks':
        'bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428',
    'searchAlbums':
        'a71d2c993fc98e1c880093738a55a38b57e69cc4ce5a8c113e6c5920f9513ee2',
    'searchArtists':
        '0e6f9020a66fe15b93b3bb5c7e6484d1d8cb3775963996eaede72bac4d97e909',
    'searchPlaylists':
        'fc3a690182167dbad20ac7a03f842b97be4e9737710600874cb903f30112ad58',
    'fetchPlaylist':
        'bb67e0af06e8d6f52b531f97468ee4acd44cd0f82b988e15c2ea47b1148efc77',
    'getTrack':
        '612585ae06ba435ad26369870deaae23b5c8800a256cd8a57e08eddc25a37294',
    'profileAttributes':
        '53bcb064f6cd18c23f752bc324a791194d20df612d8e1239c735144ab0399ced',
    'fetchLibraryTracks':
        '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240',
    'libraryV3':
        '2de10199b2441d6e4ae875f27d2db361020c399fb10b03951120223fbed10b08',
    'isCurated':
        'e4ed1f91a2cc5415befedb85acf8671dc1a4bf3ca1a5b945a6386101a22e28a6',
    'addToLibrary':
        'a3c1ff58e6a36fec5fe1e3a193dc95d9071d96b9ba53c5ba9c1494fb1ee73915',
    'removeFromLibrary':
        'a3c1ff58e6a36fec5fe1e3a193dc95d9071d96b9ba53c5ba9c1494fb1ee73915',
    // Browse/Home hashes
    'home': 'd62af2714f2623c923cc9eeca4b9545b4363abaa9188a9e94e2b63b823419a2c',
    'homeSection':
        'd62af2714f2623c923cc9eeca4b9545b4363abaa9188a9e94e2b63b823419a2c',
    'getAlbum':
        'b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10',
    'queryArtistOverview':
        '446130b4a0aa6522a686aafccddb0ae849165b5e0436fd802f96e0243617b5d8',
    'queryWhatsNewFeed':
        '3b53dede3c6054e8b7c962dd280eb6761c5d1c82b06b039f4110d76a62b4966b',
  };

  SpotifyGqlService(this._authService);

  String? get _accessToken => _authService.credentials?.accessToken;

  /// Generate random user agent
  String _generateRandomUserAgent() {
    final random = Random();
    const osList = [
      'Windows NT 10.0; Win64; x64',
      'Macintosh; Intel Mac OS X 10_15_7',
      'X11; Linux x86_64',
      'Linux; Android 14',
      'iPhone; CPU iPhone OS 18_7 like Mac OS X',
    ];

    final baseChromeVersion = 140;
    final chromeVersions = List.generate(
        5, (i) => '${baseChromeVersion - i}.0.${random.nextInt(500)}.0');

    const webkit = '537.36';
    final selectedOs = osList[random.nextInt(osList.length)];
    final chromeVersion = chromeVersions[random.nextInt(chromeVersions.length)];
    final isMobile =
        selectedOs.contains('Android') || selectedOs.contains('iPhone');
    final mobileToken = isMobile ? ' Mobile' : '';

    return 'Mozilla/5.0 ($selectedOs) AppleWebKit/$webkit (KHTML, like Gecko) Chrome/$chromeVersion$mobileToken Safari/$webkit';
  }

  /// Make GraphQL request to Spotify Partner API
  Future<Map<String, dynamic>> _gqlRequest({
    required String operationName,
    required Map<String, dynamic> variables,
    bool isRetry = false,
  }) async {
    String? token = _accessToken;
    if (token == null || _authService.isExpired()) {
      token = await _authService.getValidAccessToken();
    }
    if (token == null) throw Exception('Not authenticated');

    // If using YouTube Music mock token, return empty valid structure instead of 401
    if (token == 'yt_mock_token') {
      print('⚠️ Bypassing Spotify GraphQL for YT Music session');
      return _getMockResponse(operationName);
    }

    final hash = _hashes[operationName];
    if (hash == null) throw Exception('Unknown operation: $operationName');

    final body = jsonEncode({
      'variables': variables,
      'operationName': operationName,
      'extensions': {
        'persistedQuery': {
          'version': 1,
          'sha256Hash': hash,
        },
      },
    });

    final response = await http.post(
      Uri.parse(_gqlEndpoint),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'User-Agent': _generateRandomUserAgent(),
      },
      body: body,
    ).timeout(const Duration(seconds: 12));

    if (response.statusCode == 401 && !isRetry) {
      developer.log('[SpotifyGql] Got 401, attempting token refresh...',
          name: 'SpotifyGqlService');
      await _authService.refresh();
      return _gqlRequest(
        operationName: operationName,
        variables: variables,
        isRetry: true,
      );
    }

    if (response.statusCode != 200) {
      developer.log(
          '[SpotifyGql] Error ${response.statusCode}: ${response.body}',
          name: 'SpotifyGqlService');
      throw Exception('GraphQL error ${response.statusCode}: ${response.body}');
    }

    final jsonResponse = jsonDecode(response.body);
    if (jsonResponse['errors'] != null) {
      developer.log(
          '[SpotifyGql] GraphQL Error ($operationName): ${jsonResponse['errors']}',
          name: 'SpotifyGqlService');
    } else {
      // developer.log('[SpotifyGql] Success ($operationName): ${response.body}', name: 'SpotifyGqlService');
    }

    return jsonResponse;
  }

  /// Generate mock responses for YT Music session
  Map<String, dynamic> _getMockResponse(String operationName) {
    switch (operationName) {
      case 'home':
        return {
          'data': {
            'home': {
              'sectionContainer': {
                'sections': {'items': []}
              }
            }
          }
        };
      case 'profileAttributes':
        return {
          'data': {
            'me': {
              'profile': {
                'name': 'YouTube Music User',
                'uri': 'spotify:user:ytmusic',
                'avatar': null,
              }
            }
          }
        };
      case 'fetchLibraryTracks':
        return {
          'data': {
            'me': {
              'library': {
                'tracks': {'items': [], 'totalCount': 0}
              }
            }
          }
        };
      case 'libraryV3':
        return {
          'data': {
            'me': {
              'libraryV3': {
                'items': [],
                'totalCount': 0,
                'pagingInfo': {'limit': 20, 'offset': 0}
              }
            }
          }
        };
      case 'fetchPlaylist':
      case 'getAlbum':
      case 'getTrack':
      case 'searchDesktop':
      case 'searchTracks':
      case 'searchAlbums':
      case 'searchArtists':
      case 'searchPlaylists':
      default:
        // Default empty structure for most list responses
        return {'data': {}};
    }
  }

  // ==================== CONVERTERS ====================

  /// Convert album items from GraphQL response
  List<Map<String, dynamic>> _convertAlbums(List items) {
    return items
        .where((item) {
          final contentTypeName = item['data']?['__typename'] ?? item['__typename'];
          return contentTypeName == 'Album';
        })
        .map((item) {
      final album = item['data'];
      final id = (album['uri'] as String).split(':').last;

      return {
        'id': id,
        'name': album['name'],
        'type': album['type']?.toString().toLowerCase(),
        'release_date': album['date']?['year']?.toString(),
        'release_date_precision': 'year',
        'images': album['coverArt']?['sources'] ?? [],
        'external_urls': {'spotify': 'https://open.spotify.com/album/$id'},
        'artists': (album['artists']?['items'] as List?)?.map((artist) {
              final artistId = (artist['uri'] as String).split(':').last;
              return {
                'id': artistId,
                'uri': artist['uri'],
                'name': artist['profile']['name'],
                'external_urls': {
                  'spotify': 'https://open.spotify.com/artist/$artistId'
                },
              };
            }).toList() ??
            [],
      };
    }).toList();
  }

  /// Convert artist items from GraphQL response
  List<Map<String, dynamic>> _convertArtists(List items) {
    return items
        .where((item) {
          final contentTypeName = item['data']?['__typename'] ?? item['__typename'];
          return contentTypeName == 'Artist';
        })
        .map((data) {
      final artist = data['data'];
      final id = (artist['uri'] as String).split(':').last;

      return {
        'id': id,
        'uri': artist['uri'],
        'name': artist['profile']['name'],
        'images': artist['visuals']?['avatarImage']?['sources'] ?? [],
        'external_urls': {'spotify': 'https://open.spotify.com/artist/$id'},
      };
    }).toList();
  }

  /// Convert playlist items from GraphQL response
  List<Map<String, dynamic>> _convertPlaylists(List items) {
    return items
        .where((item) {
          final contentTypeName = item['data']?['__typename'] ?? item['__typename'];
          return contentTypeName == 'Playlist';
        })
        .map((data) {
      final playlist = data['data'];
      final id = (playlist['uri'] as String).split(':').last;
      final owner = playlist['ownerV2']['data'];
      final ownerId = (owner['uri'] as String).split(':').last;

      return {
        'id': id,
        'uri': playlist['uri'],
        'name': playlist['name'],
        'description': playlist['description'],
        'images': (playlist['images']?['items'] as List?)
                ?.expand((image) => image['sources'] as List)
                .toList() ??
            [],
        'external_urls': {'spotify': 'https://open.spotify.com/playlist/$id'},
        'owner': {
          'id': ownerId,
          'uri': owner['uri'],
          'name': owner['username'],
          'display_name': owner['name'],
          'images': owner['avatar']?['sources'] ?? [],
          'external_urls': {
            'spotify': 'https://open.spotify.com/user/$ownerId'
          },
        },
      };
    }).toList();
  }

  /// Convert track items from GraphQL response
  List<Map<String, dynamic>> _convertTracks(List items) {
    return items
        .where((item) {
          final contentTypeName = item['item']?['data']?['__typename'] ?? item['item']?['__typename'];
          return contentTypeName == 'Track';
        })
        .map((track) {
      final item = track['item']['data'];
      final trackId = (item['uri'] as String).split(':').last;

      final trackArtists = (item['artists']?['items'] as List?)?.map((artist) {
            final artistId = (artist['uri'] as String).split(':').last;
            return {
              'id': artistId,
              'uri': artist['uri'],
              'name': artist['profile']['name'],
              'external_urls': {
                'spotify': 'https://open.spotify.com/artist/$artistId'
              },
            };
          }).toList() ??
          [];

      final albumId = (item['albumOfTrack']['uri'] as String).split(':').last;

      return {
        'id': trackId,
        'uri': item['uri'],
        'name': item['name'],
        'album': {
          'album_type': 'album',
          'id': albumId,
          'name': item['albumOfTrack']['name'],
          'images': item['albumOfTrack']['coverArt']?['sources'] ?? [],
          'external_urls': {
            'spotify': 'https://open.spotify.com/album/$albumId'
          },
          'href': 'https://api.spotify.com/v1/albums/$albumId',
          'artists': trackArtists.isNotEmpty ? [trackArtists.first] : [],
        },
        'artists': trackArtists,
        'duration_ms': item['duration']?['totalMilliseconds'],
        'external_urls': {'spotify': 'https://open.spotify.com/track/$trackId'},
      };
    }).toList();
  }

  // ==================== SEARCH METHODS ====================

  /// Search all types (tracks, albums, artists, playlists)
  Future<Map<String, dynamic>> searchAll(String query,
      {int offset = 0, int limit = 10, int topResults = 5}) async {
    final result = await _gqlRequest(
      operationName: 'searchDesktop',
      variables: {
        'searchTerm': query,
        'offset': offset,
        'limit': limit,
        'numberOfTopResults': topResults,
        'includeAudiobooks': false,
        'includeArtistHasConcertsField': false,
        'includePreReleases': false,
        'includeLocalConcertsField': false,
        'includeAuthors': false,
      },
    );

    final searchData = result['data']['searchV2'];

    return {
      'albums': _convertAlbums(searchData['albumsV2']['items'] ?? []),
      'artists': _convertArtists(searchData['artists']['items'] ?? []),
      'playlists': _convertPlaylists(searchData['playlists']['items'] ?? []),
      'tracks': _convertTracks(searchData['tracksV2']['items'] ?? []),
    };
  }

  /// Search tracks only
  Future<Map<String, dynamic>> searchTracks(String query,
      {int offset = 0, int limit = 20}) async {
    final result = await _gqlRequest(
      operationName: 'searchTracks',
      variables: {
        'searchTerm': query,
        'offset': offset,
        'limit': limit,
        'numberOfTopResults': 20,
        'includeAudiobooks': true,
        'includeAuthors': false,
        'includePreReleases': false,
      },
    );

    final searchData = result['data']['searchV2']['tracksV2'];
    final pagingInfo = searchData['pagingInfo'];

    return {
      'total': searchData['totalCount'],
      'limit': pagingInfo['limit'],
      'offset': pagingInfo['nextOffset'],
      'items': _convertTracks(searchData['items'] ?? []),
    };
  }

  /// Search albums only
  Future<Map<String, dynamic>> searchAlbums(String query,
      {int offset = 0, int limit = 20}) async {
    final result = await _gqlRequest(
      operationName: 'searchAlbums',
      variables: {
        'searchTerm': query,
        'offset': offset,
        'limit': limit,
        'numberOfTopResults': 20,
        'includeAudiobooks': false,
        'includeAuthors': false,
        'includePreReleases': false,
      },
    );

    final searchData = result['data']['searchV2']['albumsV2'];
    final pagingInfo = searchData['pagingInfo'];

    return {
      'total': searchData['totalCount'],
      'limit': pagingInfo['limit'],
      'offset': pagingInfo['nextOffset'],
      'items': _convertAlbums(searchData['items'] ?? []),
    };
  }

  /// Search artists only
  Future<Map<String, dynamic>> searchArtists(String query,
      {int offset = 0, int limit = 20}) async {
    final result = await _gqlRequest(
      operationName: 'searchArtists',
      variables: {
        'searchTerm': query,
        'offset': offset,
        'limit': limit,
        'numberOfTopResults': 20,
        'includeAudiobooks': true,
        'includeAuthors': false,
        'includePreReleases': false,
      },
    );

    final searchData = result['data']['searchV2']['artists'];
    final pagingInfo = searchData['pagingInfo'];

    return {
      'total': searchData['totalCount'],
      'limit': pagingInfo['limit'],
      'offset': pagingInfo['nextOffset'],
      'items': _convertArtists(searchData['items'] ?? []),
    };
  }

  /// Search playlists only
  Future<Map<String, dynamic>> searchPlaylists(String query,
      {int offset = 0, int limit = 20}) async {
    final result = await _gqlRequest(
      operationName: 'searchPlaylists',
      variables: {
        'searchTerm': query,
        'offset': offset,
        'limit': limit,
        'numberOfTopResults': 20,
        'includeAudiobooks': true,
        'includeAuthors': false,
        'includePreReleases': false,
      },
    );

    final searchData = result['data']['searchV2']['playlists'];
    final pagingInfo = searchData['pagingInfo'];

    return {
      'total': searchData['totalCount'],
      'limit': pagingInfo['limit'],
      'offset': pagingInfo['nextOffset'],
      'items': _convertPlaylists(searchData['items'] ?? []),
    };
  }

  // ==================== LIBRARY METHODS ====================

  /// Get user's saved tracks
  Future<Map<String, dynamic>> getSavedTracks(
      {int offset = 0, int limit = 20}) async {
    final result = await _gqlRequest(
      operationName: 'fetchLibraryTracks',
      variables: {
        'offset': offset,
        'limit': limit,
      },
    );

    final library = result['data']['me']['library'];
    final tracks = (library['tracks']['items'] as List).map((track) {
      final id = (track['track']['_uri'] as String).split(':').last;
      final item = track['track']['data'];

      final trackArtists = (item['artists']?['items'] as List?)?.map((artist) {
            final artistId = (artist['uri'] as String).split(':').last;
            return {
              'id': artistId,
              'uri': artist['uri'],
              'name': artist['profile']['name'],
              'external_urls': {
                'spotify': 'https://open.spotify.com/artist/$artistId'
              },
            };
          }).toList() ??
          [];

      final albumId = (item['albumOfTrack']['uri'] as String).split(':').last;

      return {
        'id': id,
        'uri': item['uri'],
        'name': item['name'],
        'album': {
          'album_type': 'album',
          'id': albumId,
          'name': item['albumOfTrack']['name'],
          'images': item['albumOfTrack']['coverArt']?['sources'] ?? [],
          'external_urls': {
            'spotify': 'https://open.spotify.com/album/$albumId'
          },
          'artists': trackArtists.isNotEmpty ? [trackArtists.first] : [],
        },
        'artists': trackArtists,
        'duration_ms': item['duration']?['totalMilliseconds'],
        'external_urls': {'spotify': 'https://open.spotify.com/track/$id'},
      };
    }).toList();

    return {
      'limit': limit,
      'offset': offset,
      'total': library['tracks']['totalCount'],
      'items': tracks,
    };
  }

  /// Get user's saved playlists
  Future<Map<String, dynamic>> getSavedPlaylists(
      {int offset = 0, int limit = 20}) async {
    final result = await _gqlRequest(
      operationName: 'libraryV3',
      variables: {
        'filters': ['Playlists'],
        'order': null,
        'textFilter': '',
        'features': [
          'LIKED_SONGS',
          'YOUR_EPISODES_V2',
          'PRERELEASES',
          'EVENTS'
        ],
        'limit': limit,
        'offset': offset,
        'flatten': false,
        'expandedFolders': [],
        'folderUri': null,
        'includeFoldersWhenFlattening': true,
      },
    );

    final playlistData = result['data']?['me']?['libraryV3'];
    if (playlistData == null) {
      return {
        'items': [],
        'total': 0,
        'limit': limit,
        'offset': offset,
      };
    }
    
    final pagingInfo = playlistData['pagingInfo'];

    final items = (playlistData['items'] as List? ?? [])
        .where((item) {
          final contentTypeName = item['item']?['data']?['__typename'] ?? item['item']?['__typename'];
          return contentTypeName == 'Playlist';
        })
        .map((item) {
      final id = ((item['item']?['_uri'] ?? item['item']?['uri']) as String?)?.split(':').last ?? '';
      final playlist = item['item']?['data'] ?? item['item'] ?? {};
      final ownerV2 = playlist['ownerV2']?['data'];

      return {
        'type': 'playlist',
        'id': id,
        'description': playlist['description'],
        'external_urls': {'spotify': 'https://open.spotify.com/playlist/$id'},
        'images': (playlist['images']?['items'] as List?)
                ?.map((i) => i['sources'])
                .expand((i) => i)
                .toList() ??
            [],
        'name': playlist['name'] ?? '',
        'owner': {
          'type': 'user',
          'external_urls': {
            'spotify': 'https://open.spotify.com/user/${ownerV2?["id"] ?? ""}'
          },
          'id': ownerV2?['id'] ?? '',
          'uri': ownerV2?['uri'] ?? '',
          'display_name': ownerV2?['name'] ?? '',
          'images': ownerV2?['avatar']?['sources'] ?? [],
        },
        'uri': item['item']?['_uri'] ?? item['item']?['uri'] ?? '',
      };
    }).toList();

    return {
      'limit': pagingInfo['limit'],
      'offset': pagingInfo['offset'],
      'total': playlistData['totalCount'],
      'items': items,
    };
  }

  /// Get playlist tracks (Fetches all tracks using pagination)
  Future<Map<String, dynamic>> getPlaylistTracks(String playlistId,
      {int offset = 0, int limit = 25}) async {
    
    final List<Map<String, dynamic>> allTracks = [];
    int currentOffset = offset;
    bool hasMore = true;
    
    String playlistName = '';
    List<Map<String, dynamic>> playlistImages = [];
    int totalCount = 0;

    while (hasMore) {
      final result = await _gqlRequest(
        operationName: 'fetchPlaylist',
        variables: {
          'uri': 'spotify:playlist:$playlistId',
          'offset': currentOffset,
          'limit': 100, // Fetch in large batches
          'enableWatchFeedEntrypoint': false,
        },
      );

      final playlist = result['data']['playlistV2'];
      
      if (currentOffset == offset) {
        playlistName = playlist['name'] ?? '';
        playlistImages = _extractImages(playlist['images']);
        totalCount = playlist['content']['totalCount'] ?? 0;
      }

      final contentItems = playlist['content']['items'] as List;
      
      final tracks = contentItems.map((track) {
        final item = track['itemV2']['data'];
        final trackId = (item['uri'] as String).split(':').last;

        final trackArtists = (item['artists']?['items'] as List?)?.map((artist) {
              final artistId = (artist['uri'] as String).split(':').last;
              return {
                'id': artistId,
                'uri': artist['uri'],
                'name': artist['profile']['name'],
                'external_urls': {
                  'spotify': 'https://open.spotify.com/artist/$artistId'
                },
              };
            }).toList() ??
            [];

        final albumId = (item['albumOfTrack']['uri'] as String).split(':').last;

        // Try multiple paths for duration
        int durationMs = 0;
        if (item['playTime']?['totalMilliseconds'] != null) {
          durationMs = (item['playTime']['totalMilliseconds'] as num).toInt();
        } else if (item['duration']?['totalMilliseconds'] != null) {
          durationMs = (item['duration']['totalMilliseconds'] as num).toInt();
        } else if (item['trackDuration']?['totalMilliseconds'] != null) {
          durationMs =
              (item['trackDuration']['totalMilliseconds'] as num).toInt();
        }

        return {
          'id': trackId,
          'uri': item['uri'],
          'name': item['name'],
          'album': {
            'album_type': 'album',
            'id': albumId,
            'name': item['albumOfTrack']['name'],
            'images': item['albumOfTrack']['coverArt']?['sources'] ?? [],
            'external_urls': {
              'spotify': 'https://open.spotify.com/album/$albumId'
            },
            'artists': trackArtists.isNotEmpty ? [trackArtists.first] : [],
          },
          'artists': trackArtists,
          'duration_ms': durationMs,
          'external_urls': {'spotify': 'https://open.spotify.com/track/$trackId'},
        };
      }).toList();
      
      allTracks.addAll(tracks);
      
      if (contentItems.length < 100) {
        hasMore = false;
      } else {
        currentOffset += 100;
      }
    }

    return {
      'limit': limit, // Keep original signature for compatibility
      'offset': offset,
      'total': totalCount,
      'items': allTracks,
      'name': playlistName,
      'images': playlistImages,
    };
  }

  /// Get album tracks
  Future<Map<String, dynamic>> getAlbumTracks(String albumId,
      {int offset = 0, int limit = 50}) async {
    final result = await _gqlRequest(
      operationName: 'getAlbum',
      variables: {
        'uri': 'spotify:album:$albumId',
        'locale': '',
        'offset': offset,
        'limit': limit,
      },
    );

    final album = result['data']?['albumUnion'];
    if (album == null) {
      print('⚠️ getAlbumTracks: albumUnion is null');
      return {
        'items': [],
        'total': 0,
        'offset': offset,
        'limit': limit,
      };
    }

    final tracksV2 = album['tracksV2']?['items'] as List? ?? [];

    // Build album info for track references
    final albumInfo = {
      'id': albumId,
      'name': album['name'] ?? '',
      'images': album['coverArt']?['sources'] ?? [],
      'external_urls': {'spotify': 'https://open.spotify.com/album/$albumId'},
    };

    final tracks = tracksV2
        .map((item) {
          final track = item['track'];
          if (track == null) return null;

          final trackId = (track['uri'] as String?)?.split(':').last ?? '';

          final trackArtists =
              (track['artists']?['items'] as List? ?? []).map((artist) {
            final artistId = (artist['uri'] as String?)?.split(':').last ?? '';
            return {
              'id': artistId,
              'uri': artist['uri'],
              'name': artist['profile']?['name'] ?? '',
              'external_urls': {
                'spotify': 'https://open.spotify.com/artist/$artistId'
              },
            };
          }).toList();

          return {
            'id': trackId,
            'uri': track['uri'],
            'name': track['name'] ?? '',
            'duration_ms':
                (track['duration']?['totalMilliseconds'] as num?)?.toInt() ?? 0,
            'explicit': track['contentRating']?['label'] == 'EXPLICIT',
            'artists': trackArtists,
            'album': albumInfo,
            'external_urls': {
              'spotify': 'https://open.spotify.com/track/$trackId'
            },
          };
        })
        .where((t) => t != null)
        .toList();

    return {
      'items': tracks,
      'total': album['tracksV2']?['totalCount'] ?? tracks.length,
      'offset': offset,
      'limit': limit,
    };
  }

  /// Get track by ID
  Future<Map<String, dynamic>> getTrack(String trackId) async {
    final result = await _gqlRequest(
      operationName: 'getTrack',
      variables: {'uri': 'spotify:track:$trackId'},
    );

    final track = result['data']['trackUnion'];

    final firstArtists = track['firstArtist']?['items'] as List? ?? [];
    final otherArtists = track['otherArtists']?['items'] as List? ?? [];
    final trackArtists = [...firstArtists, ...otherArtists].map((artist) {
      final id = (artist['uri'] as String).split(':').last;
      return {
        'id': id,
        'uri': artist['uri'],
        'name': artist['profile']['name'],
        'external_urls': {'spotify': 'https://open.spotify.com/artist/$id'},
        'images': artist['visuals']?['avatarImage']?['sources'] ?? [],
      };
    }).toList();

    return {
      'id': track['id'],
      'name': track['name'],
      'duration_ms': track['duration']['totalMilliseconds'],
      'album': {
        'id': track['albumOfTrack']['id'],
        'name': track['albumOfTrack']['name'],
        'images': track['albumOfTrack']['coverArt']['sources'],
        'album_type': track['albumOfTrack']['type']?.toString().toLowerCase(),
        'uri': track['albumOfTrack']['uri'],
        'artists': trackArtists.isNotEmpty ? [trackArtists.first] : [],
        'release_date': track['albumOfTrack']['date']?['isoString'] ?? '',
        'external_urls': {
          'spotify':
              'https://open.spotify.com/album/${track["albumOfTrack"]["id"]}'
        },
      },
      'artists': trackArtists,
      'uri': track['uri'],
      'external_urls': {
        'spotify': 'https://open.spotify.com/track/${track["id"]}'
      },
    };
  }

  /// Get current user profile
  Future<Map<String, dynamic>> me() async {
    final result = await _gqlRequest(
      operationName: 'profileAttributes',
      variables: {},
    );

    final user = result['data']['me']['profile'];
    final userId = (user['uri'] as String).split(':').last;

    return {
      'display_name': user['name'],
      'email': 'unknown',
      'explicit_content': {'filter_enabled': false, 'filter_locked': false},
      'external_urls': {'spotify': 'https://open.spotify.com/user/$userId'},
      'followers': {
        'href': 'https://api.spotify.com/v1/users/$userId/followers',
        'total': 0
      },
      'href': 'https://api.spotify.com/v1/users/$userId',
      'id': userId,
      'images': user['avatar']?['sources'] ?? [],
      'type': 'user',
      'uri': user['uri'],
    };
  }

  // ==================== BROWSE/HOME ====================

  /// Get home sections (playlists, albums, artists)
  Future<List<Map<String, dynamic>>> getHome({
    String? timeZone,
    int limit = 20,
  }) async {
    final spT = _authService.credentials?.spTCookie ?? '';

    final result = await _gqlRequest(
      operationName: 'home',
      variables: {
        'timeZone': timeZone ?? 'Asia/Kolkata',
        'sp_t': spT,
        'facet': '',
        'sectionItemsLimit': limit,
      },
    );

    final homeData = result['data']?['home'];
    if (homeData == null) {
      developer.log('[SpotifyGql] Error: result.data.home is null. Result keys: ${result.keys}, Data keys: ${result['data']?.keys}');
      return [];
    }
    if (homeData['sectionContainer'] == null) {
      developer.log('[SpotifyGql] Error: homeData.sectionContainer is null. HomeData keys: ${homeData.keys}');
      return [];
    }
    
    final homeSections = homeData['sectionContainer']['sections']?['items'] as List? ?? [];
    if (homeSections.isEmpty) {
      developer.log('[SpotifyGql] Error: homeSections is empty');
    } else {
      developer.log('[SpotifyGql] Success: Found ${homeSections.length} sections');
    }

    final parsedSections = homeSections
        .where((section) =>
            section['sectionItems'] != null &&
            (section['sectionItems']['items'] as List?)?.isNotEmpty == true)
        .map<Map<String, dynamic>>((section) => _parseSectionItems(section))
        .where((section) => (section['items'] as List?)?.isNotEmpty == true)
        .toList();
        
    if (parsedSections.isEmpty && homeSections.isNotEmpty) {
      developer.log('[SpotifyGql] Error: parsedSections is empty despite having ${homeSections.length} raw sections. Check _parseSectionItems!');
    }
    
    return parsedSections;
  }

  /// Parse section items from home response
  Map<String, dynamic> _parseSectionItems(Map<String, dynamic> section) {
    final id = (section['uri'] as String).split(':').last;

    return {
      'id': id,
      'uri': section['uri'],
      'title': section['data']?['title']?['transformedLabel'] ?? section['data']?['title']?['text'] ?? 'Section',
      'external_urls': {'spotify': 'https://open.spotify.com/section/$id'},
      'items': (section['sectionItems']['items'] as List)
          .map<Map<String, dynamic>?>((item) {
            final contentTypeName = item['content']?['data']?['__typename'] ?? item['content']?['__typename'];

            if (contentTypeName == 'Playlist') {
              return _parsePlaylistItem(item);
            } else if (contentTypeName == 'Album') {
              return _parseAlbumItem(item);
            } else if (contentTypeName == 'Artist') {
              return _parseArtistItem(item);
            }
            return null;
          })
          .where((item) => item != null)
          .toList(),
    };
  }

  Map<String, dynamic> _parsePlaylistItem(Map<String, dynamic> item) {
    final id = (item['uri'] as String).split(':').last;
    final playlist = item['content']?['data'] ?? item['content'] ?? {};
    final ownerV2 = playlist['ownerV2']?['data'];
    final ownerId =
        ownerV2 != null ? (ownerV2['uri'] as String).split(':').last : '';

    return {
      'objectType': 'Playlist',
      'id': id,
      'description': playlist['description'] ?? '',
      'external_urls': {'spotify': 'https://open.spotify.com/playlist/$id'},
      'images': _extractImages(playlist['images']),
      'name': playlist['name'] ?? '',
      'owner': {
        'type': 'user',
        'external_urls': {'spotify': 'https://open.spotify.com/user/$ownerId'},
        'id': ownerId,
        'uri': ownerV2?['uri'] ?? '',
        'display_name': ownerV2?['name'] ?? '',
        'images': ownerV2?['avatar']?['sources'] ?? [],
      },
      'uri': item['uri'],
    };
  }

  Map<String, dynamic> _parseAlbumItem(Map<String, dynamic> item) {
    final id = (item['uri'] as String).split(':').last;
    final album = item['content']?['data'] ?? item['content'] ?? {};

    return {
      'objectType': 'Album',
      'id': id,
      'name': album['name'] ?? '',
      'album_type': (album['albumType'] ?? 'album').toString().toLowerCase(),
      'external_urls': {'spotify': 'https://open.spotify.com/album/$id'},
      'uri': item['uri'],
      'images': album['coverArt']?['sources'] ?? [],
      'artists': _extractArtists(album['artists']?['items']),
    };
  }

  Map<String, dynamic> _parseArtistItem(Map<String, dynamic> item) {
    final id = (item['uri'] as String).split(':').last;
    final artist = item['content']?['data'] ?? item['content'] ?? {};

    return {
      'objectType': 'Artist',
      'id': id,
      'name': artist['profile']?['name'] ?? '',
      'uri': item['uri'],
      'external_urls': {'spotify': 'https://open.spotify.com/artist/$id'},
      'images': artist['visuals']?['avatarImage']?['sources'] ?? [],
    };
  }

  List<Map<String, dynamic>> _extractImages(dynamic images) {
    if (images == null) return [];
    final items = images['items'] as List?;
    if (items == null) return [];
    return items
        .expand<Map<String, dynamic>>((img) =>
            ((img['sources'] ?? []) as List).cast<Map<String, dynamic>>())
        .toList();
  }

  List<Map<String, dynamic>> _extractArtists(List? artists) {
    if (artists == null) return [];
    return artists.map<Map<String, dynamic>>((artist) {
      final id = (artist['uri'] as String).split(':').last;
      return {
        'id': id,
        'uri': artist['uri'],
        'name': artist['profile']?['name'] ?? '',
        'external_urls': {'spotify': 'https://open.spotify.com/artist/$id'},
      };
    }).toList();
  }

  // ==================== ALBUM ====================

  /// Get album details
  Future<Map<String, dynamic>> getAlbum(String albumId) async {
    final result = await _gqlRequest(
      operationName: 'getAlbum',
      variables: {
        'uri': 'spotify:album:$albumId',
        'locale': '',
        'offset': 0,
        'limit': 50,
      },
    );

    final album = result['data']['albumUnion'];

    return {
      'id': albumId,
      'name': album['name'] ?? '',
      'album_type': (album['type'] ?? 'album').toString().toLowerCase(),
      'label': album['label'] ?? '',
      'release_date': album['date']?['isoString'] ?? '',
      'release_date_precision': album['date']?['precision'] ?? 'day',
      'images': album['coverArt']?['sources'] ?? [],
      'external_urls': {'spotify': 'https://open.spotify.com/album/$albumId'},
      'copyrights': album['copyrights']?['copyright'] ?? [],
      'artists': _extractArtistsWithImages(album['artists']?['items']),
    };
  }

  List<Map<String, dynamic>> _extractArtistsWithImages(List? artists) {
    if (artists == null) return [];
    return artists.map<Map<String, dynamic>>((artist) {
      final id = (artist['uri'] as String).split(':').last;
      return {
        'id': id,
        'uri': artist['uri'],
        'name': artist['profile']?['name'] ?? '',
        'external_urls': {'spotify': 'https://open.spotify.com/artist/$id'},
        'images': artist['visuals']?['avatarImage']?['sources'] ?? [],
      };
    }).toList();
  }

  // ==================== ARTIST ====================

  /// Get artist details
  Future<Map<String, dynamic>> getArtist(String artistId) async {
    final result = await _gqlRequest(
      operationName: 'queryArtistOverview',
      variables: {
        'uri': 'spotify:artist:$artistId',
        'locale': '',
      },
    );

    final artist = result['data']['artistUnion'];

    return {
      'external_urls': {'spotify': 'https://open.spotify.com/artist/$artistId'},
      'followers': {
        'href': 'https://open.spotify.com/artist/$artistId/followers',
        'total': artist['stats']?['followers'] ?? 0,
      },
      'genres': [],
      'href': 'https://api.spotify.com/v1/artists/$artistId',
      'id': artistId,
      'images': artist['visuals']?['avatarImage']?['sources'] ?? [],
      'name': artist['profile']?['name'] ?? '',
      'popularity': 1,
      'type': 'artist',
      'uri': 'spotify:artist:$artistId',
    };
  }

  /// Get artist top tracks
  Future<List<Map<String, dynamic>>> getArtistTopTracks(String artistId) async {
    final result = await _gqlRequest(
      operationName: 'queryArtistOverview',
      variables: {
        'uri': 'spotify:artist:$artistId',
        'locale': '',
      },
    );

    final artist = result['data']['artistUnion'];
    final topTracks =
        artist['discography']?['topTracks']?['items'] as List? ?? [];

    return topTracks.map<Map<String, dynamic>>((track) {
      final item = track['track'];
      final trackId = (item['uri'] as String).split(':').last;
      final albumId = (item['albumOfTrack']['uri'] as String).split(':').last;

      return {
        'id': trackId,
        'uri': item['uri'],
        'name': item['name'] ?? '',
        'album': {
          'album_type': 'album',
          'id': albumId,
          'name': item['albumOfTrack']?['name'] ?? 'unknown',
          'images': item['albumOfTrack']?['coverArt']?['sources'] ?? [],
          'external_urls': {
            'spotify': 'https://open.spotify.com/album/$albumId'
          },
          'href': 'https://api.spotify.com/v1/albums/$albumId',
        },
        'artists': _extractArtists(item['artists']?['items']),
        'duration_ms': item['duration']?['totalMilliseconds'] ?? 0,
        'external_urls': {'spotify': 'https://open.spotify.com/track/$trackId'},
      };
    }).toList();
  }
}
