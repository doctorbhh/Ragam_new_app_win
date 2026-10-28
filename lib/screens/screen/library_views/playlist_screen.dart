import 'dart:ui';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:icons_plus/icons_plus.dart';

import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/screens/screen/library_views/cubit/current_playlist_cubit.dart';
import 'package:Bloomee/screens/screen/library_views/more_opts_sheet.dart';
import 'package:Bloomee/blocs/downloader/cubit/downloader_cubit.dart';
import 'package:Bloomee/screens/widgets/more_bottom_sheet.dart';
import 'package:Bloomee/screens/widgets/animated_list_item.dart';
import 'package:Bloomee/screens/widgets/sign_board_widget.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/screens/widgets/song_tile.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/services/song_cache_service.dart';
import 'package:Bloomee/utils/load_image.dart';
import 'package:Bloomee/l10n/app_localizations.dart';

part 'playlist_info_dialog.dart';

class PlaylistView extends StatefulWidget {
  final String? initialPlaylistName;

  const PlaylistView({super.key, this.initialPlaylistName});

  @override
  State<PlaylistView> createState() => _PlaylistViewState();
}

class _PlaylistViewState extends State<PlaylistView> {
  late final ScrollController _scrollController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  bool _didTriggerInitialLoad = false;
  String? _targetPlaylistName;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    _searchFocusNode.addListener(() {
      if (mounted) setState(() {});
    });

    if (widget.initialPlaylistName != null &&
        widget.initialPlaylistName!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startInitialLoad(widget.initialPlaylistName!);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didTriggerInitialLoad) return;

    final playlistName = _targetPlaylistName ??
        widget.initialPlaylistName ??
        context.read<CurrentPlaylistCubit>().currentPlaylistName;
    if (playlistName == null || playlistName.trim().isEmpty) return;

