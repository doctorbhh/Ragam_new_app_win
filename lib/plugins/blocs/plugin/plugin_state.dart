import 'package:equatable/equatable.dart';
import 'package:Bloomee/src/rust/api/plugin/plugin_info.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';
import 'package:Bloomee/services/plugin/mock_plugin_info.dart';

enum PluginOperation {
  loading,
  unloading,
  installing,
  deleting,
}

/// State for [PluginBloc].
///
/// Tracks available plugins, loaded plugin IDs, installation state,
/// and the most recent error.
class PluginState extends Equatable {
  /// All plugins found in the plugins directory.
  final List<PluginInfo> availablePlugins;

  /// IDs of currently loaded plugins.
  final Set<String> _nativeLoadedPluginIds;

  /// IDs of currently loaded plugins (including pseudo-plugins).
  Set<String> get loadedPluginIds => {..._nativeLoadedPluginIds, 'spotify', 'ytmusic'};

  /// Private helper for filtering native plugins.
  Set<String> get _allLoadedIds => _nativeLoadedPluginIds;

  /// Whether the plugin system is initialized.
  final bool isInitialized;

  /// Whether a plugin operation is in progress.
  final bool isLoading;

  /// Per-plugin active operations.
  final Map<String, PluginOperation> pluginOperations;

  /// Most recent error message, if any.
  final String? error;

  /// Most recent success notification, if any.
  final String? successMessage;

  const PluginState({
    this.availablePlugins = const [],
    Set<String> loadedPluginIds = const {},
    this.isInitialized = false,
    this.isLoading = false,
    this.pluginOperations = const {},
    this.error,
    this.successMessage,
  }) : _nativeLoadedPluginIds = loadedPluginIds;

  /// Initial state before any operations.
  const PluginState.initial()
      : availablePlugins = const [],
        _nativeLoadedPluginIds = const {},
        isInitialized = false,
        isLoading = false,
        pluginOperations = const {},
        error = null,
        successMessage = null;

  /// Get loaded content resolver plugins.
  List<PluginInfo> get loadedContentResolvers {
    final resolvers = availablePlugins
        .where((p) =>
            p.pluginType == PluginType.contentResolver &&
            _allLoadedIds.contains(p.manifest.id))
        .toList();

    // Inject Dart-native pseudo-plugins
    resolvers.add(spotifyMockPluginInfo);
    resolvers.add(ytMusicMockPluginInfo);

    return resolvers;
  }

  /// Get loaded chart provider plugins.
  List<PluginInfo> get loadedChartProviders => availablePlugins
      .where((p) =>
          p.pluginType == PluginType.chartProvider &&
          _allLoadedIds.contains(p.manifest.id))
      .toList();

  /// Get loaded lyrics provider plugins.
  List<PluginInfo> get loadedLyricsProviders => availablePlugins
      .where((p) =>
          p.pluginType == PluginType.lyricsProvider &&
          _allLoadedIds.contains(p.manifest.id))
      .toList();

  /// Get loaded search suggestion provider plugins.
  List<PluginInfo> get loadedSearchSuggestionProviders => availablePlugins
      .where((p) =>
          p.pluginType == PluginType.searchSuggestionProvider &&
          _allLoadedIds.contains(p.manifest.id))
      .toList();

  /// Get loaded content importer plugins.
  List<PluginInfo> get loadedContentImporters => availablePlugins
      .where((p) =>
          p.pluginType == PluginType.contentImporter &&
          _allLoadedIds.contains(p.manifest.id))
      .toList();

  /// Check if a specific plugin is loaded.
  bool isPluginLoaded(String pluginId) {
    if (pluginId == 'spotify' || pluginId == 'ytmusic') return true;
    return loadedPluginIds.contains(pluginId);
  }

  /// Whether any plugin-specific operation is active.
  bool get hasActiveOperations => isLoading || pluginOperations.isNotEmpty;

  /// Return the active operation for [pluginId], if any.
  PluginOperation? operationFor(String pluginId) => pluginOperations[pluginId];

  PluginState copyWith({
    List<PluginInfo>? availablePlugins,
    Set<String>? loadedPluginIds,
    bool? isInitialized,
    bool? isLoading,
    Map<String, PluginOperation>? pluginOperations,
    String? error,
    bool clearError = false,
    String? successMessage,
    bool clearSuccessMessage = false,
  }) {
    return PluginState(
      availablePlugins: availablePlugins ?? this.availablePlugins,
      loadedPluginIds: loadedPluginIds ?? this._nativeLoadedPluginIds,
      isInitialized: isInitialized ?? this.isInitialized,
      isLoading: isLoading ?? this.isLoading,
      pluginOperations: pluginOperations ?? this.pluginOperations,
      error: clearError ? null : (error ?? this.error),
      successMessage: clearSuccessMessage
          ? null
          : (successMessage ?? this.successMessage),
    );
  }

  @override
  List<Object?> get props => [
        availablePlugins,
        _nativeLoadedPluginIds,
        isInitialized,
        isLoading,
        pluginOperations,
        error,
        successMessage,
      ];
}
