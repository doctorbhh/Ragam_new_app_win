import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/routes/app_router.dart';
import 'package:Bloomee/screens/widgets/bloomee_ui_kit/bloomee_dialog.dart';
import 'package:Bloomee/services/bloomee_player.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/sync/sync_models.dart';
import 'package:rxdart/rxdart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum SyncJoinStatus {
  idle,
  checkingRoom,
  waitingForApproval,
  approved,
  declined,
  roomNotFound,
  timeout,
}

class SyncJoinException implements Exception {
  final String message;
  SyncJoinException(this.message);
  @override
  String toString() => message;
}

class RagamSyncService {
  RagamSyncService._();
  static final RagamSyncService instance = RagamSyncService._();

  // Default community relay fallback (can be overridden by user in Settings)
  static const String defaultUrl = 'https://sygfptakwqyffrwwpzrg.supabase.co';
  static const String defaultAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN5Z2ZwdGFrd3F5ZmZyd3dwenJnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Mjc5NzEyMDAsImV4cCI6MjA0MzU0NzIwMH0.d9jY4n8294nd823hd92hf92hf';

  BloomeeMusicPlayer? _player;
  SupabaseClient? _client;
  RealtimeChannel? _channel;

  late String _deviceId;
  late String _deviceName;
  bool _isHost = false;
  String? _currentRoomId;
  SyncMode _mode = SyncMode.party;
  bool isApplyingPartySync = false;
  bool _isGuestManuallyPaused = false;
  String? _lastPartyTrackId;

  // Guest join state management
  RealtimeChannel? _tempJoinChannel;
  Completer<bool>? _pendingApprovalCompleter;
  String? _currentJoinRequestId;

  // Host approval dialog queue and active request tracking
  final Set<String> _handledRequestIds = {};
  String? _activeDialogRequestId;
  BuildContext? _activeDialogContext;
  Completer<void>? _activeDialogCompleter;

  bool get isGuestManuallyPaused => _isGuestManuallyPaused;

  void guestPauseLocal() {
    _isGuestManuallyPaused = true;
    _driftCheckDebounce?.cancel();
  }

  void guestResumeLocal() {
    _isGuestManuallyPaused = false;
    final state = roomState.value;
    final player = _player;
    if (state != null && player != null && state.track != null) {
      final latency = (DateTime.now().millisecondsSinceEpoch - state.playback.emittedAt).clamp(0, 3000);
      final targetPosMs = state.playback.positionMs + (state.playback.isPlaying ? latency : 0);
      player.seek(Duration(milliseconds: targetPosMs.clamp(0, state.track!.durationMs)));
    }
  }

  final BehaviorSubject<SyncRoomState?> roomState =
      BehaviorSubject<SyncRoomState?>.seeded(null);
  final BehaviorSubject<bool> isConnected =
      BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<List<SyncDevice>> connectedDevices =
      BehaviorSubject<List<SyncDevice>>.seeded([]);
  final BehaviorSubject<SyncJoinStatus> joinStatus =
      BehaviorSubject<SyncJoinStatus>.seeded(SyncJoinStatus.idle);

  StreamSubscription? _playerMediaSub;
  StreamSubscription? _playerStateSub;
  Timer? _hostBroadcastTimer;
  Timer? _driftCheckDebounce;

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  bool get isInRoom => _currentRoomId != null;
  String? get currentRoomId => _currentRoomId;
  bool get isHost => _isHost;
  SyncMode get currentMode => _mode;

  /// Initializes device identity and hooks into player streams.
  Future<void> initialize(BloomeeMusicPlayer player) async {
    _player = player;
    final settingsDao = SettingsDAO(DBProvider.db);

    // Setup persistent unique device ID
    var storedId = await settingsDao.getSettingStr('sync_local_device_id');
    if (storedId == null || storedId.isEmpty) {
      storedId = 'dev_${math.Random().nextInt(900000) + 100000}_${DateTime.now().millisecondsSinceEpoch % 10000}';
      await settingsDao.putSettingStr('sync_local_device_id', storedId);
    }
    _deviceId = storedId;

    // Setup device name
    var storedName = await settingsDao.getSettingStr(SettingKeys.syncDeviceName);
    if (storedName == null || storedName.isEmpty) {
      final os = Platform.operatingSystem;
      storedName = 'Ragam on ${os[0].toUpperCase()}${os.substring(1)}';
      await settingsDao.putSettingStr(SettingKeys.syncDeviceName, storedName);
    }
    _deviceName = storedName;

    await _initSupabaseClient();
    unawaited(_purgeStaleRooms());
  }

