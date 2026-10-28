import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/services/player/player_engine.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<int> generateRandomIndices(int length) {
  final indices = List<int>.generate(length, (i) => i);
  indices.shuffle();
  return indices;
}

/// Manages the playback queue (track list, ordering, shuffle, navigation).
///
/// Pure data structure — does NOT control the audio engine.
/// The [BloomeeMusicPlayer] reads [currentTrack] after calling navigation
/// methods and decides what to play.
class QueueManager {
  final BehaviorSubject<List<Track>> _queue = BehaviorSubject.seeded([]);
  final BehaviorSubject<bool> shuffleMode = BehaviorSubject.seeded(false);
  final BehaviorSubject<String> queueTitle = BehaviorSubject.seeded('Queue');

  int _currentIndex = 0;
  int _shuffleIndex = 0;
  List<int> _shuffleList = [];

  /// True while [restoreQueueState] is populating the queue from disk.
  /// [BloomeeMusicPlayer] checks this to skip the persistence listener
  /// and avoid writing back the exact same data we just read.
  bool _isRestoring = false;
  bool get isRestoring => _isRestoring;

  // ─── Getters ───────────────────────────────────────────────────────────────

  List<Track> get tracks => _queue.value;
  Stream<List<Track>> get tracksStream => _queue.stream;
  int get currentIndex => _currentIndex;
  int get length => _queue.value.length;
  bool get isEmpty => _queue.value.isEmpty;
  bool get isNotEmpty => _queue.value.isNotEmpty;

  Track? get currentTrack {
    if (_queue.value.isEmpty || _currentIndex >= _queue.value.length) {
      return null;
    }
    return _queue.value[_currentIndex];
  }

  bool hasNext({LoopMode loopMode = LoopMode.off}) {
    if (_queue.value.isEmpty) return false;
    if (loopMode == LoopMode.all) return true;
    if (shuffleMode.value) {
      return _shuffleList.isNotEmpty &&
          _shuffleIndex < (_shuffleList.length - 1);
    }
    return _currentIndex < (_queue.value.length - 1);
  }

  bool hasPrevious({LoopMode loopMode = LoopMode.off}) {
    if (_queue.value.isEmpty) return false;
    if (loopMode == LoopMode.all) return true;
    if (shuffleMode.value) {
      return _shuffleList.isNotEmpty && _shuffleIndex > 0;
    }
    return _currentIndex > 0;
  }

  /// Peek at the next track without advancing the index.
  Track? peekNext({LoopMode loopMode = LoopMode.off}) {
    if (_queue.value.isEmpty) return null;

    if (!shuffleMode.value) {
      if (_currentIndex < _queue.value.length - 1) {
        return _queue.value[_currentIndex + 1];
      } else if (loopMode == LoopMode.all) {
        return _queue.value[0];
      }
    } else {
      _ensureShuffleListValid();
      if (_shuffleIndex < _shuffleList.length - 1) {
        final nextIdx = _shuffleList[_shuffleIndex + 1];
        if (nextIdx < _queue.value.length) return _queue.value[nextIdx];
      } else if (loopMode == LoopMode.all && _shuffleList.isNotEmpty) {
        return _queue.value[_shuffleList[0]];
      }
    }
    return null;
  }

  // ─── Navigation ────────────────────────────────────────────────────────────

  /// Advance to the next track. Returns true if index changed.
  bool advanceToNext({LoopMode loopMode = LoopMode.off}) {
    if (_queue.value.isEmpty) return false;

    bool changed = false;
    if (!shuffleMode.value) {
      if (_currentIndex < _queue.value.length - 1) {
        _currentIndex++;
        changed = true;
      } else if (loopMode == LoopMode.all) {
        _currentIndex = 0;
        changed = true;
      }
    } else {
      _ensureShuffleListValid();
      if (_shuffleIndex < _shuffleList.length - 1) {
        _shuffleIndex++;
        _currentIndex =
            _shuffleList[_shuffleIndex].clamp(0, _queue.value.length - 1);
        changed = true;
      } else if (loopMode == LoopMode.all) {
        _shuffleIndex = 0;
        _currentIndex =
            _shuffleList[_shuffleIndex].clamp(0, _queue.value.length - 1);
        changed = true;
      }
    }
    if (changed && !_isRestoring) {
      unawaited(persistQueueState());
    }
    return changed;
  }

