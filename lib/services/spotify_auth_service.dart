import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:otp/otp.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/spotify_credentials.dart';

/// Spotify Authentication Service
/// Uses TOTP-based authentication with sp_dc cookie
class SpotifyAuthService {
  static final SpotifyAuthService _instance = SpotifyAuthService._internal();
  factory SpotifyAuthService() => _instance;
  SpotifyAuthService._internal();

  static const String _nuanceUrl =
      'https://gist.githubusercontent.com/saraansx/a622d4c1a12c36afdcf701201e9482a3/raw/9afe2c9c7d1a5eb3f7a05d0002a94f45b73682d0/nuance.json';

  static const String _serverTimeUrl =
      'https://open.spotify.com/api/server-time';

  static const String _tokenEndpoint = 'https://open.spotify.com/api/token';

  static const Map<String, dynamic> _fallbackNuance = {
    's':
        'GM3TMMJTGYZTQNZVGM4DINJZHA4TGOBYGMZTCMRTGEYDSMJRHE4TEOBUG4YTCMRUGQ4DQOJUGQYTAMRRGA2TCMJSHE3TCMBY',
    'v': 61,
  };

  SpotifyCredentials? _credentials;
  SpotifyCredentials? get credentials => _credentials;

  Timer? _refreshTimer;
  Future<void>? _initFuture;
  Future<void>? _refreshFuture;

  final StreamController<String> _authStateController =
      StreamController<String>.broadcast();

  /// Stream of auth state changes: 'login', 'logout', 'recovered', 'refreshed'
  Stream<String> get authStateStream => _authStateController.stream;

  /// Check if user has stored session cookies
  bool get hasStoredSession =>
      _credentials != null &&
      ((_credentials!.sapisid != null && _credentials!.sapisid!.isNotEmpty) ||
          (_credentials!.spDcCookie.isNotEmpty &&
              _credentials!.spDcCookie != 'yt_mock_sp_dc'));

  /// Check if user is authenticated with a non-expired token
  bool get isAuthenticated =>
      _credentials != null &&
      (_credentials?.sapisid != null ||
          (!isExpired() && _credentials!.accessToken.isNotEmpty));

  /// Ensure initialization from storage has completed
  Future<void> ensureInitialized() async {
    if (_credentials != null && !isExpired()) return;
    if (_initFuture != null) {
      await _initFuture;
      return;
    }
    await initializeFromStorage();
  }

  /// Get a valid, non-expired access token. If expired or missing, attempts refresh.
  Future<String?> getValidAccessToken() async {
    await ensureInitialized();
    if (_credentials == null) return null;

    if (!isExpired() && _credentials!.accessToken.isNotEmpty) {
      return _credentials!.accessToken;
    }

    if (hasStoredSession) {
      await refresh();
      if (!isExpired() && _credentials != null && _credentials!.accessToken.isNotEmpty) {
        return _credentials!.accessToken;
      }
    }
    return null;
  }

  /// Dispose resources
  void dispose() {
    _refreshTimer?.cancel();
    _authStateController.close();
  }

  // ==================== EXPIRATION ====================