  Future<void> _initSupabaseClient() async {
    final settingsDao = SettingsDAO(DBProvider.db);
    final customUrl = await settingsDao.getSettingStr(SettingKeys.syncCustomSupabaseUrl);
    final customKey = await settingsDao.getSettingStr(SettingKeys.syncCustomSupabaseKey);

    final url = (customUrl != null && customUrl.trim().isNotEmpty)
        ? customUrl.trim()
        : defaultUrl;
    final key = (customKey != null && customKey.trim().isNotEmpty)
        ? customKey.trim()
        : defaultAnonKey;

    try {
      _client = SupabaseClient(
        url,
        key,
        realtimeClientOptions: const RealtimeClientOptions(
          eventsPerSecond: 10,
        ),
      );
    } catch (e) {
      log('Failed to initialize Supabase client: $e', name: 'RagamSyncService');
    }
  }

  /// Sets custom user-provided Supabase project credentials (BYOD).
  Future<void> updateCustomSupabase({String? url, String? anonKey}) async {
    final settingsDao = SettingsDAO(DBProvider.db);
    if (url != null) {
      await settingsDao.putSettingStr(SettingKeys.syncCustomSupabaseUrl, url);
    }
    if (anonKey != null) {
      await settingsDao.putSettingStr(SettingKeys.syncCustomSupabaseKey, anonKey);
    }
    if (isInRoom) {
      await leaveRoom();
    }
    await _initSupabaseClient();
  }

  /// Formats and normalizes room codes (e.g. "rag842" -> "RAG-842").
  String normalizeRoomCode(String input) {
    final clean = input.replaceAll('-', '').trim().toUpperCase();
    if (clean.length == 6) {
      return '${clean.substring(0, 3)}-${clean.substring(3)}';
    }
    return input.trim().toUpperCase();
  }

