import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'lib/services/spotify_auth_service.dart';
import 'lib/services/spotify_gql_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final spotifyAuth = SpotifyAuthService();
  await spotifyAuth.initializeFromStorage();
  
  if (spotifyAuth.isAuthenticated) {
    print("Authenticated!");
    final spotify = SpotifyGqlService(spotifyAuth);
    try {
      final spT = spotifyAuth.credentials?.spTCookie ?? '';
      
      final result = await spotify.getHomeRaw();
      final homeData = result['data']['home'];
      final homeSections = homeData['sectionContainer']['sections']['items'] as List;
      for (var section in homeSections) {
        print("Typename: ${section['data']?['__typename']}");
      }
    } catch (e) {
      print("Error: $e");
    }
  } else {
    print("Not authenticated");
  }
}

extension SpotifyTest on SpotifyGqlService {
  Future<Map<String, dynamic>> getHomeRaw() async {
    final auth = this as dynamic;
    final spT = auth._authService.credentials?.spTCookie ?? '';
    return await auth._gqlRequest(
      operationName: 'home',
      variables: {
        'timeZone': 'Asia/Kolkata',
        'sp_t': spT,
        'facet': '',
        'sectionItemsLimit': 5,
      },
    );
  }
}
