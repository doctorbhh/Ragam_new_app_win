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
      final homeSections = await spotify.getHome(limit: 5);
      print("Home sections length: ${homeSections.length}");
      for (var section in homeSections) {
        print("Section: ${section['title']}");
        print("Items: ${(section['items'] as List).length}");
      }
    } catch (e) {
      print("Error: $e");
    }
  } else {
    print("Not authenticated");
  }
}
