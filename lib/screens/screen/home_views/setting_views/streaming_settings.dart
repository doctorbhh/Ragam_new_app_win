import 'package:flutter/material.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/services/spotify_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:Bloomee/blocs/explore/cubit/home_addons_cubit.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/core/events/global_event_bus.dart';
import 'webview_login_screen.dart';
class StreamingSettings extends StatefulWidget {
  const StreamingSettings({super.key});

  @override
  State<StreamingSettings> createState() => _StreamingSettingsState();
}

class _StreamingSettingsState extends State<StreamingSettings> {
  final SpotifyAuthService _spotifyAuth = SpotifyAuthService();

  final TextEditingController _spDcController = TextEditingController();
  final TextEditingController _ytmSapisidController = TextEditingController();
  final TextEditingController _ytmCookieController = TextEditingController();

  bool _isSpotifyLoading = false;
  bool _isSpotifyLoggedIn = false;

  bool _isYtmLoading = false;
  bool _isYtmLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    await _spotifyAuth.initializeFromStorage();
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _isSpotifyLoggedIn = _spotifyAuth.isAuthenticated &&
          _spotifyAuth.credentials?.sapisid == null;

      _isYtmLoggedIn = prefs.getString('ytm_cookie') != null &&
          prefs.getString('ytm_sapisid') != null;

      if (_isYtmLoggedIn) {
        _ytmCookieController.text = prefs.getString('ytm_cookie') ?? '';
        _ytmSapisidController.text = prefs.getString('ytm_sapisid') ?? '';
      }
    });
  }

  Future<void> _loginSpotify() async {
    final spDc = _spDcController.text.trim();
    if (spDc.isEmpty) {
      SnackbarService.showMessage('sp_dc cookie is required');
      return;
    }

    setState(() => _isSpotifyLoading = true);

    try {
      await _spotifyAuth.authenticateWithCookies({'sp_dc': spDc});
      SnackbarService.showMessage('Spotify Login Successful');
      await _checkStatus();
      if (mounted) context.read<HomeAddonsCubit>().loadHomeData();
    } catch (e) {
      SnackbarService.showMessage('Spotify Login Failed: $e');
    } finally {
      setState(() => _isSpotifyLoading = false);
    }
  }

  Future<void> _logoutSpotify() async {
    await _spotifyAuth.logout();
    _spDcController.clear();
    SnackbarService.showMessage('Logged out from Spotify');
    await _checkStatus();
    if (mounted) context.read<HomeAddonsCubit>().loadHomeData();
    GlobalEventBus.instance.emitRefresh();
  }

  Future<void> _loginYtm() async {
    final sapisid = _ytmSapisidController.text.trim();
    final cookie = _ytmCookieController.text.trim();

    if (sapisid.isEmpty || cookie.isEmpty) {
      SnackbarService.showMessage('SAPISID and Cookie string are required');
      return;
    }

    setState(() => _isYtmLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ytm_sapisid', sapisid);
      await prefs.setString('ytm_cookie', cookie);

      SnackbarService.showMessage('YouTube Music configuration saved');
      await _checkStatus();
      if (mounted) context.read<HomeAddonsCubit>().loadHomeData();
    } catch (e) {
      SnackbarService.showMessage('Failed to save YTM config: $e');
    } finally {
      setState(() => _isYtmLoading = false);
    }
  }

  Future<void> _logoutYtm() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ytm_sapisid');
    await prefs.remove('ytm_cookie');
    _ytmSapisidController.clear();
    _ytmCookieController.clear();
    SnackbarService.showMessage('YouTube Music config removed');
    await _checkStatus();
    if (mounted) context.read<HomeAddonsCubit>().loadHomeData();
    GlobalEventBus.instance.emitRefresh();
  }

  @override
  void dispose() {
    _spDcController.dispose();
    _ytmSapisidController.dispose();
    _ytmCookieController.dispose();
    _spotifyAuth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Default_Theme.primaryColor1),
        title: const Text(
          'Streaming Services',
          style: TextStyle(
            color: Default_Theme.primaryColor1,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSpotifyCard(),
          const SizedBox(height: 24),
          _buildYtmCard(),
        ],
      ),
    );
  }

  Widget _buildSpotifyCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.library_music, color: Color(0xFF1DB954)),
              const SizedBox(width: 8),
              const Text(
                'Spotify Integration',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Login using your Spotify account to fetch metadata, playlists, and recommendations.',
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(height: 16),
          if (_isSpotifyLoggedIn) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1DB954).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF1DB954)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Logged In to Spotify',
                        style: TextStyle(color: Color(0xFF1DB954))),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _logoutSpotify,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withOpacity(0.8),
                foregroundColor: Colors.white,
              ),
              child: const Text('Logout'),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSpotifyLoading
                    ? null
                    : () {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (context) => WebviewLoginScreen(
                            title: 'Spotify Login',
                            initialUrl: 'https://accounts.spotify.com/en/login',
                            targetCookies: const ['sp_dc', 'sp_t'],
                            onLoginComplete: (cookies) async {
                              final homeAddonsCubit = context.read<HomeAddonsCubit>();
                              setState(() => _isSpotifyLoading = true);
                              try {
                                await _spotifyAuth.authenticateWithCookies({
                                  'sp_dc': cookies['sp_dc']!,
                                  'sp_t': cookies['sp_t'],
                                });
                                SnackbarService.showMessage('Spotify Login Successful');
                                await _checkStatus();
                                homeAddonsCubit.loadHomeData();
                                GlobalEventBus.instance.emitRefresh();
                              } catch (e) {
                                SnackbarService.showMessage('Spotify Login Failed: $e');
                              } finally {
                                if (mounted) setState(() => _isSpotifyLoading = false);
                              }
                            },
                          ),
                        ));
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1DB954),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isSpotifyLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Login via Web',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildYtmCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.play_circle_filled, color: Colors.red),
              const SizedBox(width: 8),
              const Text(
                'YouTube Music Integration',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Configure YouTube Music by logging in to fetch private playlists.',
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(height: 16),
          if (_isYtmLoggedIn) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.red),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Configured for YouTube Music',
                        style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _logoutYtm,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withOpacity(0.8),
                foregroundColor: Colors.white,
              ),
              child: const Text('Remove Configuration'),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isYtmLoading
                    ? null
                    : () {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (context) => WebviewLoginScreen(
                            title: 'YouTube Music Login',
                            initialUrl: 'https://music.youtube.com',
                            targetCookies: const ['SAPISID'],
                            onLoginComplete: (cookies) async {
                              final homeAddonsCubit = context.read<HomeAddonsCubit>();
                              setState(() => _isYtmLoading = true);
                              try {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setString('ytm_sapisid', cookies['SAPISID']!);
                                await prefs.setString('ytm_cookie', cookies['cookie_string']!);
                                SnackbarService.showMessage('YouTube Music configuration saved');
                                await _checkStatus();
                                homeAddonsCubit.loadHomeData();
                                GlobalEventBus.instance.emitRefresh();
                              } catch (e) {
                                SnackbarService.showMessage('Failed to save YTM config: $e');
                              } finally {
                                if (mounted) setState(() => _isYtmLoading = false);
                              }
                            },
                          ),
                        ));
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isYtmLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Login via Web',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
