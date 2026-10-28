import 'dart:developer';
import 'dart:async';
import 'dart:io';

import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:Bloomee/blocs/downloader/cubit/downloader_cubit.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/screens/widgets/downloading_item.dart';
import 'package:Bloomee/screens/widgets/more_bottom_sheet.dart';
import 'package:Bloomee/screens/widgets/sign_board_widget.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/screens/widgets/song_tile.dart';
import 'package:flutter/material.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:Bloomee/services/song_cache_service.dart';
import 'package:Bloomee/services/db/dao/download_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';

class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  bool _isSearch = false;
  final TextEditingController _searchController = TextEditingController();
  List<Track> _filteredSongs = [];
  List<Track> _cachedSongs = [];
  int _cachedSizeBytes = 0;
  int _downloadedSizeBytes = 0;
  StreamSubscription? _cacheSub;

  List<Track> get _allOfflineSongs {
    final downloaderState = context.read<DownloaderCubit>().state;
    final downloaded = downloaderState.downloaded;
    final Map<String, Track> uniqueTracks = {};
    // Newly cached songs appear at the top of the list
    for (final t in _cachedSongs) {
      uniqueTracks[t.id] = t;
    }
    for (final t in downloaded) {
      if (!uniqueTracks.containsKey(t.id)) {
        uniqueTracks[t.id] = t;
      }
    }
    return uniqueTracks.values.toList();
  }

  @override
  void initState() {
    super.initState();
    _filteredSongs = _allOfflineSongs;
    _searchController.addListener(_filterSongs);
    _loadCachedSongs();
    _cacheSub = SongCacheService().onCacheUpdated.listen((_) {
      if (mounted) {
        _loadCachedSongs();
      }
    });
  }

  Future<void> _loadCachedSongs() async {
    try {
      final cachedIds = await SongCacheService().getCachedTrackIds();
      final tracks = <Track>[];
      for (final id in cachedIds) {
        final track = await SongCacheService().getCachedTrack(id);
        if (track != null) {
          tracks.add(track);
        }
      }
      final cacheBytes = await SongCacheService().getTotalCacheSizeBytes();

      int downBytes = 0;
      try {
        final downloadDao = DownloadDAO(
          DBProvider.db,
          TrackDAO(DBProvider.db),
          PlaylistDAO(DBProvider.db, TrackDAO(DBProvider.db)),
        );
        final validDownloads = await downloadDao.getValidDownloads();
        for (final d in validDownloads) {
          final file = File(d.filePath);
          if (file.existsSync()) {
            downBytes += file.lengthSync();
          }
        }
      } catch (e) {
        log('Failed to calculate download size: $e', name: 'OfflineScreen');
      }

      if (mounted) {
        setState(() {
          _cachedSongs = tracks;
          _cachedSizeBytes = cacheBytes;
          _downloadedSizeBytes = downBytes;
          if (!_isSearch && _searchController.text.isEmpty) {
            _filteredSongs = _allOfflineSongs;
          }
        });
      }
    } catch (e) {
      log('Failed to load cached songs: $e', name: 'OfflineScreen');
    }
  }

  @override
  void dispose() {
    _cacheSub?.cancel();
    _searchController.removeListener(_filterSongs);
    _searchController.dispose();
    super.dispose();
  }

  void _filterSongs() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredSongs = _allOfflineSongs
          .where((song) =>
              "${song.title.toLowerCase()} ${song.artists.map((a) => a.name).join(', ').toLowerCase()}"
                  .contains(query))
          .toList();
    });
  }

  void _toggleSearch() {
    setState(() {
      _isSearch = !_isSearch;
      // When closing the search, clear the controller and reset the filter
      if (!_isSearch) {
        _searchController.clear();
        _filteredSongs = _allOfflineSongs;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Scaffold(
        backgroundColor: Default_Theme.themeColor,
        body: BlocBuilder<DownloaderCubit, DownloaderState>(
          builder: (context, state) {
            if (_searchController.text.isEmpty) {
              _filteredSongs = _allOfflineSongs;
            }
            final allOffline = _allOfflineSongs;
            return RefreshIndicator(
              color: Default_Theme.accentColor2,
              backgroundColor: Default_Theme.themeColor,
              onRefresh: () async {
                await context.read<DownloaderCubit>().refreshDownloadedSongs();
                await _loadCachedSongs();
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics()),
                slivers: [
                  customDiscoverSliverBar(context, l10n),
                  if (state.downloads.isEmpty && allOffline.isEmpty)
                    SliverFillRemaining(
                      child: Center(
                        child: SignBoardWidget(
                          message: l10n.offlineNoDownloads,
                          icon: FontAwesome.download_solid,
                        ),
                      ),
                    )
                  else ...[
                    if (!_isSearch && allOffline.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16.0, vertical: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Cache & Disk Size Stats Card
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Default_Theme.primaryColor1
                                      .withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Default_Theme.primaryColor1
                                        .withValues(alpha: 0.1),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Default_Theme.accentColor2
                                            .withValues(alpha: 0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        MingCute.download_2_fill,
                                        color: Default_Theme.accentColor2,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${allOffline.length} Offline Tracks',
                                            style: const TextStyle(
                                              color: Default_Theme.primaryColor1,
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${_cachedSongs.length} cached (${SongCacheService.formatBytes(_cachedSizeBytes)})'
                                            '${state.downloaded.isNotEmpty ? " • ${state.downloaded.length} downloaded (${SongCacheService.formatBytes(_downloadedSizeBytes)})" : " • Total: ${SongCacheService.formatBytes(_cachedSizeBytes + _downloadedSizeBytes)}"}',
                                            style: TextStyle(
                                              color: Default_Theme.primaryColor2
                                                  .withValues(alpha: 0.7),
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Action buttons: Shuffle & Play, Play All
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () {
                                        if (allOffline.isEmpty) return;
                                        context
                                            .read<BloomeePlayerCubit>()
                                            .bloomeePlayer
                                            .loadPlaylist(
                                              Playlist(
                                                tracks: allOffline,
                                                title: "Offline",
                                              ),
                                              shuffling: true,
                                              doPlay: true,
                                            );
                                      },
                                      icon: const Icon(MingCute.shuffle_line,
                                          size: 18),
                                      label: const Text(
                                        'Shuffle & Play',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13),
                                      ),
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            Default_Theme.accentColor2,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 11),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        if (allOffline.isEmpty) return;
                                        context
                                            .read<BloomeePlayerCubit>()
                                            .bloomeePlayer
                                            .loadPlaylist(
                                              Playlist(
                                                tracks: allOffline,
                                                title: "Offline",
                                              ),
                                              idx: 0,
                                              doPlay: true,
                                            );
                                      },
                                      icon: const Icon(MingCute.play_fill,
                                          size: 18),
                                      label: const Text(
                                        'Play All',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            Default_Theme.primaryColor1,
                                        side: BorderSide(
                                          color: Default_Theme.primaryColor1
                                              .withValues(alpha: 0.25),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 11),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                    SliverList(
                      delegate: SliverChildListDelegate(
                        [
                          ...state.downloads.map((download) =>
                              DownloadingCardWidget(
                                  downloadProgress: download)),
                          ..._filteredSongs.asMap().entries.map((entry) {
                            final index = entry.key + 1;
                            final song = entry.value;
                            return SongCardWidget(
                              index: index,
                              song: song,
                              showOptions: true,
                              delDownBtn: true,
                              onDelDownTap: () async {
                                final isPlaying = context.read<BloomeePlayerCubit>().bloomeePlayer.currentMedia.id == song.id;
                                if (isPlaying) {
                                  SnackbarService.showMessage(l10n.snackbarCannotDeletePlayingSong);
                                  return;
                                }
                                
                                bool deleted = false;
                                
                                // Remove from downloads if present
                                if (state.downloaded.any((t) => t.id == song.id)) {
                                  context.read<DownloaderCubit>().removeDownload(song);
                                  deleted = true;
                                }
                                
                                // Remove from cache if present
                                if (_cachedSongs.any((t) => t.id == song.id)) {
                                  await SongCacheService().deleteCache(song.id);
                                  deleted = true;
                                }
                                
                                if (deleted) {
                                  SnackbarService.showMessage(l10n.snackbarDeletedTrack(song.title));
                                  _loadCachedSongs();
                                }
                              },
                              onTap: () {
                                final selectedIndex =
                                    allOffline.indexWhere(
                                  (item) => item.id == song.id,
                                );

                                if (selectedIndex < 0 ||
                                    allOffline.isEmpty) {
                                  SnackbarService.showMessage(
                                      l10n.offlineOpenFailed);
                                  log(
                                    'Offline play failed: missing track in downloaded list (${song.id})',
                                    name: 'OfflineScreen',
                                  );
                                  return;
                                }

                                try {
                                  context
                                      .read<BloomeePlayerCubit>()
                                      .bloomeePlayer
                                      .loadPlaylist(
                                        Playlist(
                                          tracks: allOffline,
                                          title: "Offline",
                                        ),
                                        idx: selectedIndex,
                                        doPlay: true,
                                      );
                                } catch (e, stack) {
                                  log(
                                    'Offline play crashed for ${song.id}',
                                    name: 'OfflineScreen',
                                    error: e,
                                    stackTrace: stack,
                                  );
                                  SnackbarService.showMessage(
                                      l10n.offlinePlayFailed);
                                }
                              },
                              onOptionsTap: () {
                                showMoreBottomSheet(context, song,
                                    showDelete: false);
                              },
                            );
                          }),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        ),
      ),
    );
  }

  SliverAppBar customDiscoverSliverBar(
      BuildContext context, AppLocalizations l10n) {
    return SliverAppBar(
      floating: true,
      pinned: true,
      surfaceTintColor: Default_Theme.themeColor,
      backgroundColor: Default_Theme.themeColor,
      title: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: (Widget child, Animation<double> animation) {
          final slideAnimation = Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOut,
          ));
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: slideAnimation,
              child: child,
            ),
          );
        },
        child: _isSearch ? _buildSearchField(l10n) : _buildTitle(l10n),
      ),
      actions: [
        !_isSearch
            ? Tooltip(
                message: l10n.offlineRefreshTooltip,
                child: IconButton(
                  icon: const Icon(MingCute.refresh_2_line),
                  onPressed: () {
                    context.read<DownloaderCubit>().refreshDownloadedSongs();
                    _loadCachedSongs();
                  },
                ),
              )
            : const SizedBox.shrink(),
        Tooltip(
          message:
              _isSearch ? l10n.offlineCloseSearch : l10n.offlineSearchTooltip,
          child: IconButton(
            icon: Icon(
              _isSearch ? Icons.close : Icons.search,
              color: Default_Theme.primaryColor1,
            ),
            onPressed: _toggleSearch,
          ),
        ),
      ],
    );
  }

  Widget _buildTitle(AppLocalizations l10n) {
    return Container(
      key: const ValueKey('title'),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l10n.offlineTitle,
              style: Default_Theme.primaryTextStyle.merge(const TextStyle(
                  fontSize: 34, color: Default_Theme.primaryColor1))),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildSearchField(AppLocalizations l10n) {
    return Container(
      key: const ValueKey('search'),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        cursorColor: Default_Theme.primaryColor1,
        decoration: InputDecoration(
          hintText: l10n.offlineSearchHint,
          border: InputBorder.none,
          hintStyle: TextStyle(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.7)),
        ),
        style: Default_Theme.secondoryTextStyle.merge(
          const TextStyle(
            color: Default_Theme.primaryColor1,
            fontSize: 15.0,
          ),
        ),
      ),
    );
  }
}
