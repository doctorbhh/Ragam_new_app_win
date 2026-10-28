import 'package:Bloomee/blocs/history/cubit/history_cubit.dart';
import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/storage_setting.dart';
import 'package:Bloomee/screens/widgets/more_bottom_sheet.dart';
import 'package:Bloomee/screens/widgets/sign_board_widget.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/screens/widgets/song_tile.dart';
import 'package:flutter/material.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:icons_plus/icons_plus.dart';

class HistoryView extends StatelessWidget {
  const HistoryView({super.key});

  void _confirmClearHistory(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Default_Theme.themeColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(MingCute.delete_2_line, color: Color(0xFFFF4D6A), size: 22),
            SizedBox(width: 8),
            Text(
              'Clear History',
              style: TextStyle(
                color: Default_Theme.primaryColor1,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to clear your playback history?\n\nYour cached songs and downloads will not be affected.',
          style: TextStyle(
            color: Default_Theme.primaryColor2.withValues(alpha: 0.85),
            fontSize: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Default_Theme.primaryColor2.withValues(alpha: 0.7),
              ),
            ),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogCtx);
              await context.read<HistoryCubit>().clearHistory();
              SnackbarService.showMessage('Playback history cleared');
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF4D6A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          actions: [
            BlocBuilder<HistoryCubit, HistoryState>(
              builder: (context, state) {
                if (state.tracks.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  tooltip: 'Clear History',
                  icon: const Icon(
                    MingCute.delete_2_line,
                    color: Default_Theme.primaryColor1,
                  ),
                  onPressed: () => _confirmClearHistory(context),
                );
              },
            ),
            IconButton(
              icon: const Icon(
                MingCute.settings_1_line,
                color: Default_Theme.primaryColor1,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const BackupSettings(),
                  ),
                );
              },
            ),
          ],
          title: Text(
            l10n.recentsTitle,
            style: const TextStyle(
                    color: Default_Theme.primaryColor1,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)
                .merge(Default_Theme.secondoryTextStyle),
          ),
        ),
        body: BlocBuilder<HistoryCubit, HistoryState>(
          builder: (context, state) {
            if (state is HistoryInitial) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }
            if (state.tracks.isEmpty) {
              return const Center(
                child: SignBoardWidget(
                  message: 'No recently played tracks',
                  icon: MingCute.history_line,
                ),
              );
            }
            return ListView.builder(
              itemCount: state.tracks.length,
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              itemBuilder: (context, index) {
                return SongCardWidget(
                  song: state.tracks[index],
                  onTap: () {
                    context
                        .read<BloomeePlayerCubit>()
                        .bloomeePlayer
                        .loadPlaylist(
                            Playlist(tracks: state.tracks, title: 'History'),
                            idx: index,
                            doPlay: true);
                  },
                  onOptionsTap: () =>
                      showMoreBottomSheet(context, state.tracks[index]),
                );
              },
            );
          },
        ),
      ),
    );
  }

  ListTile settingListTile(
      {required String title,
      required String subtitle,
      required IconData icon,
      VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(
        icon,
        size: 30,
        color: Default_Theme.primaryColor1,
      ),
      title: Text(
        title,
        style: const TextStyle(color: Default_Theme.primaryColor1, fontSize: 17)
            .merge(Default_Theme.secondoryTextStyleMedium),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
                color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                fontSize: 12.5)
            .merge(Default_Theme.secondoryTextStyleMedium),
      ),
      onTap: () {
        if (onTap != null) {
          onTap();
        }
      },
    );
  }
}
