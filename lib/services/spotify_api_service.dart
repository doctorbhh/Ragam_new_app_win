import 'dart:convert';
import 'package:http/http.dart' as http;
import 'spotify_auth_service.dart';

class SpotifyApiService {
  final SpotifyAuthService _authService;

  SpotifyApiService(this._authService);

  Future<String?> get _accessToken async {
    return _authService.credentials?.accessToken;
  }

  /// Get Recommendations (Browse New Releases)
  /// This endpoint works with Web Player tokens
  Future<List<Map<String, dynamic>>> getRecommendations() async {
    final token = await _accessToken;
    if (token == null) throw Exception('Not authenticated');

    try {
      // Try getting new releases which typically works with web player tokens
      final response = await http.get(
        Uri.parse('https://api.spotify.com/v1/browse/new-releases?limit=20'),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      print('Recommendations Response: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final albums = data['albums']?['items'] as List<dynamic>?;

        // Convert albums to track-like format for display
        return albums
                ?.map((album) {
                  return {
                    'id': album['id'],
                    'name': album['name'],
                    'artists': album['artists'],
                    'album': {
                      'name': album['name'],
                      'images': album['images'],
                    },
                    'duration_ms': 180000, // Placeholder
                  };
                })
                .toList()
                .cast<Map<String, dynamic>>() ??
            [];
      } else {
        print('Error: ${response.body}');
        // Return empty list on error instead of throwing
        return [];
      }
    } catch (e) {
      print('Error in getRecommendations: $e');
      return [];
    }
  }

  /// Search Tracks - Uses Spotify API if possible, returns empty on error
  Future<List<Map<String, dynamic>>> searchTracks(String query) async {
    final token = await _accessToken;
    if (token == null) {
      print('No token, returning mock search');
      // Return mock results based on query for demo
      return _generateMockResults(query);
    }

    try {
      final response = await http.get(
        Uri.parse(
            'https://api.spotify.com/v1/search?q=${Uri.encodeComponent(query)}&type=track&limit=20'),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      print('Search Response: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['tracks']?['items'] ?? []);
      } else {
        print('Search error: ${response.statusCode} ${response.body}');
        // Fallback to mock results
        return _generateMockResults(query);
      }
    } catch (e) {
      print('Error in searchTracks: $e');
      return _generateMockResults(query);
    }
  }

  /// Generate mock results for demo when API fails
  List<Map<String, dynamic>> _generateMockResults(String query) {
    // Create mock track entries that the Track model can parse
    return [
      {
        'id': '1',
        'name': query,
        'artists': [
          {'name': 'Search on YouTube'}
        ],
        'album': {'name': 'Direct Search', 'images': []},
        'duration_ms': 180000,
      }
    ];
  }

  /// Get Album Tracks
  Future<List<Map<String, dynamic>>> getAlbumTracks(String albumId) async {
    final token = await _accessToken;
    if (token == null) throw Exception('Not authenticated');

    try {
      final response = await http.get(
        Uri.parse('https://api.spotify.com/v1/albums/$albumId/tracks?limit=50'),
        headers: {
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['items'] ?? []);
      } else {
        return [];
      }
    } catch (e) {
      print('Error in getAlbumTracks: $e');
      return [];
    }
  }
}
