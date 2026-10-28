part of 'library_items_cubit.dart';

sealed class LibraryItemsState extends Equatable {
  final List<PlaylistItemProperties> playlists;

  const LibraryItemsState({this.playlists = const []});

  @override
  List<Object?> get props => [playlists];

  LibraryItemsState copyWith({List<PlaylistItemProperties>? playlists}) {
    return LibraryItemsLoaded(
      playlists: playlists ?? this.playlists,
    );
  }
}

/// Library is being loaded for the first time.
final class LibraryItemsLoading extends LibraryItemsState {}

/// Data successfully loaded.
final class LibraryItemsLoaded extends LibraryItemsState {
  const LibraryItemsLoaded({required super.playlists});
}

/// Error during data fetch.
final class LibraryItemsError extends LibraryItemsState {
  final String message;
  const LibraryItemsError(this.message);

  @override
  List<Object?> get props => [message];
}

/// View-model for a single playlist row in the library list.
///
/// Uses domain [PlaylistType] — never DB types.
class PlaylistItemProperties extends Equatable {
  final String playlistName;
  final String storageKey;
  final String? coverImgUrl;
  final String? subTitle;
  final PlaylistType type;
  final bool isPinned;
  final int sortOrder;
  final int playlistId;

  const PlaylistItemProperties({
    required this.playlistName,
    required this.storageKey,
    this.coverImgUrl,
    this.subTitle,
    this.type = PlaylistType.userPlaylist,
    this.isPinned = false,
    this.sortOrder = 0,
    this.playlistId = 0,
  });

  Map<String, dynamic> toJson() => {
        'playlistName': playlistName,
        'storageKey': storageKey,
        'coverImgUrl': coverImgUrl,
        'subTitle': subTitle,
        'type': type.name,
        'isPinned': isPinned,
        'sortOrder': sortOrder,
        'playlistId': playlistId,
      };

  factory PlaylistItemProperties.fromJson(Map<String, dynamic> json) =>
      PlaylistItemProperties(
        playlistName: json['playlistName'] as String? ?? '',
        storageKey: json['storageKey'] as String? ?? '',
        coverImgUrl: json['coverImgUrl'] as String?,
        subTitle: json['subTitle'] as String?,
        type: PlaylistType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => PlaylistType.remotePlaylist,
        ),
        isPinned: json['isPinned'] as bool? ?? false,
        sortOrder: json['sortOrder'] as int? ?? 0,
        playlistId: json['playlistId'] as int? ?? 0,
      );

  @override
  List<Object?> get props => [
        playlistName,
        storageKey,
        coverImgUrl,
        subTitle,
        type,
        isPinned,
        sortOrder,
        playlistId
      ];
}
