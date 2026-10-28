import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'lib/services/spotify_auth_service.dart';
import 'lib/services/spotify_gql_service.dart';

void main() async {
  SharedPreferences.setMockInitialValues({
    'spotify_access_token': 'test_token',
    'spotify_sp_dc': 'test_sp_dc',
  });
  
  final auth = SpotifyAuthService();
  await auth.initializeFromStorage();
  final gql = SpotifyGqlService(auth);
  try {
    final home = await gql.getHome();
    print('Home sections: \${home.length}');
  } catch (e, stack) {
    print('Error: \$e');
    print(stack);
  }
}