  /// Check if credentials are expired
  bool isExpired() {
    if (_credentials == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    return now >= _credentials!.expirationTimestamp;
  }

  /// Get duration until expiration
  Duration getExpirationDuration() {
    if (_credentials == null) return Duration.zero;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = _credentials!.expirationTimestamp - now;
    return Duration(milliseconds: diff > 0 ? diff : 0);
  }

  /// Setup auto-refresh timer
  void _setupRefreshTimer() {
    _refreshTimer?.cancel();
    final duration = getExpirationDuration();
    if (duration.inSeconds > 60) {
      // Refresh 1 minute before expiration
      final refreshIn = duration - const Duration(minutes: 1);
      _refreshTimer = Timer(refreshIn, () => refresh());
    }
  }

  // ==================== NUANCE & TOTP ====================

  Future<Map<String, dynamic>> _getLatestNuance() async {
    try {
      final res = await http
          .get(Uri.parse(_nuanceUrl))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body);
        data.sort((a, b) => b['v'].compareTo(a['v']));
        return data.first;
      }
    } catch (e) {
      print('[SpotifyAuth] Nuance fetch error: $e, using fallback.');
    }
    return _fallbackNuance;
  }

  Future<int> _getSpotifyServerTime() async {
    try {
      final res = await http
          .get(Uri.parse(_serverTimeUrl))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['serverTime'] != null) {
          return data['serverTime'] as int;
        }
      }
    } catch (e) {
      print('[SpotifyAuth] Server time error: $e, using local system time.');
    }
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  Future<String> _generateTOTP(String secret) async {
    final serverTime = await _getSpotifyServerTime();

    return OTP.generateTOTPCodeString(
      secret,
      serverTime * 1000,
      length: 6,
      interval: 30,
      algorithm: Algorithm.SHA1,
      isGoogle: true,
    );
  }

  // ==================== USER AGENT ====================

  String _randomBytesFromMath(int length) {
    final r = Random();
    return List.generate(length, (_) => r.nextInt(256).toString()).join();
  }

  String generateRandomUserAgent() {
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

  // ==================== TOKEN ====================

  Future<Map<String, dynamic>> _getToken({
    required String spDc,
    required String totp,
    required int totpVer,
  }) async {
    final uri = Uri.parse(_tokenEndpoint).replace(
      queryParameters: {
        'reason': 'transport',
        'productType': 'web-player',
        'totp': totp,
        'totpServer': totp,
        'totpVer': totpVer.toString(),
      },
    );

    final ua = '${DateTime.now().millisecondsSinceEpoch}'
        '${Random().nextInt(100) * 1000}'
        '${_randomBytesFromMath(16)}';

    final res = await http.get(
      uri,
      headers: {
        'Cookie': 'sp_dc=$spDc;',
        'User-Agent': ua,
        'Referer': 'https://open.spotify.com/',
        'Origin': 'https://open.spotify.com',
      },
    ).timeout(const Duration(seconds: 10));

    print('[SpotifyAuth] Token response: ${res.statusCode}');

    if (res.statusCode != 200) {
      throw Exception('Token error ${res.statusCode}: ${res.body}');
    }

    return jsonDecode(res.body);
  }

  // ==================== AUTHENTICATION ====================

  /// Authenticate with cookies from webview
  Future<void> authenticateWithCookies(Map<String, String?> cookies) async {
    final spDc = cookies['sp_dc'];
    final spT = cookies['sp_t'];
    final sapisid = cookies['sapisid'];
    final cookieString = cookies['cookie_string'];

    if (sapisid != null) {
      print(
          "[SpotifyAuth] Authenticating with YouTube Music SAPISID: ${sapisid.substring(0, min(10, sapisid.length))}...");

      _credentials = SpotifyCredentials(
        accessToken: 'yt_mock_token',
        expirationTimestamp:
            DateTime.now().millisecondsSinceEpoch + 31536000000, // 1 year
        spDcCookie: 'yt_mock_sp_dc',
        sapisid: sapisid,
        cookieString: cookieString,
      );

      await _saveCredentials();
      _authStateController.add('login');
      print('[SpotifyAuth] ✅ Login Successful (YouTube Music)');
      return;
    }

    if (spDc == null) {
      throw Exception('sp_dc or sapisid cookie is required');
    }

    print(
        "[SpotifyAuth] Authenticating with sp_dc: ${spDc.substring(0, 10)}...");

    final nuance = await _getLatestNuance();
    print("[SpotifyAuth] Got nuance v: ${nuance['v']}");

    final totp = await _generateTOTP(nuance['s']);
    print("[SpotifyAuth] Generated TOTP");

    final token = await _getToken(spDc: spDc, totp: totp, totpVer: nuance['v']);

    if (token['accessToken'] == null) {
      throw Exception('Authentication failed: No access token');
    }

    _credentials = SpotifyCredentials(
      accessToken: token['accessToken'],
      expirationTimestamp: token['accessTokenExpirationTimestampMs'],
      spDcCookie: spDc,
      spTCookie: spT,
    );

    await _saveCredentials();
    _setupRefreshTimer();
    _authStateController.add('login');
    print('[SpotifyAuth] ✅ Login Successful');
  }

  /// Initialize from stored credentials
  Future<void> initializeFromStorage() async {
    if (_initFuture != null) {
      return _initFuture;
    }
    final completer = Completer<void>();
    _initFuture = completer.future;

    try {
      if (_credentials == null) {
        await loadCredentials();
      }
      if (_credentials != null) {
        if (isExpired()) {
          print('[SpotifyAuth] Stored credentials expired, refreshing...');
          await refresh();
        } else {
          _setupRefreshTimer();
          _authStateController.add('recovered');
          print('[SpotifyAuth] ✅ Credentials recovered');
        }
      }
      completer.complete();
    } catch (e) {
      print('[SpotifyAuth] Initialization error: $e');
      completer.complete();
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _saveCredentials() async {
    if (_credentials == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('spotify_creds', jsonEncode(_credentials!.toJson()));
  }

  Future<void> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final credsStr = prefs.getString('spotify_creds');
    if (credsStr != null) {
      _credentials = SpotifyCredentials.fromJson(jsonDecode(credsStr));
    }
  }

  /// Refresh credentials using stored sp_dc cookie
  Future<void> refresh() async {
    if (_refreshFuture != null) {
      return _refreshFuture;
    }
    final completer = Completer<void>();
    _refreshFuture = completer.future;

    try {
      if (_credentials?.sapisid != null) {
        print('[SpotifyAuth] YouTube Music session is valid (mock refresh).');
        _authStateController.add('refreshed');
        completer.complete();
        return;
      }

      if (_credentials?.spDcCookie == null ||
          _credentials?.spDcCookie == 'yt_mock_sp_dc') {
        print('[SpotifyAuth] No cookie found. Cannot refresh.');
        completer.complete();
        return;
      }

      await authenticateWithCookies({
        'sp_dc': _credentials!.spDcCookie,
        'sp_t': _credentials!.spTCookie,
      });
      _authStateController.add('refreshed');
      completer.complete();
    } catch (e) {
      print('[SpotifyAuth] Refresh failed: $e');
      completer.complete();
      // Don't logout on refresh failure - let user retry
    } finally {
      _refreshFuture = null;
    }
  }

  /// Logout and clear credentials
  Future<void> logout() async {
    _refreshTimer?.cancel();
    _credentials = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('spotify_creds');
    _authStateController.add('logout');
    print('[SpotifyAuth] Logged out');
  }
}
