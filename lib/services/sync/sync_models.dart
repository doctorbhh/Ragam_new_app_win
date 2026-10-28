enum SyncMode {
  /// Listen Together: All devices in the party room play audio concurrently with drift compensation.
  party,
}

class SyncDevice {
  final String deviceId;
  final String deviceName;
  final String platform;
  final bool isHost;

  const SyncDevice({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.isHost,
  });

  Map<String, dynamic> toMap() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform,
        'isHost': isHost,
      };

  factory SyncDevice.fromMap(Map<String, dynamic> map) => SyncDevice(
        deviceId: map['deviceId'] as String? ?? '',
        deviceName: map['deviceName'] as String? ?? 'Device',
        platform: map['platform'] as String? ?? 'unknown',
        isHost: map['isHost'] as bool? ?? false,
      );
}

class SyncTrack {
  final String id;
  final String title;
  final String artists;
  final String thumbnail;
  final int durationMs;
  final String? url;

  const SyncTrack({
    required this.id,
    required this.title,
    required this.artists,
    required this.thumbnail,
    required this.durationMs,
    this.url,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'artists': artists,
        'thumbnail': thumbnail,
        'durationMs': durationMs,
        'url': url,
      };

  factory SyncTrack.fromMap(Map<String, dynamic> map) => SyncTrack(
        id: map['id'] as String? ?? '',
        title: map['title'] as String? ?? 'Unknown Title',
        artists: map['artists'] as String? ?? 'Unknown Artist',
        thumbnail: map['thumbnail'] as String? ?? '',
        durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
        url: map['url'] as String?,
      );
}

class SyncPlayback {
  final bool isPlaying;
  final int positionMs;
  final int emittedAt;
  final double speed;

  const SyncPlayback({
    required this.isPlaying,
    required this.positionMs,
    required this.emittedAt,
    this.speed = 1.0,
  });

  Map<String, dynamic> toMap() => {
        'isPlaying': isPlaying,
        'positionMs': positionMs,
        'emittedAt': emittedAt,
        'speed': speed,
      };

  factory SyncPlayback.fromMap(Map<String, dynamic> map) => SyncPlayback(
        isPlaying: map['isPlaying'] as bool? ?? false,
        positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
        emittedAt: (map['emittedAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        speed: (map['speed'] as num?)?.toDouble() ?? 1.0,
      );
}

class SyncRoomState {
  final String roomId;
  final String hostDeviceId;
  final bool isHost;
  final SyncMode mode;
  final String activePlayerId;
  final SyncTrack? track;
  final SyncPlayback playback;
  final List<SyncDevice> connectedDevices;

  const SyncRoomState({
    required this.roomId,
    required this.hostDeviceId,
    required this.isHost,
    required this.mode,
    required this.activePlayerId,
    this.track,
    required this.playback,
    this.connectedDevices = const [],
  });

  SyncRoomState copyWith({
    String? roomId,
    String? hostDeviceId,
    bool? isHost,
    SyncMode? mode,
    String? activePlayerId,
    SyncTrack? track,
    SyncPlayback? playback,
    List<SyncDevice>? connectedDevices,
  }) {
    return SyncRoomState(
      roomId: roomId ?? this.roomId,
      hostDeviceId: hostDeviceId ?? this.hostDeviceId,
      isHost: isHost ?? this.isHost,
      mode: mode ?? this.mode,
      activePlayerId: activePlayerId ?? this.activePlayerId,
      track: track ?? this.track,
      playback: playback ?? this.playback,
      connectedDevices: connectedDevices ?? this.connectedDevices,
    );
  }

  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'hostDeviceId': hostDeviceId,
        'mode': mode.name,
        'activePlayerId': activePlayerId,
        'track': track?.toMap(),
        'playback': playback.toMap(),
      };

  factory SyncRoomState.fromBroadcast({
    required Map<String, dynamic> map,
    required String localDeviceId,
    required List<SyncDevice> devices,
  }) {
    final hostDeviceId = map['hostDeviceId'] as String? ?? '';
    final isHost = hostDeviceId == localDeviceId;
    return SyncRoomState(
      roomId: map['roomId'] as String? ?? '',
      hostDeviceId: hostDeviceId,
      isHost: isHost,
      mode: SyncMode.party,
      activePlayerId: map['activePlayerId'] as String? ?? hostDeviceId,
      track: map['track'] != null
          ? SyncTrack.fromMap(Map<String, dynamic>.from(map['track'] as Map))
          : null,
      playback: map['playback'] != null
          ? SyncPlayback.fromMap(
              Map<String, dynamic>.from(map['playback'] as Map))
          : SyncPlayback(
              isPlaying: false,
              positionMs: 0,
              emittedAt: DateTime.now().millisecondsSinceEpoch,
            ),
      connectedDevices: devices,
    );
  }
}
