import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/sync/ragam_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SyncSettingsView extends StatefulWidget {
  const SyncSettingsView({super.key});

  @override
  State<SyncSettingsView> createState() => _SyncSettingsViewState();
}

class _SyncSettingsViewState extends State<SyncSettingsView> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();

  bool _useCustomSupabase = false;
  bool _isTesting = false;
  bool? _testSuccess;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settingsDao = SettingsDAO(DBProvider.db);
    final customUrl = await settingsDao.getSettingStr(SettingKeys.syncCustomSupabaseUrl);
    final customKey = await settingsDao.getSettingStr(SettingKeys.syncCustomSupabaseKey);
    final name = RagamSyncService.instance.deviceName;

    setState(() {
      _nameController.text = name;
      _useCustomSupabase = (customUrl != null && customUrl.isNotEmpty);
      _urlController.text = customUrl ?? '';
      _keyController.text = customKey ?? '';
    });
  }

  Future<void> _saveDeviceName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    await RagamSyncService.instance.setDeviceName(name);
    SnackbarService.showMessage('Device name updated: $name');
  }

  Future<void> _testAndSaveSupabase() async {
    setState(() {
      _isTesting = true;
      _testSuccess = null;
    });

    if (!_useCustomSupabase) {
      // Revert to default
      await RagamSyncService.instance.updateCustomSupabase(url: '', anonKey: '');
      setState(() {
        _isTesting = false;
        _testSuccess = true;
      });
      SnackbarService.showMessage('Reverted to default community relay');
      return;
    }

    final url = _urlController.text.trim();
    final key = _keyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      SnackbarService.showMessage('Please provide both Project URL and Anon Key');
      setState(() => _isTesting = false);
      return;
    }

    try {
      final client = SupabaseClient(url, key);
      final ch = client.channel('connection_test');
      ch.subscribe();
      await client.removeChannel(ch);

      await RagamSyncService.instance.updateCustomSupabase(url: url, anonKey: key);
      setState(() {
        _isTesting = false;
        _testSuccess = true;
      });
      SnackbarService.showMessage('Connected successfully to your Supabase project!');
    } catch (e) {
      setState(() {
        _isTesting = false;
        _testSuccess = false;
      });
      SnackbarService.showMessage('Connection failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        title: const Text('Sync & Database'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          // Device Identity Card
          _buildCard(
            title: 'Device Identity',
            icon: MingCute.device_line,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _nameController,
                  style: const TextStyle(color: Default_Theme.primaryColor1),
                  decoration: InputDecoration(
                    labelText: 'Display Name',
                    labelStyle: TextStyle(
                      color: Default_Theme.primaryColor1.withValues(alpha: 0.6),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(MingCute.check_fill, color: Default_Theme.accentColor1),
                      tooltip: 'Save Name',
                      onPressed: _saveDeviceName,
                    ),
                    filled: true,
                    fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      'Device ID: ',
                      style: TextStyle(
                        fontSize: 12,
                        color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        RagamSyncService.instance.deviceId,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Default_Theme.primaryColor1.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(MingCute.copy_2_line, size: 16),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: RagamSyncService.instance.deviceId));
                        SnackbarService.showMessage('Device ID copied');
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Realtime Database / BYOD Card
          _buildCard(
            title: 'Realtime Database (BYOD)',
            icon: MingCute.server_2_line,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ragam connects devices and coordinates party rooms in real-time without requiring any account signups or passwords. You can bring your own Supabase project for complete privacy and unlimited control!',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: Default_Theme.accentColor1,
                  title: const Text(
                    'Use Custom Supabase Project',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Default_Theme.primaryColor1,
                    ),
                  ),
                  subtitle: Text(
                    _useCustomSupabase ? 'Using your private Supabase' : 'Using default public relay',
                    style: TextStyle(
                      fontSize: 12,
                      color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                    ),
                  ),
                  value: _useCustomSupabase,
                  onChanged: (val) {
                    setState(() => _useCustomSupabase = val);
                  },
                ),
                if (_useCustomSupabase) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _urlController,
                    style: const TextStyle(color: Default_Theme.primaryColor1),
                    decoration: InputDecoration(
                      labelText: 'Supabase Project URL',
                      hintText: 'https://xyz.supabase.co',
                      hintStyle: TextStyle(color: Default_Theme.primaryColor1.withValues(alpha: 0.3)),
                      filled: true,
                      fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keyController,
                    obscureText: _obscureKey,
                    style: const TextStyle(color: Default_Theme.primaryColor1),
                    decoration: InputDecoration(
                      labelText: 'Supabase Anon Key',
                      hintText: 'eyJhbGciOi...',
                      hintStyle: TextStyle(color: Default_Theme.primaryColor1.withValues(alpha: 0.3)),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureKey ? MingCute.eye_close_line : MingCute.eye_line),
                        onPressed: () => setState(() => _obscureKey = !_obscureKey),
                      ),
                      filled: true,
                      fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isTesting ? null : _testAndSaveSupabase,
                        icon: _isTesting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(
                                _testSuccess == true
                                    ? MingCute.check_circle_fill
                                    : _testSuccess == false
                                        ? MingCute.close_circle_fill
                                        : MingCute.flash_fill,
                                size: 18,
                              ),
                        label: Text(_isTesting ? 'Testing...' : 'Save & Connect'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Default_Theme.accentColor1,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required String title, required IconData icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Default_Theme.accentColor1, size: 20),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Default_Theme.primaryColor1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
