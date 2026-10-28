import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:Bloomee/core/theme/app_theme.dart';

class WebviewLoginScreen extends StatefulWidget {
  final String title;
  final String initialUrl;
  final List<String> targetCookies;
  final Future<void> Function(Map<String, String> cookies) onLoginComplete;

  const WebviewLoginScreen({
    super.key,
    required this.title,
    required this.initialUrl,
    required this.targetCookies,
    required this.onLoginComplete,
  });

  @override
  State<WebviewLoginScreen> createState() => _WebviewLoginScreenState();
}

class _WebviewLoginScreenState extends State<WebviewLoginScreen> {
  final cookieManager = CookieManager.instance();
  bool _isLoading = true;
  InAppWebViewController? webViewController;

  Future<void> _checkCookies(Uri url) async {
    try {
      final cookies = await cookieManager.getCookies(url: WebUri.uri(url));
      
      final Map<String, String> cookiesMap = {};
      final List<String> cookieStrings = [];
      for (var cookie in cookies) {
        cookiesMap[cookie.name] = cookie.value;
        cookieStrings.add('${cookie.name}=${cookie.value}');
      }

      bool hasAllCookies = true;
      for (final target in widget.targetCookies) {
        if (!cookiesMap.containsKey(target) || cookiesMap[target]!.isEmpty) {
          hasAllCookies = false;
          break;
        }
      }

      if (hasAllCookies) {
        final extracted = <String, String>{};
        for (final target in widget.targetCookies) {
          extracted[target] = cookiesMap[target]!;
        }
        extracted['cookie_string'] = cookieStrings.join('; ');

        await widget.onLoginComplete(extracted);
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      debugPrint('Error getting cookies: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Default_Theme.themeColor,
        iconTheme: const IconThemeData(color: Default_Theme.primaryColor1),
        title: Text(widget.title, style: const TextStyle(color: Default_Theme.primaryColor1)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => webViewController?.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
            onWebViewCreated: (controller) {
              webViewController = controller;
            },
            onLoadStart: (controller, url) {
              setState(() => _isLoading = true);
            },
            onLoadStop: (controller, url) async {
              setState(() => _isLoading = false);
              if (url != null) {
                await _checkCookies(url);
              }
            },
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
