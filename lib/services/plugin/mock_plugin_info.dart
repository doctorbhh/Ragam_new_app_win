import 'package:Bloomee/src/rust/api/plugin/manifest.dart';
import 'package:Bloomee/src/rust/api/plugin/plugin_info.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';

class MockPluginInfo implements PluginInfo {
  @override
  Manifest manifest;

  @override
  String name;

  @override
  String pluginPath;

  @override
  PluginType pluginType;

  @override
  bool get isDisposed => false;

  MockPluginInfo({
    required this.manifest,
    required this.name,
    required this.pluginPath,
    required this.pluginType,
  });

  @override
  void rustMut() {}

  @override
  bool get isRustOpaque => false;

  @override
  int get rustOpaquePtr => 0;

  @override
  void dispose() {}
}

final spotifyMockPluginInfo = MockPluginInfo(
  name: 'Spotify',
  pluginPath: '',
  pluginType: PluginType.contentResolver,
  manifest: Manifest(
    manifestVersion: 1,
    id: 'spotify',
    name: 'Spotify',
    version: '1.0.0',
    type: 'contentResolver',
    description: 'Spotify integration',
    publisher: const PluginPublisher(name: 'Bloomee'),
    license: 'MIT',
    homepage: '',
    hostSite: [],
    capabilities: [],
    keysRequired: {},
    resolver: false,
    countryAllowlist: [],
  ),
);

final ytMusicMockPluginInfo = MockPluginInfo(
  name: 'YouTube Music',
  pluginPath: '',
  pluginType: PluginType.contentResolver,
  manifest: Manifest(
    manifestVersion: 1,
    id: 'ytmusic',
    name: 'YouTube Music',
    version: '1.0.0',
    type: 'contentResolver',
    description: 'YouTube Music integration',
    publisher: const PluginPublisher(name: 'Bloomee'),
    license: 'MIT',
    homepage: '',
    hostSite: [],
    capabilities: [],
    keysRequired: {},
    resolver: false,
    countryAllowlist: [],
  ),
);