  /// Go back to the previous track. Returns true if index changed.
  bool advanceToPrevious({LoopMode loopMode = LoopMode.off}) {
    if (_queue.value.isEmpty) return false;

    bool changed = false;
    if (!shuffleMode.value) {
      if (_currentIndex > 0) {
        _currentIndex--;
        changed = true;
      } else if (loopMode == LoopMode.all) {
        _currentIndex = _queue.value.length - 1;
        changed = true;
      }
    } else {
      _ensureShuffleListValid();
      if (_shuffleIndex > 0) {
        _shuffleIndex--;
        _currentIndex =
            _shuffleList[_shuffleIndex].clamp(0, _queue.value.length - 1);
        changed = true;
      } else if (loopMode == LoopMode.all) {
        _shuffleIndex = _shuffleList.length - 1;
        _currentIndex =
            _shuffleList[_shuffleIndex].clamp(0, _queue.value.length - 1);
        changed = true;
      }
    }
    if (changed && !_isRestoring) {
      unawaited(persistQueueState());
    }
    return changed;
  }

  /// Jump directly to a queue index.
  void jumpTo(int index) {
    if (index < 0 || index >= _queue.value.length) {
      log('jumpTo: index $index out of bounds (len: ${_queue.value.length})',
          name: 'QueueManager');
      return;
    }
    _currentIndex = index;
    if (shuffleMode.value && _shuffleList.isNotEmpty) {
      _shuffleIndex = _shuffleList.indexOf(index);
      if (_shuffleIndex == -1) _shuffleIndex = 0;
    }
    if (!_isRestoring) {
      unawaited(persistQueueState());
    }
  }

  // ─── Queue Mutations ──────────────────────────────────────────────────────

  /// Replace the queue with a new playlist.
  void loadTracks(
    List<Track> tracks, {
    String playlistName = 'Queue',
    int idx = 0,
    bool shuffling = false,
  }) {
    // Deduplicate by ID, preserving order. We track whether the requested
    // start index needs to be remapped after deduplication.
    final seenIds = <String>{};
    Track? requestedTrack;
    if (idx >= 0 && idx < tracks.length) {
      requestedTrack = tracks[idx];
    }
    final deduped =
        tracks.where((t) => seenIds.add(t.id)).toList(growable: false);

    // Remap idx to the deduplicated list so the right song still starts.
    int remappedIdx = 0;
    if (requestedTrack != null) {
      final pos = deduped.indexWhere((t) => t.id == requestedTrack!.id);
      remappedIdx = pos != -1 ? pos : 0;
    }

    _queue.add(deduped);
    queueTitle.add(playlistName);

    final shouldShuffle = shuffling || shuffleMode.value;
    shuffleMode.add(shouldShuffle);

    if (shouldShuffle && deduped.isNotEmpty) {
      _shuffleList = generateRandomIndices(deduped.length);
      if (shuffling) {
        _shuffleIndex = 0;
        _currentIndex = _shuffleList[0];
      } else {
        _shuffleIndex = _shuffleList.indexOf(remappedIdx);
        if (_shuffleIndex == -1) _shuffleIndex = 0;
        _currentIndex = remappedIdx;
      }
    } else {
      _shuffleList = [];
      _shuffleIndex = 0;
      _currentIndex =
          remappedIdx.clamp(0, deduped.isEmpty ? 0 : deduped.length - 1);
    }
  }

  /// Toggle shuffle mode.
  void shuffle(bool enabled) {
    shuffleMode.add(enabled);
    if (enabled && _queue.value.isNotEmpty) {
      _shuffleList = generateRandomIndices(_queue.value.length);
      // Put current track at shuffle index 0.
      final pos = _shuffleList.indexOf(_currentIndex);
      if (pos != -1 && pos != 0) {
        _shuffleList.removeAt(pos);
        _shuffleList.insert(0, _currentIndex);
      }
      _shuffleIndex = 0;
    }
  }