  /// Generates a short 6-character room code (e.g. "RAG-492").
  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = math.Random();
    final p1 = List.generate(3, (_) => chars[rand.nextInt(chars.length)]).join();
    final p2 = List.generate(3, (_) => chars[rand.nextInt(chars.length)]).join();
    return '$p1-$p2';
  }

  /// Creates a new room as Host.
  Future<String> createRoom({SyncMode mode = SyncMode.party}) async {
    if (_client == null) await _initSupabaseClient();
    if (_client == null) throw Exception('Supabase client not initialized');

    unawaited(_purgeStaleRooms());
    await leaveRoom();

    final roomId = _generateRoomCode();
    _currentRoomId = roomId;
    _isHost = true;
    _mode = mode;

    await _connectToChannel(roomId);
    _setupHostBroadcast();

    // Register room in party_rooms table if available
    try {
      final client = _client;
      if (client != null) {
        await client.from('party_rooms').upsert({
          'id': roomId,
          'host_device_id': _deviceId,
          'host_name': _deviceName,
          'current_track_title': 'None',
          'current_track_artist': '',
          'is_playing': false,
          'position_ms': 0,
          'listeners_count': 1,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    } catch (_) {}

    return roomId;
  }

  /// Joins an existing room as Guest (requires room verification and host approval).
  Future<bool> joinRoom(String roomId, {SyncMode mode = SyncMode.party}) async {
    if (_client == null) await _initSupabaseClient();
    final client = _client;
    if (client == null) {
      throw SyncJoinException('Sync service not initialized. Check your connection.');
    }

    final cleanId = normalizeRoomCode(roomId);
    if (cleanId.length < 5) {
      throw SyncJoinException('Invalid room code format. Example: RAG-842');
    }

    if (_isHost && _currentRoomId == cleanId) {
      throw SyncJoinException('You are already hosting this room.');
    }

    await leaveRoom();

    joinStatus.add(SyncJoinStatus.checkingRoom);

    // 1. Verify existence in DB (if party_rooms table is available)
    bool existsInDb = false;
    try {
      final res = await client
          .from('party_rooms')
          .select('id, host_device_id')
          .eq('id', cleanId)
          .maybeSingle();
      if (res != null && res['id'] != null) {
        existsInDb = true;
      }
    } catch (_) {}

    // 2. Connect temporary channel to verify host presence and knock
    final channelName = 'ragam_sync_${cleanId.replaceAll('-', '')}';
    final tempChannel = client.channel(
      channelName,
      opts: const RealtimeChannelConfig(
        self: false,
        ack: false,
      ),
    );
    _tempJoinChannel = tempChannel;

    // Early registration so no state_sync broadcasts from host are missed
    tempChannel.onBroadcast(
      event: 'state_sync',
      callback: (payload) {
        if (isInRoom && !_isHost) {
          _handleStateSync(payload);
        }
      },
    );

    tempChannel.onPresenceSync((_) {
      if (isInRoom) {
        _syncPresenceDevices();
      }
    });

    final subCompleter = Completer<bool>();
    tempChannel.subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.subscribed && !subCompleter.isCompleted) {
        subCompleter.complete(true);
      } else if ((status == RealtimeSubscribeStatus.closed ||
              status == RealtimeSubscribeStatus.timedOut) &&
          !subCompleter.isCompleted) {
        subCompleter.complete(false);
      }
    });

    final subOk = await subCompleter.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () => false,
    );

    if (!subOk) {
      try {
        await client.removeChannel(tempChannel);
      } catch (_) {}
      _tempJoinChannel = null;
      joinStatus.add(SyncJoinStatus.idle);
      throw SyncJoinException('Could not connect to sync network. Check your connection.');
    }

    // 3. Ping Host to verify host is alive and responding
    final pingId = 'ping_${DateTime.now().millisecondsSinceEpoch}';
    final pingCompleter = Completer<bool>();

    tempChannel.onBroadcast(
      event: 'pong_host',
      callback: (payload) {
        if (payload['pingId'] == pingId || payload['targetDeviceId'] == _deviceId) {
          if (!pingCompleter.isCompleted) {
            pingCompleter.complete(true);
          }
        }
      },
    );

    try {
      await tempChannel.sendBroadcastMessage(
        event: 'ping_host',
        payload: {
          'pingId': pingId,
          'senderDeviceId': _deviceId,
          'senderDeviceName': _deviceName,
          'roomId': cleanId,
        },
      );
    } catch (_) {}

    // Check if host is already tracked in presence
    bool hostAlive = false;
    try {
      final presState = tempChannel.presenceState();
      for (final entry in presState) {
        for (final pres in entry.presences) {
          final p = pres.payload;
          if (p['isHost'] == true && p['deviceId'] != _deviceId) {
            hostAlive = true;
            break;
          }
        }
      }
    } catch (_) {}

    if (!hostAlive) {
      hostAlive = await pingCompleter.future.timeout(
        const Duration(milliseconds: 2500),
        onTimeout: () => false,
      );
    }

    // If neither DB nor host ping confirmed room existence / online host
    if (!hostAlive) {
      try {
        await client.removeChannel(tempChannel);
      } catch (_) {}
      _tempJoinChannel = null;
      joinStatus.add(SyncJoinStatus.roomNotFound);
      if (existsInDb) {
        throw SyncJoinException('Host for room "$cleanId" is currently offline.');
      } else {
        throw SyncJoinException('Room "$cleanId" does not exist or host is offline.');
      }
    }

    // 4. Host is online! Send join approval request (Knock)
    joinStatus.add(SyncJoinStatus.waitingForApproval);

    final requestId =
        'req_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(9999)}';
    _currentJoinRequestId = requestId;

    final approvalCompleter = Completer<bool>();
    _pendingApprovalCompleter = approvalCompleter;
    Map<String, dynamic>? initialHostStatePayload;
    String hostDeviceId = '';
    String hostDeviceName = '';

    tempChannel.onBroadcast(
      event: 'join_response',
      callback: (payload) {
        if (payload['targetDeviceId'] == _deviceId &&
            payload['requestId'] == requestId) {
          final approved = payload['approved'] as bool? ?? false;
          if (payload['hostState'] is Map) {
            initialHostStatePayload =
                Map<String, dynamic>.from(payload['hostState'] as Map);
          }
          hostDeviceId = payload['hostDeviceId'] as String? ?? '';
          hostDeviceName = payload['hostDeviceName'] as String? ?? '';

          if (approved) {
            // Immediately activate room credentials to defeat any incoming state sync race
            _tempJoinChannel = null;
            _channel = tempChannel;
            _currentRoomId = cleanId;
            _isHost = false;
            _mode = mode;
            _lastPartyTrackId = null;
            _isGuestManuallyPaused = false;
          }

          if (!approvalCompleter.isCompleted) {
            approvalCompleter.complete(approved);
          }
        }
      },
    );

    try {
      await tempChannel.sendBroadcastMessage(
        event: 'join_request',
        payload: {
          'requestId': requestId,
          'roomId': cleanId,
          'guestDeviceId': _deviceId,
          'guestDeviceName': _deviceName,
          'platform': Platform.operatingSystem,
        },
      );
    } catch (e) {
      try {
        await client.removeChannel(tempChannel);
      } catch (_) {}
      _tempJoinChannel = null;
      _currentJoinRequestId = null;
      _pendingApprovalCompleter = null;
      joinStatus.add(SyncJoinStatus.idle);
      throw SyncJoinException('Failed to send join request: $e');
    }

    bool approved = false;
    try {
      approved = await approvalCompleter.future.timeout(
        const Duration(seconds: 25),
      );
    } on TimeoutException {
      try {
        await client.removeChannel(tempChannel);
      } catch (_) {}
      _tempJoinChannel = null;
      _pendingApprovalCompleter = null;
      _currentJoinRequestId = null;
      _currentRoomId = null;
      _channel = null;
      joinStatus.add(SyncJoinStatus.timeout);
      throw SyncJoinException('Host did not respond in time. Request timed out.');
    }

    _pendingApprovalCompleter = null;
    _currentJoinRequestId = null;

    if (!approved) {
      try {
        await client.removeChannel(tempChannel);
      } catch (_) {}
      _tempJoinChannel = null;
      _currentRoomId = null;
      _channel = null;
      joinStatus.add(SyncJoinStatus.declined);
      throw SyncJoinException('Host declined your request to join room $cleanId.');
    }

    // 5. Host approved! Promote tempChannel to active room channel
    _tempJoinChannel = null;
    _channel = tempChannel;
    _currentRoomId = cleanId;
    _isHost = false;
    _mode = mode;
    _lastPartyTrackId = null;
    _isGuestManuallyPaused = false;

    // Immediately assemble connected devices with host & self
    final initialDevs = List<SyncDevice>.from(connectedDevices.value);
    if (hostDeviceId.isNotEmpty && !initialDevs.any((d) => d.deviceId == hostDeviceId)) {
      initialDevs.add(SyncDevice(
        deviceId: hostDeviceId,
        deviceName: hostDeviceName.isNotEmpty ? hostDeviceName : 'Host',
        platform: 'device',
        isHost: true,
      ));
    }
    if (!initialDevs.any((d) => d.deviceId == _deviceId)) {
      initialDevs.add(SyncDevice(
        deviceId: _deviceId,
        deviceName: _deviceName,
        platform: Platform.operatingSystem,
        isHost: false,
      ));
    }
    connectedDevices.add(initialDevs);

    if (initialHostStatePayload != null) {
      try {
        final state = SyncRoomState.fromBroadcast(
          map: initialHostStatePayload!,
          localDeviceId: _deviceId,
          devices: initialDevs,
        );
        roomState.add(state);
        _applyPartySync(state);
      } catch (e) {
        log('Error applying initial host state: $e', name: 'RagamSyncService');
      }
    } else {
      final initialRoomState = SyncRoomState(
        roomId: cleanId,
        hostDeviceId: hostDeviceId,
        isHost: false,
        mode: mode,
        activePlayerId: hostDeviceId,
        track: null,
        playback: SyncPlayback(
          isPlaying: false,
          positionMs: 0,
          emittedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        connectedDevices: initialDevs,
      );
      roomState.add(initialRoomState);
    }

    _setupGuestChannelListeners(tempChannel);

    // Track guest presence now that we are approved
    await tempChannel.track({
      'deviceId': _deviceId,
      'deviceName': _deviceName,
      'platform': Platform.operatingSystem,
      'isHost': false,
    });

    _syncPresenceDevices();

    // Explicitly request playback state from host right now
    try {
      await tempChannel.sendBroadcastMessage(
        event: 'request_state',
        payload: {
          'senderDeviceId': _deviceId,
          'roomId': cleanId,
        },
      );
    } catch (_) {}

    isConnected.add(true);
    joinStatus.add(SyncJoinStatus.idle);
    return true;
  }

  /// Cancels any pending join request (e.g. user pressed cancel or dismissed bottom sheet).
  void cancelJoinRequest() {
    if (_pendingApprovalCompleter != null && !_pendingApprovalCompleter!.isCompleted) {
      _pendingApprovalCompleter!.complete(false);
    }
    _pendingApprovalCompleter = null;

    final tempChan = _tempJoinChannel;
    if (tempChan != null) {
      if (_currentJoinRequestId != null) {
        try {
          tempChan.sendBroadcastMessage(
            event: 'cancel_join_request',
            payload: {
              'guestDeviceId': _deviceId,
              'requestId': _currentJoinRequestId,
            },
          );
        } catch (_) {}
      }
      try {
        _client?.removeChannel(tempChan);
      } catch (_) {}
      _tempJoinChannel = null;
    }
    _currentJoinRequestId = null;
    joinStatus.add(SyncJoinStatus.idle);
  }

  /// Shows the host an approval dialog when a guest knocks to join.
  Future<bool> _showHostApprovalDialog({
    required String requestId,
    required String guestDeviceName,
    required String platform,
  }) async {
    while (_activeDialogCompleter != null && !_activeDialogCompleter!.isCompleted) {
      await _activeDialogCompleter!.future;
    }

    final dialogCompleter = Completer<void>();
    _activeDialogCompleter = dialogCompleter;
    _activeDialogRequestId = requestId;

    bool approved = false;
    try {
      var context = AppRouter.globalRouterKey.currentContext;
      if (context == null || !context.mounted) {
        await Future.delayed(const Duration(milliseconds: 300));
        context = AppRouter.globalRouterKey.currentContext;
      }

      if (context != null && context.mounted) {
        _activeDialogContext = context;
        bool? clickedChoice;
        final res = await showBloomeeDialog<bool>(
          context: context,
          barrierDismissible: false,
          icon: Icons.person_add_rounded,
          title: 'Party Room Request',
          subtitle:
              '"$guestDeviceName" ($platform) wants to join your party room. Allow them to listen together?',
          actions: [
            BloomeeDialogAction.text(
              'Decline',
              isDestructive: true,
              result: false,
              onPressed: () {
                clickedChoice = false;
              },
            ),
            BloomeeDialogAction.filled(
              'Allow',
              result: true,
              onPressed: () {
                clickedChoice = true;
              },
            ),
          ],
        );
        approved = (clickedChoice == true || res == true);
      }
    } catch (e) {
      log('Error presenting join approval dialog: $e', name: 'RagamSyncService');
    } finally {
      _activeDialogRequestId = null;
      _activeDialogContext = null;
      if (!dialogCompleter.isCompleted) {
        dialogCompleter.complete();
      }
    }
    return approved;
  }

  Future<void> _handleIncomingJoinRequest(Map<String, dynamic> payload) async {
    final requestId = payload['requestId'] as String? ?? '';
    final guestDeviceId = payload['guestDeviceId'] as String? ?? '';
    final guestDeviceName = payload['guestDeviceName'] as String? ?? 'A friend';
    final platform = payload['platform'] as String? ?? 'device';
    final reqRoomId = payload['roomId'] as String? ?? '';

    if (requestId.isEmpty ||
        _handledRequestIds.contains(requestId) ||
        guestDeviceId == _deviceId ||
        reqRoomId != _currentRoomId) {
      return;
    }
    _handledRequestIds.add(requestId);
    if (_handledRequestIds.length > 50) {
      _handledRequestIds.remove(_handledRequestIds.first);
    }

    final approved = await _showHostApprovalDialog(
      requestId: requestId,
      guestDeviceName: guestDeviceName,
      platform: platform,
    );

    final channel = _channel;
    if (channel != null && isInRoom && _isHost) {
      try {
        final hostSnapshot = approved ? _buildCurrentStateSnapshot() : null;
        await channel.sendBroadcastMessage(
          event: 'join_response',
          payload: {
            'requestId': requestId,
            'targetDeviceId': guestDeviceId,
            'approved': approved,
            'hostDeviceName': _deviceName,
            'hostDeviceId': _deviceId,
            'hostState': hostSnapshot?.toMap(),
          },
        );

        if (approved) {
          // Immediately add guest to local connectedDevices list on host
          final currentDevs = List<SyncDevice>.from(connectedDevices.value);
          if (!currentDevs.any((d) => d.deviceId == guestDeviceId)) {
            currentDevs.add(SyncDevice(
              deviceId: guestDeviceId,
              deviceName: guestDeviceName,
              platform: platform,
              isHost: false,
            ));
            connectedDevices.add(currentDevs);
            final curRoom = roomState.value;
            if (curRoom != null) {
              roomState.add(curRoom.copyWith(connectedDevices: currentDevs));
            }
          }

          // Broadcast state bursts so guest reliably receives playback immediately
          _broadcastCurrentState();
          Future.delayed(const Duration(milliseconds: 200), () {
            if (isInRoom && _isHost) _broadcastCurrentState();
          });
          Future.delayed(const Duration(milliseconds: 600), () {
            if (isInRoom && _isHost) _broadcastCurrentState();
          });
          Future.delayed(const Duration(milliseconds: 1200), () {
            if (isInRoom && _isHost) _broadcastCurrentState();
          });
        }
      } catch (e) {
        log('Failed to send join response: $e', name: 'RagamSyncService');
      }
    }
  }

  void _setupGuestChannelListeners(RealtimeChannel channel) {
    // Note: guest pause isolation is managed via BloomeeMusicPlayer.pause()/play().
    // We avoid listening directly to playbackState here to prevent engine pause
    // events from mistakenly setting _isGuestManuallyPaused when host pauses.
  }

  /// Automatically deletes inactive/abandoned rooms older than 30 minutes from the database.
  Future<void> _purgeStaleRooms() async {
    final client = _client;
    if (client == null) return;
    try {
      final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 30)).toIso8601String();
      await client.from('party_rooms').delete().lt('updated_at', cutoff);
    } catch (_) {
      // Safe fallback if party_rooms table does not exist
    }
  }

  Future<void> _connectToChannel(String roomId) async {
    final client = _client;
    if (client == null) return;

    final channelName = 'ragam_sync_${roomId.replaceAll('-', '')}';
    final channel = client.channel(
      channelName,
      opts: const RealtimeChannelConfig(
        self: false,
        ack: false,
      ),
    );

    _channel = channel;

    // Listen for state sync broadcast
    channel.onBroadcast(
      event: 'state_sync',
      callback: (payload) {
        _handleStateSync(payload);
      },
    );

    // Listen for control commands (from guests to host)
    channel.onBroadcast(
      event: 'control_command',
      callback: (payload) {
        if (_isHost) {
          _handleControlCommand(payload);
        }
      },
    );

    // Host responds to ping from prospective guests
    channel.onBroadcast(
      event: 'ping_host',
      callback: (payload) {
        if (!_isHost) return;
        final pingId = payload['pingId'] as String? ?? '';
        final senderDeviceId = payload['senderDeviceId'] as String? ?? '';
        try {
          channel.sendBroadcastMessage(
            event: 'pong_host',
            payload: {
              'pingId': pingId,
              'targetDeviceId': senderDeviceId,
              'hostDeviceId': _deviceId,
              'hostDeviceName': _deviceName,
              'roomId': _currentRoomId,
            },
          );
        } catch (_) {}
      },
    );

    // Host handles join requests from guests (requires host approval)
    channel.onBroadcast(
      event: 'join_request',
      callback: (payload) {
        if (!_isHost) return;
        _handleIncomingJoinRequest(payload);
      },
    );

    // Host handles cancellation from guests who stopped waiting
    channel.onBroadcast(
      event: 'cancel_join_request',
      callback: (payload) {
        if (!_isHost) return;
        final cancelReqId = payload['requestId'] as String? ?? '';
        if (_activeDialogRequestId != null && _activeDialogRequestId == cancelReqId) {
          final ctx = _activeDialogContext;
          if (ctx != null && ctx.mounted) {
            try {
              Navigator.of(ctx, rootNavigator: true).pop(false);
            } catch (_) {}
          }
          _activeDialogRequestId = null;
        }
      },
    );

    // Host handles request_state from newly approved guests
    channel.onBroadcast(
      event: 'request_state',
      callback: (payload) {
        if (_isHost && isInRoom) {
          _broadcastCurrentState();
        }
      },
    );

    // Listen for presence changes
    channel.onPresenceSync((_) {
      _syncPresenceDevices();
    });

    channel.subscribe((status, error) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        isConnected.add(true);
        // Track self in presence
        await channel.track({
          'deviceId': _deviceId,
          'deviceName': _deviceName,
          'platform': Platform.operatingSystem,
          'isHost': _isHost,
        });

        if (_isHost) {
          _broadcastCurrentState();
        }
      } else if (status == RealtimeSubscribeStatus.closed ||
          status == RealtimeSubscribeStatus.timedOut) {
        isConnected.add(false);
      }
    });
  }

  void _syncPresenceDevices() {
    final channel = _channel;
    if (channel == null) return;

    try {
      final presenceState = channel.presenceState();
      final List<SyncDevice> list = [];

      for (final entry in presenceState) {
        for (final pres in entry.presences) {
          final payload = pres.payload;
          final dev = SyncDevice.fromMap(Map<String, dynamic>.from(payload));
          if (dev.deviceId.isNotEmpty &&
              !list.any((d) => d.deviceId == dev.deviceId)) {
            list.add(dev);
          }
        }
      }

      // Preserve previously approved/known devices (so host or guests are not wiped if presence sync is slow)
      for (final dev in connectedDevices.value) {
        if (!list.any((d) => d.deviceId == dev.deviceId)) {
          list.add(dev);
        }
      }

      // Ensure local device is present
      if (!list.any((d) => d.deviceId == _deviceId)) {
        list.add(SyncDevice(
          deviceId: _deviceId,
          deviceName: _deviceName,
          platform: Platform.operatingSystem,
          isHost: _isHost,
        ));
      }

      connectedDevices.add(list);

      // Update room state with devices
      final current = roomState.value;
      if (current != null) {
        roomState.add(current.copyWith(connectedDevices: list));
      }
    } catch (e) {
      log('Error syncing presence: $e', name: 'RagamSyncService');
    }
  }

  void _setupHostBroadcast() {
    final player = _player;
    if (player == null) return;

    _playerMediaSub?.cancel();
    _playerMediaSub = player.mediaItem.listen((_) {
      if (_isHost && isInRoom) _broadcastCurrentState();
    });

    _playerStateSub?.cancel();
    _playerStateSub = player.playbackState.listen((_) {
      if (_isHost && isInRoom) _broadcastCurrentState();
    });

    _hostBroadcastTimer?.cancel();
    _hostBroadcastTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isHost && isInRoom) {
        _broadcastCurrentState();
      }
    });
  }

  /// Immediately broadcasts the host's current state to the room (called on play, pause, seek).
  void broadcastNow({bool? forcePlaying}) {
    if (_isHost && isInRoom) {
      _broadcastCurrentState(forcePlaying: forcePlaying);
    }
  }

  SyncRoomState? _buildCurrentStateSnapshot({bool? forcePlaying}) {
    final player = _player;
    if (player == null || !isInRoom || !_isHost) return null;

    final mediaItem = player.mediaItem.value;
    final playbackState = player.playbackState.value;
    final currentMedia = player.currentMedia;

    SyncTrack? track;
    if (mediaItem != null) {
      track = SyncTrack(
        id: mediaItem.id,
        title: mediaItem.title,
        artists: mediaItem.artist ?? '',
        thumbnail: mediaItem.artUri?.toString() ?? '',
        durationMs: mediaItem.duration?.inMilliseconds ?? 0,
      );
    } else if (player.currentTrackInfo.id.isNotEmpty) {
      final t = player.currentTrackInfo;
      track = SyncTrack(
        id: t.id,
        title: t.title,
        artists: t.artists.map((a) => a.name).join(', '),
        thumbnail: t.thumbnail.url,
        durationMs: (t.durationMs?.toInt()) ?? 0,
      );
    } else if (currentMedia.id.isNotEmpty) {
      track = SyncTrack(
        id: currentMedia.id,
        title: currentMedia.title,
        artists: currentMedia.artists.map((a) => a.name).join(', '),
        thumbnail: currentMedia.thumbnail.url,
        durationMs: (currentMedia.durationMs?.toInt()) ?? 0,
      );
    }

    final isPlaying = forcePlaying ?? (player.engine.playing || playbackState.playing);

    final playback = SyncPlayback(
      isPlaying: isPlaying,
      positionMs: player.engine.position.inMilliseconds,
      emittedAt: DateTime.now().millisecondsSinceEpoch,
    );

    return SyncRoomState(
      roomId: _currentRoomId!,
      hostDeviceId: _deviceId,
      isHost: true,
      mode: _mode,
      activePlayerId: _deviceId,
      track: track,
      playback: playback,
      connectedDevices: connectedDevices.value,
    );
  }

  Future<void> _broadcastCurrentState({bool? forcePlaying}) async {
    final snapshot = _buildCurrentStateSnapshot(forcePlaying: forcePlaying);
    final channel = _channel;
    if (snapshot == null || channel == null || !isInRoom || !_isHost) return;

    roomState.add(snapshot);

    try {
      await channel.sendBroadcastMessage(
        event: 'state_sync',
        payload: snapshot.toMap(),
      );
    } catch (e) {
      log('Broadcast failed: $e', name: 'RagamSyncService');
    }

    // Persist to Supabase Postgres database (party_rooms table) if available
    try {
      final client = _client;
      if (client != null && _currentRoomId != null) {
        await client.from('party_rooms').upsert({
          'id': _currentRoomId,
          'host_device_id': _deviceId,
          'host_name': _deviceName,
          'current_track_title': snapshot.track?.title ?? 'None',
          'current_track_artist': snapshot.track?.artists ?? '',
          'is_playing': snapshot.playback.isPlaying,
          'position_ms': snapshot.playback.positionMs,
          'listeners_count': connectedDevices.value.length,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    } catch (_) {
      // Safe fallback if user hasn't created the party_rooms table in Supabase
    }
  }

  void _handleStateSync(Map<String, dynamic> payload) {
    if (_isHost) return; // Host generates state, never overwrites from broadcast

    try {
      final state = SyncRoomState.fromBroadcast(
        map: payload,
        localDeviceId: _deviceId,
        devices: connectedDevices.value,
      );

      _mode = SyncMode.party;
      roomState.add(state);
      _applyPartySync(state);
    } catch (e) {
      log('Error handling state sync: $e', name: 'RagamSyncService');
    }
  }

  /// In Party Mode: synchronizes guest audio playback and corrects audio drift.
  void _applyPartySync(SyncRoomState state) {
    final player = _player;
    if (player == null) return;
    if (state.track == null) {
      if (player.engine.playing) {
        player.pause();
      }
      return;
    }

    isApplyingPartySync = true;
    try {
      final targetTrackId = state.track!.id;
      final isNewSong = targetTrackId.isNotEmpty && targetTrackId != _lastPartyTrackId;

      // Track changed by host: resolve and play new track for everyone in room
      if (isNewSong) {
        _lastPartyTrackId = targetTrackId;
        _isGuestManuallyPaused = false; // Reset local pause on new song
        final newTrack = Track(
          id: state.track!.id,
          title: state.track!.title,
          artists: [ArtistSummary(id: '', name: state.track!.artists)],
          thumbnail: Artwork(url: state.track!.thumbnail, layout: ImageLayout.square),
          durationMs: BigInt.from(state.track!.durationMs),
          isExplicit: false,
        );

        final latency = (DateTime.now().millisecondsSinceEpoch - state.playback.emittedAt).clamp(0, 3000);
        final targetPosMs = (state.playback.positionMs + (state.playback.isPlaying ? latency : 0)).clamp(0, state.track!.durationMs);

        player.updateQueueTracks(
          [newTrack],
          doPlay: state.playback.isPlaying,
          initialPosition: Duration(milliseconds: targetPosMs),
        );
        return;
      }

      final isPlaying = state.playback.isPlaying;
      final isLocalPlaying = player.engine.playing;

      // If host stopped/paused, pause ALL connected devices in the room
      if (!isPlaying) {
        _isGuestManuallyPaused = false; // Reset on host pause so host next play triggers all members!
        if (isLocalPlaying) {
          player.pause();
        }
        return;
      }

      // Host is playing: check if this guest deliberately paused their local playback
      if (_isGuestManuallyPaused) {
        if (isLocalPlaying) {
          player.pause();
        }
        return;
      }

      // Guest is not paused: start playing if not already
      if (!isLocalPlaying) {
        final latency = (DateTime.now().millisecondsSinceEpoch - state.playback.emittedAt).clamp(0, 3000);
        final targetPosMs = (state.playback.positionMs + latency).clamp(0, state.track!.durationMs);
        final localPosMs = player.engine.position.inMilliseconds;
        if ((targetPosMs - localPosMs).abs() > 1500) {
          player.seek(Duration(milliseconds: targetPosMs));
        }
        player.play();
      }

      // ─── Gentle Audio Drift Adjustment (Reverted to prevent noise/clicks) ───
      // Small ~1s timing offsets are normal and smooth. We do NOT perform rapid micro-seeks.
      // We only seek if there is a major desync (e.g. host manually jumped ahead by >2.5 seconds).
      final latency = (DateTime.now().millisecondsSinceEpoch - state.playback.emittedAt).clamp(0, 3000);
      final targetPosMs = state.playback.positionMs + (isPlaying ? latency : 0);
      final localPosMs = player.engine.position.inMilliseconds;
      final driftMs = (targetPosMs - localPosMs).abs();

      if (driftMs > 2500 && state.track!.durationMs > 0) {
        _driftCheckDebounce?.cancel();
        _driftCheckDebounce = Timer(const Duration(milliseconds: 300), () {
          isApplyingPartySync = true;
          try {
            player.seek(Duration(milliseconds: targetPosMs.clamp(0, state.track!.durationMs)));
          } finally {
            isApplyingPartySync = false;
          }
        });
      }
    } finally {
      isApplyingPartySync = false;
    }
  }

  void _handleControlCommand(Map<String, dynamic> payload) {
    final player = _player;
    if (player == null) return;

    final cmd = payload['command'] as String? ?? '';
    final posMs = (payload['positionMs'] as num?)?.toInt();

    switch (cmd) {
      case 'play':
        player.play();
        break;
      case 'pause':
        player.pause();
        break;
      case 'playPause':
        if (player.playbackState.value.playing) {
          player.pause();
        } else {
          player.play();
        }
        break;
      case 'next':
        player.skipToNext();
        break;
      case 'prev':
        player.skipToPrevious();
        break;
      case 'seek':
        if (posMs != null) {
          player.seek(Duration(milliseconds: posMs));
        }
        break;
    }

    // Immediately broadcast new state after applying command
    Future.delayed(const Duration(milliseconds: 50), () {
      _broadcastCurrentState();
    });
  }

  /// Sends a playback control command from Guest to Host.
  Future<void> sendControlCommand(String command, {int? positionMs}) async {
    final channel = _channel;
    if (channel == null || !isInRoom) return;

    if (_isHost) {
      // Direct local execution if called on host
      _handleControlCommand({'command': command, 'positionMs': positionMs});
      return;
    }

    try {
      await channel.sendBroadcastMessage(
        event: 'control_command',
        payload: {
          'senderDeviceId': _deviceId,
          'command': command,
          'positionMs': positionMs,
        },
      );
    } catch (e) {
      log('Failed to send control command: $e', name: 'RagamSyncService');
    }
  }

  /// Switches operating mode (Remote Control / Mirror vs Party Room).
  Future<void> setSyncMode(SyncMode newMode) async {
    _mode = newMode;
    if (_isHost) {
      await _broadcastCurrentState();
    }
    final current = roomState.value;
    if (current != null) {
      roomState.add(current.copyWith(mode: newMode));
    }
  }

  /// Sets device display name.
  Future<void> setDeviceName(String name) async {
    _deviceName = name;
    await SettingsDAO(DBProvider.db).putSettingStr(SettingKeys.syncDeviceName, name);
    if (isInRoom && _channel != null) {
      await _channel!.track({
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'platform': Platform.operatingSystem,
        'isHost': _isHost,
      });
    }
  }

  /// Disconnects from current room and resets state.
  Future<void> leaveRoom() async {
    _hostBroadcastTimer?.cancel();
    _hostBroadcastTimer = null;
    _playerMediaSub?.cancel();
    _playerMediaSub = null;
    _playerStateSub?.cancel();
    _playerStateSub = null;
    _driftCheckDebounce?.cancel();
    cancelJoinRequest();

    if (_channel != null) {
      try {
        await _channel!.untrack();
        await _client?.removeChannel(_channel!);
      } catch (_) {}
      _channel = null;
    }

    if (_isHost && _currentRoomId != null) {
      try {
        await _client?.from('party_rooms').delete().eq('id', _currentRoomId!);
      } catch (_) {}
    }
    _lastPartyTrackId = null;
    _isGuestManuallyPaused = false;
    _currentRoomId = null;
    _isHost = false;
    joinStatus.add(SyncJoinStatus.idle);
    roomState.add(null);
    isConnected.add(false);
    connectedDevices.add([]);
  }
}
