import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/sync_settings.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/sync/ragam_sync_service.dart';
import 'package:Bloomee/services/sync/sync_models.dart';

void showSyncConnectBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const SyncConnectBottomSheet(),
  );
}

class SyncConnectBottomSheet extends StatefulWidget {
  const SyncConnectBottomSheet({super.key});

  @override
  State<SyncConnectBottomSheet> createState() => _SyncConnectBottomSheetState();
}

class _SyncConnectBottomSheetState extends State<SyncConnectBottomSheet> {
  final TextEditingController _codeController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _codeController.dispose();
    if (RagamSyncService.instance.joinStatus.value == SyncJoinStatus.waitingForApproval ||
        RagamSyncService.instance.joinStatus.value == SyncJoinStatus.checkingRoom) {
      RagamSyncService.instance.cancelJoinRequest();
    }
    super.dispose();
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.phone_android_rounded;
      case 'windows':
        return Icons.laptop_windows_rounded;
      case 'macos':
      case 'ios':
        return Icons.apple_rounded;
      case 'linux':
        return Icons.terminal_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  Future<void> _shareRoomCode(String roomId) async {
    final inviteMessage =
        'Join my Ragam music party room!\nRoom Code: $roomId\nListen to songs together in real-time!';
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: inviteMessage,
          subject: 'Ragam Music Party Room Invite',
        ),
      );
    } catch (e) {
      Clipboard.setData(ClipboardData(text: roomId));
      SnackbarService.showMessage('Room code copied: $roomId');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = RagamSyncService.instance;

    return StreamBuilder<SyncRoomState?>(
      stream: sync.roomState,
      builder: (context, snapshot) {
        final room = snapshot.data;
        final isInRoom = sync.isInRoom || room != null;

        return Container(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            top: 16,
            left: 20,
            right: 20,
          ),
          decoration: BoxDecoration(
            color: Default_Theme.themeColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.1),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Sheet handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title and Settings Gear
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.purpleAccent, Default_Theme.accentColor1],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          MingCute.music_2_fill,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Listening Party Room',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Default_Theme.primaryColor1,
                            ),
                          ),
                          Text(
                            isInRoom
                                ? 'Active Room: ${room?.roomId ?? sync.currentRoomId ?? ''}'
                                : 'Listen to songs together in sync',
                            style: TextStyle(
                              fontSize: 12,
                              color: Default_Theme.primaryColor1.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(MingCute.settings_6_line,
                        color: Default_Theme.primaryColor1),
                    tooltip: 'Sync & Database Settings',
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SyncSettingsView()),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),

              if (isInRoom) ...[
                _buildActiveRoomView(room ??
                    SyncRoomState(
                      roomId: sync.currentRoomId ?? '',
                      hostDeviceId: '',
                      isHost: sync.isHost,
                      mode: sync.currentMode,
                      activePlayerId: '',
                      playback: SyncPlayback(
                        isPlaying: false,
                        positionMs: 0,
                        emittedAt: DateTime.now().millisecondsSinceEpoch,
                      ),
                      connectedDevices: sync.connectedDevices.value,
                    )),
              ] else ...[
                StreamBuilder<SyncJoinStatus>(
                  stream: sync.joinStatus,
                  builder: (context, statusSnap) {
                    final status = statusSnap.data ?? SyncJoinStatus.idle;
                    if (status == SyncJoinStatus.checkingRoom) {
                      return _buildCheckingRoomView();
                    } else if (status == SyncJoinStatus.waitingForApproval) {
                      return _buildWaitingForApprovalView();
                    }
                    return _buildCreateOrJoinView();
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildCreateOrJoinView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Party Room Info Banner
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.purpleAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.purpleAccent.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const Icon(MingCute.celebrate_fill, color: Colors.purpleAccent, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Listen to music simultaneously with friends! Play, pause, and skip in sync with automated drift compensation.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Create Room Button
        ElevatedButton.icon(
          onPressed: _isLoading ? null : _createPartyRoom,
          icon: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(MingCute.add_circle_fill, size: 20),
          label: const Text(
            'Create Party Room',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Default_Theme.accentColor1,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 18),

        // Divider
        Row(
          children: [
            Expanded(child: Divider(color: Default_Theme.primaryColor1.withValues(alpha: 0.15))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'OR ENTER ROOM CODE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
                ),
              ),
            ),
            Expanded(child: Divider(color: Default_Theme.primaryColor1.withValues(alpha: 0.15))),
          ],
        ),
        const SizedBox(height: 18),

        // Join Input
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                maxLength: 7,
                onSubmitted: (_) => _joinPartyRoom(),
                style: const TextStyle(
                  color: Default_Theme.primaryColor1,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: 'CODE e.g. RAG-842',
                  hintStyle: TextStyle(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.3),
                    letterSpacing: 1,
                  ),
                  filled: true,
                  fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: _isLoading ? null : _joinPartyRoom,
              style: ElevatedButton.styleFrom(
                backgroundColor: Default_Theme.primaryColor1.withValues(alpha: 0.12),
                foregroundColor: Default_Theme.primaryColor1,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Join Party', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActiveRoomView(SyncRoomState room) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Room Code Card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.purpleAccent.withValues(alpha: 0.18),
                Default_Theme.accentColor1.withValues(alpha: 0.12),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.purpleAccent.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PARTY ROOM CODE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: Default_Theme.primaryColor1.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    room.roomId,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                      color: Default_Theme.primaryColor1,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(MingCute.copy_2_line, color: Default_Theme.primaryColor1),
                    tooltip: 'Copy Code',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: room.roomId));
                      SnackbarService.showMessage('Room code copied: ${room.roomId}');
                    },
                  ),
                  IconButton(
                    icon: const Icon(MingCute.share_forward_line, color: Colors.purpleAccent),
                    tooltip: 'Share Invite',
                    onPressed: () => _shareRoomCode(room.roomId),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Prominent Share to Apps Button (WhatsApp, Telegram, etc.)
        ElevatedButton.icon(
          onPressed: () => _shareRoomCode(room.roomId),
          icon: const Icon(MingCute.share_forward_fill, size: 18),
          label: const Text(
            'Share Code (WhatsApp, Telegram...)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.purpleAccent.withValues(alpha: 0.18),
            foregroundColor: Colors.purpleAccent,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.purpleAccent.withValues(alpha: 0.4)),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Connected Listeners Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Connected Listeners (${room.connectedDevices.length})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Default_Theme.primaryColor1.withValues(alpha: 0.8),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '🎉 Jamming',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.purpleAccent,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Devices List
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: room.connectedDevices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final dev = room.connectedDevices[index];
              final isMe = dev.deviceId == RagamSyncService.instance.deviceId;

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _getPlatformIcon(dev.platform),
                      size: 18,
                      color: Colors.purpleAccent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        dev.deviceName + (isMe ? ' (You)' : ''),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                          color: Default_Theme.primaryColor1,
                        ),
                      ),
                    ),
                    if (dev.isHost)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'HOST',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.purpleAccent,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),

        // Leave Session Button
        OutlinedButton.icon(
          onPressed: () async {
            await RagamSyncService.instance.leaveRoom();
            if (mounted) setState(() {});
          },
          icon: const Icon(MingCute.exit_door_fill, size: 18),
          label: const Text('Leave Party', style: TextStyle(fontWeight: FontWeight.bold)),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.redAccent,
            side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.4)),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ],
    );
  }

  Future<void> _createPartyRoom() async {
    setState(() => _isLoading = true);
    try {
      final code = await RagamSyncService.instance.createRoom(mode: SyncMode.party);
      SnackbarService.showMessage('Created party room $code');
      // Prompt share immediately
      _shareRoomCode(code);
    } catch (e) {
      SnackbarService.showMessage('Failed to create party room: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildCheckingRoomView() {
    final code = _codeController.text.trim().toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Default_Theme.accentColor1,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Verifying Party Room',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Default_Theme.primaryColor1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            code.isNotEmpty
                ? 'Checking room $code and verifying host availability...'
                : 'Verifying room and checking host availability...',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Default_Theme.primaryColor1.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingForApprovalView() {
    final code = _codeController.text.trim().toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.purpleAccent.withValues(alpha: 0.15),
            Default_Theme.accentColor1.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.purpleAccent.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.purpleAccent.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_person_rounded,
              color: Colors.purpleAccent,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Waiting for Host Approval',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Default_Theme.primaryColor1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Knocked on room $code!\nThe host must approve your request before you can join.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: Default_Theme.primaryColor1.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.purpleAccent),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Approval prompt sent to host...',
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () {
              RagamSyncService.instance.cancelJoinRequest();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.close_rounded, size: 16),
            label: const Text(
              'Cancel Request',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _joinPartyRoom() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      SnackbarService.showMessage('Please enter a room code');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final success = await RagamSyncService.instance.joinRoom(code, mode: SyncMode.party);
      if (success) {
        SnackbarService.showMessage('Approved! Joined party room ${RagamSyncService.instance.normalizeRoomCode(code)}');
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    } on SyncJoinException catch (e) {
      SnackbarService.showMessage(e.message);
    } catch (e) {
      SnackbarService.showMessage('Failed to join room: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