  /// Add a track to the end of the queue. Skips duplicates (by id).
  void addTrack(Track track) {
    if (_queue.value.any((t) => t.id == track.id)) return;
    queueTitle.add('Queue');
    final newQueue = List<Track>.from(_queue.value)..add(track);
    final newIdx = newQueue.length - 1;
    _queue.add(newQueue);
    if (shuffleMode.value && _shuffleList.isNotEmpty) {
      _shuffleList.add(newIdx);
    }
  }

  /// Add multiple tracks to the queue.
  void addTracks(List<Track> tracks, {bool atLast = false}) {
    if (atLast) {
      final existingIds = _queue.value.map((t) => t.id).toSet();
      final deduplicated =
          tracks.where((t) => existingIds.add(t.id)).toList(growable: false);
      if (deduplicated.isEmpty) return;
      final startIdx = _queue.value.length;
      final newQueue = List<Track>.from(_queue.value)..addAll(deduplicated);
      _queue.add(newQueue);
      // Append new indices to the shuffle list so the existing shuffle order
      // is preserved. Without this, _ensureShuffleListValid would regenerate
      // the entire order, causing unpredictable jumps.
      if (shuffleMode.value && _shuffleList.isNotEmpty) {
        for (int i = 0; i < deduplicated.length; i++) {
          _shuffleList.add(startIdx + i);
        }
      }
    } else {
      for (final track in tracks) {
        addTrack(track);
      }
    }
  }

  /// Replace a track at a specific index.
  void replaceTrack(int index, Track newTrack) {
    if (index >= 0 && index < _queue.value.length) {
      final queue = List<Track>.from(_queue.value);
      queue[index] = newTrack;
      _queue.add(queue);
    }
  }

  /// Insert a track to play next (after current).
  void addPlayNext(Track track) {
    if (_queue.value.isEmpty) {
      _queue.add([track]);
      _currentIndex = 0;
      return;
    }
    if (_queue.value.any((t) => t.id == track.id)) return;

    final insertIdx = _currentIndex + 1;
    final newQueue = List<Track>.from(_queue.value)..insert(insertIdx, track);
    _queue.add(newQueue);

    if (shuffleMode.value && _shuffleList.isNotEmpty) {
      for (int i = 0; i < _shuffleList.length; i++) {
        if (_shuffleList[i] >= insertIdx) _shuffleList[i]++;
      }
      _shuffleList.insert(_shuffleIndex + 1, insertIdx);
    }
  }

  /// Insert a track at a specific index.
  void insertTrack(int index, Track track) {
    // Guard against inserting a duplicate ID — same reason as addTrack.
    if (_queue.value.any((t) => t.id == track.id)) return;

    final queue = List<Track>.from(_queue.value);
    final actualIdx = index.clamp(0, queue.length);
    if (actualIdx < queue.length) {
      queue.insert(actualIdx, track);
    } else {
      queue.add(track);
    }
    _queue.add(queue);

    if (_currentIndex >= actualIdx) _currentIndex++;

    if (shuffleMode.value && _shuffleList.isNotEmpty) {
      for (int i = 0; i < _shuffleList.length; i++) {
        if (_shuffleList[i] >= actualIdx) _shuffleList[i]++;
      }
      final insertPos =
          (_shuffleIndex + 1 + (_shuffleList.length - _shuffleIndex - 1) ~/ 2)
              .clamp(0, _shuffleList.length);
      _shuffleList.insert(insertPos, actualIdx);
    }
  }

