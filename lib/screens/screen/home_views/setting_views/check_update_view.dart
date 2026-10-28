import 'package:Bloomee/screens/screen/plugin_manager_screen.dart';
import 'package:Bloomee/services/bloomee_updater_tools.dart';
import 'package:flutter/material.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:icons_plus/icons_plus.dart';

class CheckUpdateView extends StatelessWidget {
  const CheckUpdateView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Default_Theme.themeColor,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded,
              color: Default_Theme.primaryColor1),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          l10n.updateCheckTitle,
          style: const TextStyle(
            color: Default_Theme.primaryColor1,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ).merge(Default_Theme.secondoryTextStyle),
        ),
      ),
      body: Center(
        child: FutureBuilder(
          future: getLatestVersion(),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              final data = snapshot.data ?? {};
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Default_Theme.accentColor2.withValues(alpha: 0.15),
                        border: Border.all(
                          color: Default_Theme.accentColor2.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          MingCute.check_circle_fill,
                          color: Default_Theme.accentColor2,
                          size: 48,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.updateUpToDate,
                      style: const TextStyle(
                        color: Default_Theme.primaryColor1,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ).merge(Default_Theme.secondoryTextStyleMedium),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Ragam features and music sources update automatically whenever new plugin rollouts are available.',
                      style: TextStyle(
                        color: Default_Theme.primaryColor1.withValues(alpha: 0.65),
                        fontSize: 14,
                        height: 1.4,
                      ).merge(Default_Theme.secondoryTextStyle),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const PluginManagerScreen(),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 14),
                          decoration: BoxDecoration(
                            color: Default_Theme.accentColor2.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Default_Theme.accentColor2,
                              width: 1.2,
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                MingCute.plugin_2_fill,
                                size: 20,
                                color: Default_Theme.accentColor2,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Manage Plugins',
                                style: TextStyle(
                                  color: Default_Theme.accentColor2,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 30),
                      child: Text(
                        l10n.updateCurrentVersion(
                          data["currVer"] ?? '',
                          data["currBuild"] ?? '',
                        ),
                        style: TextStyle(
                          color: Default_Theme.primaryColor2.withValues(alpha: 0.5),
                          fontSize: 13,
                        ).merge(Default_Theme.tertiaryTextStyle),
                      ),
                    ),
                  ],
                ),
              );
            } else {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    height: 48,
                    width: 48,
                    child: CircularProgressIndicator(
                      color: Default_Theme.accentColor2,
                      strokeWidth: 3,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.updateChecking,
                    style: const TextStyle(
                      color: Default_Theme.accentColor2,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ).merge(Default_Theme.tertiaryTextStyle),
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }
          },
        ),
      ),
    );
  }
}
