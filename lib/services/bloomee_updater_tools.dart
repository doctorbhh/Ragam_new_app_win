import 'dart:developer';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

bool isUpdateAvailable(
    String currentVer, String currentBuild, String newVer, String newBuild,
    {bool checkBuild = true}) {
  // Normalize versions and builds and compare component-wise.
  List<int> parseVersion(String v) {
    v = v.replaceFirst(RegExp(r'^v'), '');
    final parts = v.split('.');
    return parts.map((p) {
      final m = RegExp(r'^(\d+)').firstMatch(p);
      return m != null ? int.parse(m.group(1)!) : 0;
    }).toList();
  }

  List<int> currentParts = parseVersion(currentVer);
  List<int> newParts = parseVersion(newVer);

  final maxLen = currentParts.length > newParts.length
      ? currentParts.length
      : newParts.length;
  for (int i = 0; i < maxLen; i++) {
    final cur = i < currentParts.length ? currentParts[i] : 0;
    final neu = i < newParts.length ? newParts[i] : 0;
    if (neu > cur) return true;
    if (neu < cur) return false;
  }

  if (checkBuild && !Platform.isLinux) {
    int parseBuild(String b) {
      try {
        final parsed = int.parse(b);
        return parsed > 1000 ? parsed % 1000 : parsed;
      } catch (_) {
        final m = RegExp(r'(\d+)').firstMatch(b);
        return m != null ? int.parse(m.group(1)!) : 0;
      }
    }

    final curBuild = parseBuild(currentBuild);
    final newBuildNum = parseBuild(newBuild);
    if (newBuildNum > curBuild) return true;
    if (newBuildNum < curBuild) return false;
  }

  return false;
}

Future<Map<String, dynamic>> sourceforgeUpdate(
    {Duration timeout = const Duration(seconds: 6)}) async {
  return await getAppUpdates();
}

Future<Map<String, dynamic>> githubUpdate(
    {Duration timeout = const Duration(seconds: 6)}) async {
  return await getAppUpdates();
}

/// App update checks for upstream Bloomee repository releases are disabled.
/// Updates are delivered exclusively via plugin rollouts.
Future<Map<String, dynamic>> getAppUpdates() async {
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    return {
      'results': false,
      'source': 'none',
      'currVer': packageInfo.version,
      'currBuild': packageInfo.buildNumber,
      'newVer': packageInfo.version,
      'newBuild': packageInfo.buildNumber,
      'changelogs': null,
    };
  } catch (_) {
    return {
      'results': false,
      'source': 'none',
      'currVer': '0.0.0',
      'currBuild': '0',
      'newVer': '0.0.0',
      'newBuild': '0',
      'changelogs': null,
    };
  }
}

/// Fetch the project's CHANGELOG.md from the hosted GitHub Pages site.
/// Returns the changelog text on success, or null on any failure.
Future<String?> fetchChangelog(
    {Duration timeout = const Duration(seconds: 6)}) async {
  const changelogUrl =
      'https://hemantkarya.github.io/BloomeeTunes/CHANGELOG.md';
  try {
    final response = await http.get(Uri.parse(changelogUrl)).timeout(timeout);
    if (response.statusCode == 200) {
      return response.body;
    } else {
      log('Changelog fetch returned status ${response.statusCode}',
          name: 'UpdaterTools');
      return null;
    }
  } catch (e, st) {
    log('Failed to fetch changelog: $e\n$st', name: 'UpdaterTools');
    return null;
  }
}

/// Backwards-compatible wrapper for existing callers
Future<Map<String, dynamic>> getLatestVersion() async => await getAppUpdates();

String? extractUpUrl(Map<String, dynamic> data) {
  // List<String> urls = [];

  for (var element in (data["assets"] as List)) {
    // urls.add(element["browser_download_url"]);
    if (element["browser_download_url"].toString().contains("windows")) {
      if (Platform.isWindows) {
        return element["browser_download_url"].toString();
      }
    } else if (element["browser_download_url"].toString().contains("android")) {
      if (Platform.isAndroid) {
        return element["browser_download_url"].toString();
      }
    } else {
      continue;
    }
  }
  return null;
}