  /// Remove a track by queue index.
  void removeTrackAt(int index) {
    if (index >= _queue.value.length) return;

    final newQueue = List<Track>.from(_queue.value)..removeAt(index);
    _queue.add(newQueue);

    // Adjust shuffle list.
    if (shuffleMode.value && _shuffleList.isNotEmpty) {
      final posInShuffle = _shuffleList.indexOf(index);
      if (posInShuffle != -1) {
        _shuffleList.removeAt(posInShuffle);
        if (posInShuffle < _shuffleIndex) {
          _shuffleIndex--;
        } else if (posInShuffle == _shuffleIndex &&
            _shuffleIndex >= _shuffleList.length) {
          _shuffleIndex =
              (_shuffleList.length - 1).clamp(0, _shuffleList.length);
        }
      }
      for (int i = 0; i < _shuffleList.length; i++) {
        if (_shuffleList[i] > index) _shuffleList[i]--;
      }
    }

    // Adjust current index.
    if (_currentIndex == index) {
      if (newQueue.isEmpty) {
        _currentIndex = 0;
      } else {
        _currentIndex = _currentIndex.clamp(0, newQueue.length - 1);
      }
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
  }

  /// Move a track from one position to another.
  void moveTrack(int oldIndex, int newIndex) {
    final queue = List<Track>.from(_queue.value);
    if (oldIndex < newIndex) newIndex--;
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    _queue.add(queue);

    // Update shuffle list.
    if (shuffleMode.value && _shuffleList.isNotEmpty) {
      for (int i = 0; i < _shuffleList.length; i++) {
        if (_shuffleList[i] == oldIndex) {
          _shuffleList[i] = newIndex;
        } else if (oldIndex < newIndex) {
          if (_shuffleList[i] > oldIndex && _shuffleList[i] <= newIndex) {
            _shuffleList[i]--;
          }
        } else {
          if (_shuffleList[i] >= newIndex && _shuffleList[i] < oldIndex) {
            _shuffleList[i]++;
          }
        }
      }
    }

    // Update current index.
    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
  }

  /// Clear all tracks from the queue, keeping only the currently playing
  /// track so playback does not stop abruptly.
  void clearQueue() {
    final current = currentTrack;
    if (current == null) {
      _queue.add([]);
      _currentIndex = 0;
    } else {
      _queue.add([current]);
      _currentIndex = 0;
    }
    _shuffleList = [];
    _shuffleIndex = 0;
  }

  /// Replace the entire queue with new tracks.
  void updateQueue(List<Track> tracks, {int startIndex = 0}) {
    final seenIds = <String>{};
    final deduped =
        tracks.where((t) => seenIds.add(t.id)).toList(growable: false);
    _queue.add(deduped);
    _currentIndex =
        startIndex.clamp(0, deduped.isEmpty ? 0 : deduped.length - 1);
    if (shuffleMode.value && deduped.isNotEmpty) {
      _shuffleList = generateRandomIndices(deduped.length);
      _shuffleIndex = 0;
    } else {
      _shuffleList = [];
      _shuffleIndex = 0;
    }
  }

  bool replaceTrackById(String mediaId, Track replacement) {
    final queue = List<Track>.from(_queue.value);
    var changed = false;
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id == mediaId) {
        queue[i] = replacement;
        changed = true;
      }
    }
    if (changed) {
      _queue.add(queue);
    }
    return changed;
  }

  // ─── Internal ──────────────────────────────────────────────────────────────

  void _ensureShuffleListValid() {
    if (_shuffleList.isEmpty || _shuffleList.length != _queue.value.length) {
      log('Shuffle list invalid, regenerating', name: 'QueueManager');
      _shuffleList = generateRandomIndices(_queue.value.length);
      _shuffleIndex = _shuffleList.indexOf(_currentIndex);
      if (_shuffleIndex == -1) _shuffleIndex = 0;
    }
  }

  // ─── Track Serialization Helpers ─────────────────────────────────────────

  static Map<String, dynamic> _trackToMap(Track track) => {
        'id': track.id,
        'title': track.title,
        'artists':
            track.artists.map((a) => {'id': a.id, 'name': a.name}).toList(),
        'album': track.album != null
            ? {'id': track.album!.id, 'title': track.album!.title}
            : null,
        'durationMs': track.durationMs?.toString(),
        'thumbnail': track.thumbnail.url,
        'isExplicit': track.isExplicit,
      };

  static Track _mapToTrack(Map<String, dynamic> map) => Track(
        id: map['id'] as String? ?? '',
        title: map['title'] as String? ?? '',
        artists: (map['artists'] as List?)
                ?.map((a) => ArtistSummary(
                      id: a['id'] as String? ?? '',
                      name: a['name'] as String? ?? '',
                    ))
                .toList() ??
            [],
        album: map['album'] != null
            ? AlbumSummary(
                id: map['album']['id'] as String? ?? '',
                title: map['album']['title'] as String? ?? '',
                artists: const [],
              )
            : null,
        durationMs: map['durationMs'] != null
            ? BigInt.tryParse(map['durationMs'].toString())
            : null,
        thumbnail: Artwork(
            url: map['thumbnail'] as String? ?? '',
            layout: ImageLayout.square),
        isExplicit: map['isExplicit'] as bool? ?? false,
      );

  // ─── Queue Persistence ───────────────────────────────────────────────────

  /// Persist current queue state to DB settings and SharedPreferences for session restore.
  ///
  /// Stores v3 format with full Track objects alongside track IDs.
  /// This ensures that even ephemeral tracks (from search, streaming, etc.)
  /// survive app restart without requiring a prior database lookup.
  Future<void> persistQueueState() async {
    final tracks = _queue.value;
    if (tracks.isEmpty) return;
    try {
      final queueData = {
        'v': 3,
        'currentIndex': _currentIndex,
        'queueTitle': queueTitle.value,
        'tracks': tracks.map(_trackToMap).toList(),
        'trackIds': tracks.map((t) => t.id).toList(),
      };
      final raw = jsonEncode(queueData);

      // Fast, synchronous disk flush to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(SettingKeys.lastQueueState, raw);
      } catch (e) {
        log('Failed to persist queue to SharedPreferences: $e',
            name: 'QueueManager');
      }

      // Also persist to SettingsDAO
      try {
        final dao = SettingsDAO(DBProvider.db);
        await dao.putSettingStr(SettingKeys.lastQueueState, raw);
      } catch (e) {
        log('Failed to persist queue to SettingsDAO: $e', name: 'QueueManager');
      }

      // Best effort DB sync
      try {
        final trackDao = TrackDAO(DBProvider.db);
        await trackDao.upsertTracks(tracks);
      } catch (_) {}
    } catch (e) {
      log('Failed to persist queue: $e', name: 'QueueManager');
    }
  }

  /// Restore queue state from SharedPreferences or SettingsDAO. Returns true if restored.
  Future<bool> restoreQueueState() async {
    try {
      String? raw;
      try {
        final prefs = await SharedPreferences.getInstance();
        raw = prefs.getString(SettingKeys.lastQueueState);
      } catch (_) {}

      if (raw == null || raw.isEmpty) {
        try {
          final dao = SettingsDAO(DBProvider.db);
          raw = await dao.getSettingStr(SettingKeys.lastQueueState);
        } catch (_) {}
      }

      if (raw == null || raw.isEmpty) return false;
      final data = jsonDecode(raw) as Map<String, dynamic>;

      final tracks = <Track>[];

      // 1. Try v3 full-track deserialization first
      if (data['tracks'] is List && (data['tracks'] as List).isNotEmpty) {
        for (final item in (data['tracks'] as List)) {
          if (item is Map<String, dynamic>) {
            try {
              tracks.add(_mapToTrack(item));
            } catch (e) {
              log('Skipping malformed track map: $e', name: 'QueueManager');
            }
          }
        }
      }

      // 2. Fallback to v2 trackIds lookup
      if (tracks.isEmpty) {
        final trackIds = data['trackIds'] as List?;
        if (trackIds != null && trackIds.isNotEmpty) {
          final trackDao = TrackDAO(DBProvider.db);
          for (final id in trackIds) {
            if (id is! String || id.isEmpty) continue;
            try {
              final track = await trackDao.getTrackByMediaId(id);
              if (track != null) tracks.add(track);
            } catch (e) {
              log('Skipping track $id: $e', name: 'QueueManager');
            }
          }
        }
      }

      if (tracks.isEmpty) return false;

      final idx = (data['currentIndex'] as int?)
              ?.clamp(0, tracks.length - 1) ??
          0;
      _isRestoring = true;
      loadTracks(tracks, idx: idx, playlistName: data['queueTitle'] ?? 'Queue');
      _isRestoring = false;
      return true;
    } catch (e) {
      _isRestoring = false;
      log('Failed to restore queue: $e', name: 'QueueManager');
      return false;
    }
  }

  void dispose() {
    _queue.close();
    shuffleMode.close();
    queueTitle.close();
  }
}