    _didTriggerInitialLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialLoad(playlistName);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildSearchBar() {
    return Container(
      height: 46,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _searchFocusNode.hasFocus
              ? Default_Theme.accentColor2.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.08),
          width: 1.2,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(
            MingCute.search_line,
            size: 20,
            color: Colors.white.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: 'Search songs in this playlist...',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val;
                });
              },
            ),
          ),
          if (_searchQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                setState(() {
                  _searchQuery = '';
                });
              },
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 500) {
      context.read<CurrentPlaylistCubit>().loadMoreTracks();
    }
  }

  Future<void> _startInitialLoad(String playlistName) async {
    if (!mounted) return;
    _targetPlaylistName = playlistName;
    final cubit = context.read<CurrentPlaylistCubit>();

    await cubit.openPlaylist(playlistName, deferFirstPage: true);
    if (!mounted) return;

    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    await cubit.loadMoreTracks();
  }

  Future<void> _playFromPlaylist(
      BuildContext context, CurrentPlaylistState state,
      {int? index, List<Track>? customTracks, bool shuffle = false}) async {
    final fullPlaylist =
        await context.read<CurrentPlaylistCubit>().ensureAllTracksLoaded();
    if (!mounted) return;

    final tracksToPlay = customTracks ?? fullPlaylist.tracks;
    if (tracksToPlay.isEmpty) return;

    context.read<BloomeePlayerCubit>().bloomeePlayer.loadPlaylist(
          Playlist(tracks: tracksToPlay, title: fullPlaylist.title),
          idx: index ?? 0,
          doPlay: true,
          shuffling: shuffle,
        );
  }

  List<Color> _getOptimizedPalette(BuildContext context) {
    final pallete =
        context.read<CurrentPlaylistCubit>().getCurrentPlaylistPallete();
    Color fgColor = pallete?.lightVibrantColor?.color ?? Colors.white;
    Color bgColor = pallete?.dominantColor?.color ??
        pallete?.darkMutedColor?.color ??
        Default_Theme.themeColor;

    if (bgColor.computeLuminance() / fgColor.computeLuminance() > 0.05) {
      fgColor = HSLColor.fromColor(fgColor)
          .withLightness(
              (HSLColor.fromColor(fgColor).lightness + 0.1).clamp(0.0, 1.0))
          .toColor();
      bgColor = HSLColor.fromColor(bgColor)
          .withLightness(
              (HSLColor.fromColor(bgColor).lightness - 0.1).clamp(0.0, 1.0))
          .toColor();
    }
    return [fgColor, bgColor];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      body: BlocBuilder<CurrentPlaylistCubit, CurrentPlaylistState>(
        builder: (context, state) {
          final waitingForTarget = _targetPlaylistName != null &&
              state.playlist.title != _targetPlaylistName;

          if (waitingForTarget ||
              state.status == CurrentPlaylistLoadStatus.initial ||
              state.status == CurrentPlaylistLoadStatus.loading) {
            return const Center(
                child: CircularProgressIndicator(
                    color: Default_Theme.accentColor2));
          }

          if (state.status == CurrentPlaylistLoadStatus.error) {
            return Center(
                child: SignBoardWidget(
                    message: state.errorMessage ?? 'Failed to load playlist',
                    icon: MingCute.alert_line));
          }

          final colors = _getOptimizedPalette(context);
          final fgColor = colors[0];
          final bgColor = colors[1];
          final tracks = state.playlist.tracks;
          final imageUrl = tracks.isNotEmpty
              ? (tracks.first.thumbnail.urlHigh ?? tracks.first.thumbnail.url)
              : '';

          return LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 850;
              return Stack(
                fit: StackFit.expand,
                children: [
                  _buildAmbientBackground(imageUrl, bgColor, isMobile),
                  if (isMobile)
                    _buildMobileLayout(
                        state, fgColor, bgColor, imageUrl, l10n, constraints)
                  else
                    _buildDesktopLayout(
                        state, fgColor, bgColor, imageUrl, l10n, constraints),
                ],
              );
            },
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      leadingWidth: 70,
      leading: Padding(
        padding: const EdgeInsets.only(left: 16.0),
        child: Center(
          child: IconButton(
            icon: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: Colors.white, size: 20),
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16.0),
          child: Center(
            child: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: const Icon(MingCute.search_line,
                    color: Colors.white, size: 20),
              ),
              tooltip: 'Search in playlist',
              onPressed: () => _searchFocusNode.requestFocus(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAmbientBackground(
      String imageUrl, Color dominantColor, bool isMobile) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Default_Theme.themeColor),
            Positioned(
              top: isMobile ? -100 : -200,
              left: isMobile ? -50 : -200,
              width: 800,
              height: 800,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      dominantColor.withValues(alpha: 0.45),
                      Colors.transparent
                    ],
                  ),
                ),
              ),
            ),
            if (imageUrl.isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.35,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
                    child:
                        LoadImageCached(imageUrl: imageUrl, fit: BoxFit.cover),
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Default_Theme.themeColor.withValues(alpha: 0.1),
                    Default_Theme.themeColor.withValues(alpha: 0.85),
                    Default_Theme.themeColor,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Pro-Desktop Layout (Perfectly Centered Left Panel) ───

  Widget _buildDesktopLayout(
      CurrentPlaylistState state,
      Color fgColor,
      Color bgColor,
      String imageUrl,
      AppLocalizations l10n,
      BoxConstraints constraints) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // FIXED LEFT PANEL: Centered content, elegant flex scaling
        SizedBox(
          width: math.max(340, constraints.maxWidth * 0.35),
          child: Padding(
            // Optically balanced padding so it sits perfectly in the center of its space
            padding: const EdgeInsets.fromLTRB(40, 90, 20, 40),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.center, // Centered alignment
              children: [
                const Spacer(flex: 1), // Top breathing room

                // Intelligently scaling cover art
                Flexible(
                  flex: 10,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: _buildIntelligentCover(imageUrl, bgColor),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Meta Info (Centered)
                _buildInfo(state, l10n, isCentered: true),

                const SizedBox(height: 24),

                // Single-Line Forced Actions (Centered)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child:
                      _buildActions(state, fgColor, bgColor, isCentered: true),
                ),

                const Spacer(flex: 2), // Bottom breathing room
              ],
            ),
          ),
        ),

        // SCROLLABLE RIGHT PANEL: The track list
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(
                20, 90, 40, 40), // Matches left panel gap
            decoration: BoxDecoration(
              color: Default_Theme.themeColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 40,
                    offset: const Offset(0, 15)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: CustomScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                slivers: [
                  if (state.playlist.tracks.isEmpty && !state.isLoadingMore)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                          child: SignBoardWidget(
                              message: l10n.playlistEmptyState,
                              icon: MingCute.playlist_line)),
                    )
                  else ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                        child: _buildSearchBar(),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 16),
                      sliver: _buildTrackList(state),
                    ),
                  ],
                  if (state.isLoadingMore || state.hasMore)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: Default_Theme.accentColor2)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Mobile Layout (Scrolling Canvas) ───

  Widget _buildMobileLayout(
      CurrentPlaylistState state,
      Color fgColor,
      Color bgColor,
      String imageUrl,
      AppLocalizations l10n,
      BoxConstraints constraints) {
    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 100, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: constraints.maxWidth * 0.65,
                  height: constraints.maxWidth * 0.65,
                  child: _buildIntelligentCover(imageUrl, bgColor),
                ),
                const SizedBox(height: 32),
                _buildInfo(state, l10n, isCentered: true),
                const SizedBox(height: 28),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child:
                      _buildActions(state, fgColor, bgColor, isCentered: true),
                ),
              ],
            ),
          ),
        ),
        if (state.playlist.tracks.isEmpty && !state.isLoadingMore)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
                child: SignBoardWidget(
                    message: l10n.playlistEmptyState,
                    icon: MingCute.playlist_line)),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: _buildSearchBar(),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: state.isLoadingMore ? 0 : 120),
            sliver: _buildTrackList(state),
          ),
        ],
        if (state.isLoadingMore || state.hasMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                  child: CircularProgressIndicator(
                      color: Default_Theme.accentColor2)),
            ),
          ),
      ],
    );
  }

  Widget _buildIntelligentCover(String imageUrl, Color dominantColor) {
    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.black.withValues(alpha: 0.2),
          boxShadow: [
            BoxShadow(
                color: dominantColor.withValues(alpha: 0.35),
                blurRadius: 60,
                offset: const Offset(0, 20)),
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 10)),
            BoxShadow(
                color: Colors.white.withValues(alpha: 0.1),
                blurRadius: 1,
                offset: const Offset(0, -1)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: imageUrl.isEmpty
              ? FractionallySizedBox(
                  widthFactor: 0.3,
                  heightFactor: 0.3,
                  child: Icon(MingCute.music_2_line,
                      color: Colors.white.withValues(alpha: 0.3)),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                      child: LoadImageCached(
                          imageUrl: imageUrl, fit: BoxFit.cover),
                    ),
                    Container(color: Colors.black.withValues(alpha: 0.3)),
                    LoadImageCached(imageUrl: imageUrl, fit: BoxFit.contain),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildInfo(CurrentPlaylistState state, AppLocalizations l10n,
      {required bool isCentered}) {
    final creatorText = l10n.playlistByCreator(
        state.playlist.artists?.map((a) => a.name).join(', ') ??
            l10n.playlistYou);

    return Column(
      crossAxisAlignment:
          isCentered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          state.playlist.title,
          textAlign: isCentered ? TextAlign.center : TextAlign.left,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.95),
            fontSize: 36,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.0,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.playlistSongCount(state.totalTracks),
          textAlign: isCentered ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          creatorText,
          textAlign: isCentered ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildActions(CurrentPlaylistState state, Color fgColor, Color bgColor,
      {required bool isCentered}) {
    final isEmpty = state.playlist.tracks.isEmpty;
    final l10n = AppLocalizations.of(context)!;
    final query = _searchQuery.trim().toLowerCase();
    final filteredTracks = query.isEmpty
        ? state.playlist.tracks
        : state.playlist.tracks.where((t) {
            final title = t.title.toLowerCase();
            final artist =
                t.artists.map((a) => a.name.toLowerCase()).join(' ');
            final album = (t.album?.title ?? '').toLowerCase();
            return title.contains(query) ||
                artist.contains(query) ||
                album.contains(query);
          }).toList();
    final canPlay = !isEmpty && (query.isEmpty || filteredTracks.isNotEmpty);

    return RepaintBoundary(
      child: Wrap(
        alignment: isCentered ? WrapAlignment.center : WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 12,
        children: [
          StreamBuilder<String>(
              stream:
                  context.watch<BloomeePlayerCubit>().bloomeePlayer.queueTitle,
              builder: (context, snapshot) {
                final isCurrent =
                    snapshot.hasData && snapshot.data == state.playlist.title;
                return StreamBuilder<bool>(
                    stream: context
                        .read<BloomeePlayerCubit>()
                        .bloomeePlayer
                        .engine
                        .playingStream,
                    builder: (context, playingSnapshot) {
                      final isPlaying =
                          isCurrent && (playingSnapshot.data ?? false);
                      return _PremiumPlayButton(
                        isEmpty: !canPlay,
                        isPlaying: isPlaying,
                        onTap: () {
                          if (isCurrent && query.isEmpty) {
                            if (isPlaying) {
                              context
                                  .read<BloomeePlayerCubit>()
                                  .bloomeePlayer
                                  .pause();
                            } else {
                              context
                                  .read<BloomeePlayerCubit>()
                                  .bloomeePlayer
                                  .play();
                            }
                          } else {
                            _playFromPlaylist(
                              context,
                              state,
                              customTracks:
                                  query.isNotEmpty ? filteredTracks : null,
                            );
                          }
                        },
                      );
                    });
              }),

          _PremiumShuffleButton(
            isEmpty: !canPlay,
            onTap: () => _playFromPlaylist(
              context,
              state,
              customTracks: query.isNotEmpty ? filteredTracks : null,
              shuffle: true,
            ),
          ),

          Builder(builder: (ctx) {
            final downloaded = ctx.watch<DownloaderCubit>().state.downloaded;
            final allDownloaded = !isEmpty &&
                state.playlist.tracks
                    .every((s) => downloaded.any((d) => d.id == s.id));

            if (allDownloaded) {
              return Tooltip(
                message: l10n.playlistAvailableOffline,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          Default_Theme.accentColor2.withValues(alpha: 0.15)),
                  child: const Icon(Icons.offline_pin_rounded,
                      color: Default_Theme.accentColor2, size: 20),
                ),
              );
            }
            return _buildActionIcon(
                MingCute.download_2_fill,
                l10n.buttonDownload,
                isEmpty ? null : () => _handleDownload(context, state, l10n));
          }),

          _PlaylistAutoCacheButton(playlistName: state.playlist.title),

          _buildActionIcon(
              MingCute.information_line,
              l10n.buttonInfo,
              () => showPlaylistInfo(context, state,
                  fgColor: fgColor, bgColor: bgColor)),

          _buildActionIcon(MingCute.more_2_line, l10n.buttonMore,
              () => showPlaylistOptsInrSheet(context, state.playlist)),
        ],
      ),
    );
  }

  Widget _buildActionIcon(IconData icon, String tooltip, VoidCallback? onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          splashColor: Colors.white.withValues(alpha: 0.1),
          highlightColor: Colors.white.withValues(alpha: 0.05),
          child: Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Icon(icon,
                color: Colors.white.withValues(alpha: 0.85), size: 20),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackList(CurrentPlaylistState state) {
    final query = _searchQuery.trim().toLowerCase();
    final allTracks = state.playlist.tracks;
    final tracks = query.isEmpty
        ? allTracks
        : allTracks.where((t) {
            final title = t.title.toLowerCase();
            final artist =
                t.artists.map((a) => a.name.toLowerCase()).join(' ');
            final album = (t.album?.title ?? '').toLowerCase();
            return title.contains(query) ||
                artist.contains(query) ||
                album.contains(query);
          }).toList();

    if (query.isNotEmpty && tracks.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: SignBoardWidget(
              message: 'No matching songs found',
              icon: MingCute.search_line,
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = tracks[index];
          return AnimatedListItem(
            index: index,
            child: SongCardWidget(
              index: index + 1,
              key: ValueKey(track.id),
              song: track,
              onTap: () {
                if (query.isEmpty) {
                  _playFromPlaylist(context, state, index: index);
                } else {
                  _playFromPlaylist(context, state,
                      customTracks: tracks, index: index);
                }
              },
              onOptionsTap: () => showMoreBottomSheet(
                context,
                track,
                onDelete: () => _removeTrack(context, track),
                showDelete: true,
                showSinglePlay: true,
              ),
            ),
          );
        },
        childCount: tracks.length,
        addRepaintBoundaries: true,
      ),
    );
  }

  void _removeTrack(BuildContext context, Track track) {
    final cubit = context.read<CurrentPlaylistCubit>();
    final l10n = AppLocalizations.of(context)!;
    cubit.removeTrack(track);
    SnackbarService.showMessage(
        l10n.playlistRemovedTrack(track.title, cubit.state.playlist.title));
  }

  Future<void> _handleDownload(BuildContext context, CurrentPlaylistState state,
      AppLocalizations l10n) async {
    final items =
        (await context.read<CurrentPlaylistCubit>().ensureAllTracksLoaded())
            .tracks;
    if (items.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Default_Theme.themeColor,
        title: Text(l10n.dialogDownloadPlaylist,
            style: const TextStyle(color: Colors.white)),
        content: Text(
            l10n.dialogDownloadPlaylistMessage(
                items.length, state.playlist.title),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.buttonCancel,
                  style:
                      TextStyle(color: Colors.white.withValues(alpha: 0.7)))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Default_Theme.accentColor2,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.dialogDownloadAll,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _showAddToDownloadProgress(context, items, l10n);
      SnackbarService.showMessage(l10n.snackbarSongsAddedToQueue(items.length));
    }
  }

  Future<void> _showAddToDownloadProgress(
      BuildContext context, List<Track> items, AppLocalizations l10n) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        int completed = 0;
        String currentTitle = '';
        void Function(void Function()) setStateRef = (_) {};

        WidgetsBinding.instance.addPostFrameCallback((_) async {
          for (final song in items) {
            setStateRef(() => currentTitle = song.title);
            try {
              context
                  .read<DownloaderCubit>()
                  .downloadSong(song, showSnackbar: false);
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 100));
            setStateRef(() => completed++);
          }
          if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
        });

        return StatefulBuilder(
          builder: (sbCtx, sbSetState) {
            setStateRef = sbSetState;
            return AlertDialog(
              backgroundColor: Default_Theme.themeColor,
              contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.dialogAddingToDownloadQueue,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('$completed/${items.length} items',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7))),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: items.isEmpty
                            ? 0
                            : (completed / items.length).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Default_Theme.accentColor2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(currentTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 12)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PremiumPlayButton extends StatelessWidget {
  final bool isEmpty;
  final bool isPlaying;
  final VoidCallback onTap;

  const _PremiumPlayButton({
    required this.isEmpty,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEmpty ? null : onTap,
        borderRadius: BorderRadius.circular(30),
        splashColor: Default_Theme.accentColor2.withValues(alpha: 0.2),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 26),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: Default_Theme.accentColor2.withValues(alpha: 0.15),
            border: Border.all(color: Default_Theme.accentColor2, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isPlaying ? MingCute.pause_fill : MingCute.play_fill,
                size: 20,
                color: Default_Theme.accentColor2,
              ),
              const SizedBox(width: 8),
              Text(
                isPlaying ? 'Pause' : 'Play',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Default_Theme.accentColor2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PremiumShuffleButton extends StatelessWidget {
  final bool isEmpty;
  final VoidCallback onTap;

  const _PremiumShuffleButton({required this.isEmpty, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEmpty ? null : onTap,
        borderRadius: BorderRadius.circular(30),
        splashColor: Colors.white.withValues(alpha: 0.15),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: Colors.white.withValues(alpha: 0.06),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.15), width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(MingCute.shuffle_line,
                  size: 20, color: Colors.white.withValues(alpha: 0.9)),
              const SizedBox(width: 8),
              Text(
                'Shuffle',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistAutoCacheButton extends StatefulWidget {
  final String playlistName;
  const _PlaylistAutoCacheButton({required this.playlistName});

  @override
  State<_PlaylistAutoCacheButton> createState() =>
      _PlaylistAutoCacheButtonState();
}

class _PlaylistAutoCacheButtonState extends State<_PlaylistAutoCacheButton> {
  bool _isAutoCacheEnabled = false;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _loadState();
    _sub = SongCacheService().onAutoCachePlaylistsChanged.listen((_) {
      if (mounted) _loadState();
    });
  }

  @override
  void didUpdateWidget(covariant _PlaylistAutoCacheButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistName != widget.playlistName) {
      _loadState();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadState() async {
    final enabled =
        await SongCacheService().isPlaylistAutoCacheEnabled(widget.playlistName);
    if (mounted) setState(() => _isAutoCacheEnabled = enabled);
  }

  Future<void> _toggle() async {
    HapticFeedback.lightImpact();
    final next = !_isAutoCacheEnabled;
    await SongCacheService().setPlaylistAutoCache(widget.playlistName, next);
    if (!mounted) return;
    setState(() => _isAutoCacheEnabled = next);
    SnackbarService.showMessage(
      next
          ? 'Auto-cache enabled for "${widget.playlistName}". Songs played will be cached even if global cache is off.'
          : 'Auto-cache disabled for "${widget.playlistName}".',
    );
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = _isAutoCacheEnabled
        ? 'Auto-cache on play: Active (caches even when global cache is off)'
        : 'Enable auto-cache on play';

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(22),
          splashColor: Default_Theme.accentColor2.withValues(alpha: 0.2),
          highlightColor: Default_Theme.accentColor2.withValues(alpha: 0.1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isAutoCacheEnabled
                  ? Default_Theme.accentColor2.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.04),
              border: Border.all(
                color: _isAutoCacheEnabled
                    ? Default_Theme.accentColor2
                    : Colors.white.withValues(alpha: 0.08),
                width: _isAutoCacheEnabled ? 1.5 : 1.0,
              ),
              boxShadow: _isAutoCacheEnabled
                  ? [
                      BoxShadow(
                        color:
                            Default_Theme.accentColor2.withValues(alpha: 0.25),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: Icon(
              _isAutoCacheEnabled
                  ? Icons.cached_rounded
                  : Icons.cached_outlined,
              color: _isAutoCacheEnabled
                  ? Default_Theme.accentColor2
                  : Colors.white.withValues(alpha: 0.85),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
