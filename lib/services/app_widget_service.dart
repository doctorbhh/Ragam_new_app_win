import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:Bloomee/services/bloomee_player.dart';

/// Service that coordinates live synchronization between [BloomeeMusicPlayer]
/// and the Android Home Screen AppWidget (`RagamPlayerWidgetProvider`).
class AppWidgetService {
  AppWidgetService._();
  static final AppWidgetService instance = AppWidgetService._();

  static const MethodChannel _channel =
      MethodChannel('ls.bloomee.musicplayer/widget');

  BloomeeMusicPlayer? _player;
  StreamSubscription? _mediaItemSub;
  StreamSubscription? _playbackStateSub;
  Timer? _positionTimer;

  bool _isInitialized = false;

  /// Initializes the service and hooks up stream listeners and method handlers.
  static void initialize(BloomeeMusicPlayer player) {
    if (!Platform.isAndroid) return;
    instance._init(player);
  }

  void _init(BloomeeMusicPlayer player) {
    if (_isInitialized) return;
    _isInitialized = true;
    _player = player;

    _channel.setMethodCallHandler(_handleNativeCall);

    _mediaItemSub = player.mediaItem.listen((item) {
      _syncWidget();
    });

    _playbackStateSub = player.playbackState.listen((state) {
      _managePositionTimer(state.playing);
      _syncWidget();
    });

    // Initial push
    _syncWidget();
  }

  void _managePositionTimer(bool isPlaying) {
    _positionTimer?.cancel();
    _positionTimer = null;

    if (isPlaying) {
      _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _syncWidget();
      });
    }
  }

  Future<void> _syncWidget() async {
    final player = _player;
    if (player == null) return;

    final mediaItem = player.mediaItem.value;
    final playbackState = player.playbackState.value;

    final trackArtists = player.currentTrackInfo.artists
        .map((a) => a.name)
        .where((n) => n.trim().isNotEmpty)
        .join(', ');

    final title = mediaItem?.title ??
        (player.currentTrackInfo.title.isNotEmpty
            ? player.currentTrackInfo.title
            : 'Ragam Music');
    final artist = mediaItem?.artist ??
        (trackArtists.isNotEmpty ? trackArtists : 'No track playing');
    final artworkUri = mediaItem?.artUri?.toString() ??
        player.currentTrackInfo.thumbnail.url;

    final isPlaying = playbackState.playing;
    final positionMs = player.engine.position.inMilliseconds;
    final durationMs = (mediaItem?.duration?.inMilliseconds ?? 0) > 0
        ? mediaItem!.duration!.inMilliseconds
        : player.engine.duration.inMilliseconds;

    try {
      await _channel.invokeMethod('updateWidget', {
        'title': title,
        'artist': artist,
        'artworkUri': artworkUri,
        'isPlaying': isPlaying,
        'positionMs': positionMs,
        'durationMs': durationMs,
      });
    } catch (_) {
      // Channel or widget not yet bound or host inactive
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final player = _player;
    if (player == null) return null;

    switch (call.method) {
      case 'playPause':
        if (player.playbackState.value.playing) {
          await player.pause();
        } else {
          await player.play();
        }
        break;

      case 'next':
        await player.skipToNext();
        break;

      case 'prev':
        await player.skipToPrevious();
        break;

      case 'rewind':
        final sec = (call.arguments is Map && call.arguments['seconds'] is num)
            ? (call.arguments['seconds'] as num).toInt()
            : 10;
        await player.seekNSecBackward(Duration(seconds: sec));
        break;

      case 'forward':
        final sec = (call.arguments is Map && call.arguments['seconds'] is num)
            ? (call.arguments['seconds'] as num).toInt()
            : 10;
        await player.seekNSecForward(Duration(seconds: sec));
        break;

      case 'seekTo':
        final posMs = (call.arguments is Map &&
                call.arguments['positionMs'] is num)
            ? (call.arguments['positionMs'] as num).toInt()
            : 0;
        await player.seek(Duration(milliseconds: posMs));
        break;

      default:
        break;
    }
    return true;
  }

  /// Clean up subscriptions if ever needed.
  void dispose() {
    _positionTimer?.cancel();
    _mediaItemSub?.cancel();
    _playbackStateSub?.cancel();
    _isInitialized = false;
    _player = null;
  }
}
