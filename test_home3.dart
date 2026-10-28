import 'dart:convert';
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
      final auth = spotify as dynamic;
      final spT = auth._authService.credentials?.spTCookie ?? '';
      final result = await auth._gqlRequest(
        operationName: 'home',
        variables: {
          'timeZone': 'Asia/Kolkata',
          'sp_t': spT,
          'facet': '',
          'sectionItemsLimit': 2,
        },
      );
      final homeData = result['data']['home'];
      final homeSections = homeData['sectionContainer']['sections']['items'] as List;
      for (var section in homeSections) {
        if (section['sectionItems'] != null && (section['sectionItems']['items'] as List).isNotEmpty) {
          print("Section Title data: ${section['data']?['title']}");
          final firstItem = section['sectionItems']['items'][0];
          print("First item wrapper: ${firstItem['content']?['__typename']}");
          print("First item content: ${firstItem['content']?['data']?['__typename']}");
        }
      }
    } catch (e) {
      print("Error: $e");
    }
  } else {
    print("Not authenticated");
  }
}
