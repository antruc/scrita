import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' show AndroidAudioSource;
import 'package:url_launcher/url_launcher.dart';

import '../backup.dart';
import '../l10n.dart';
import '../main.dart' show appTheme, rowCard, setTheme, wallpaperSeed;
import '../prefs.dart' show audioSource, exportM4a, materialYou, seedColor;
import 'onboarding_screen.dart';

// ponytail: duplicates pubspec's version name; package_info_plus if it drifts.
const _appVersion = '1.0.0';

/// Seeds offered as palettes. Material 3 derives light and dark schemes
/// from each one.
const _seeds = <Color>[
  Colors.indigo,
  Colors.teal,
  Colors.green,
  Colors.orange,
  Colors.pink,
  Colors.deepPurple,
  Colors.brown,
  Colors.blueGrey,
];

/// Mic paths offered as recording modes: (source, title, hint).
/// voiceCommunication applies the system call filters (noise, gain, echo) in
/// one go. A getter, not a final: tr() must run after main() sets the
/// language.
List<(AndroidAudioSource, String, String)> get _sources => [
  (
    AndroidAudioSource.voiceRecognition,
    tr('cleanVoiceRecommended'),
    tr('cleanVoiceHint'),
  ),
  (
    AndroidAudioSource.voiceCommunication,
    tr('noiseReduction'),
    tr('noiseReductionHint'),
  ),
  (
    AndroidAudioSource.mic,
    tr('modeDefault'),
    tr('modeDefaultHint'),
  ),
  (
    AndroidAudioSource.camcorder,
    tr('modeGroup'),
    tr('modeGroupHint'),
  ),
  (
    AndroidAudioSource.unprocessed,
    tr('unprocessed'),
    tr('unprocessedHint'),
  ),
];

String _modeName(ThemeMode m) => switch (m) {
  ThemeMode.system => tr('system'),
  ThemeMode.light => tr('light'),
  ThemeMode.dark => tr('dark'),
};

/// Matches the code: INTERNET is used only by downloadModels
/// (lib/models.dart). Update it if that ever changes.
String get _privacy => tr('privacyText');

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _RecordingModeTile(),
          const _AudioFormatTile(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr('theme')),
            subtitle: ValueListenableBuilder(
              valueListenable: appTheme,
              builder: (_, t, _) => Text(_modeName(t.$1)),
            ),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => const _ThemeDialog(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: Text(tr('backUp')),
            subtitle: Text(
              tr('recordingsAndSettings'),
            ),
            onTap: () async {
              if (!await _confirmExport(context) || !context.mounted) return;
              await _run(
                context,
                tr('backupFailed'),
                () async {
                  await exportBackup();
                  return tr('backupSaved');
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: Text(tr('restoreBackup')),
            subtitle: Text(tr('fromAFile')),
            onTap: () async {
              final picked = (await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['zip'],
              ))?.path;
              if (picked == null || !context.mounted) return;
              await _run(
                context,
                tr('couldNotRestoreTheBackup'),
                () async {
                  try {
                    await importBackup(picked);
                    return tr('backupRestored');
                  } finally {
                    // file_picker's cache copy can be as big as the backup.
                    if (p.isWithin(
                      (await getTemporaryDirectory()).path,
                      picked,
                    )) {
                      await File(picked).delete();
                    }
                  }
                },
              );
              // Apply the restored theme now, not at next launch.
              setTheme();
            },
          ),
          ListTile(
            leading: const Icon(Icons.school_outlined),
            title: Text(tr('viewTutorial')),
            subtitle: Text(tr('howToUseScrita')),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const OnboardingScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('GitHub'),
            subtitle: const Text('antruc/scrita'),
            onTap: () => launchUrl(
              Uri.parse('https://github.com/antruc/scrita'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(tr('about')),
            subtitle: Text('${tr('version')} $_appVersion'),
            // Own dialog, not showAboutDialog: that one indents the text for an
            // icon slot and leaves an empty legalese line at the bottom.
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) {
                final l = MaterialLocalizations.of(ctx);
                return AlertDialog(
                  title: const Text('Scrita'),
                  content: Text(
                    '${tr('version')} $_appVersion\n'
                    'GPL-3.0-or-later',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => showLicensePage(
                        context: ctx,
                        applicationName: 'Scrita',
                        applicationVersion: _appVersion,
                      ),
                      child: Text(l.viewLicensesButtonLabel),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(l.closeButtonLabel),
                    ),
                  ],
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(tr('privacy')),
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('privacyPolicy')),
                content: SingleChildScrollView(child: Text(_privacy)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(MaterialLocalizations.of(ctx).closeButtonLabel),
                  ),
                ],
              ),
            ),
          ),
        ].map(rowCard).toList(),
      ),
    );
  }

  Future<bool> _confirmExport(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('backUpQuestion')),
          content: Text(
            tr('backupConfirmBody'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('backUp')),
            ),
          ],
        ),
      ) ==
      true;

  /// Runs [work] behind a blocking spinner (backups can take a while) and
  /// shows the message it returns. On failure, a FormatException's message
  /// (meant for the user) or [failed].
  Future<void> _run(
    BuildContext context,
    String failed,
    Future<String> Function() work,
  ) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    String msg;
    try {
      msg = await work();
    } catch (e) {
      msg = e is FormatException ? e.message : failed;
    }
    nav.pop();
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Format the app's recordings are saved to Documents with. Imported audios
/// are always saved in their own format.
class _AudioFormatTile extends StatefulWidget {
  const _AudioFormatTile();

  @override
  State<_AudioFormatTile> createState() => _AudioFormatTileState();
}

class _AudioFormatTileState extends State<_AudioFormatTile> {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.audio_file_outlined),
      title: Text(tr('audioFormat')),
      subtitle: Text(exportM4a ? 'M4A' : 'WAV'),
      onTap: () async {
        final m4a = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              tr('audioFormatWhenSaving'),
            ),
            content: RadioGroup<bool>(
              groupValue: exportM4a,
              onChanged: (v) => Navigator.pop(ctx, v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('audioFormatHint'),
                  ),
                  const SizedBox(height: 8),
                  RadioListTile(
                    value: true,
                    title: Text(tr('m4aRecommended')),
                    subtitle: Text(
                      tr('m4aHint'),
                    ),
                  ),
                  RadioListTile(
                    value: false,
                    title: const Text('WAV'),
                    subtitle: Text(
                      tr('wavHint'),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('cancel')),
              ),
            ],
          ),
        );
        if (m4a != null) setState(() => exportM4a = m4a);
      },
    );
  }
}

/// Mic path for new recordings. Home reads it at each start.
class _RecordingModeTile extends StatefulWidget {
  const _RecordingModeTile();

  @override
  State<_RecordingModeTile> createState() => _RecordingModeTileState();
}

class _RecordingModeTileState extends State<_RecordingModeTile> {
  @override
  Widget build(BuildContext context) {
    // A restored backup may hold a source not offered here.
    // Short name for the subtitle: the dialog keeps "(recommended)".
    final name = _sources
        .firstWhere((s) => s.$1 == audioSource, orElse: () => _sources.first)
        .$2
        .split(' (')
        .first;
    return ListTile(
      leading: const Icon(Icons.mic_none),
      title: Text(tr('recordingMode')),
      subtitle: Text(name),
      onTap: () async {
        final source = await showDialog<AndroidAudioSource>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('recordingMode')),
            // Five options with hints may not fit a small screen.
            content: SingleChildScrollView(
              child: RadioGroup<AndroidAudioSource>(
                groupValue: audioSource,
                onChanged: (v) => Navigator.pop(ctx, v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (value, title, subtitle) in _sources)
                      RadioListTile<AndroidAudioSource>(
                        value: value,
                        title: Text(title),
                        subtitle: Text(subtitle),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('cancel')),
              ),
            ],
          ),
        );
        if (source != null) setState(() => audioSource = source);
      },
    );
  }
}

/// Wallpaper switch, palettes and mode. Applies each tap at once, so the app
/// behind the dialog previews it. The wallpaper switch only greys out the
/// palettes: the mode works with either.
class _ThemeDialog extends StatelessWidget {
  const _ThemeDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
    return AlertDialog(
      title: Text(tr('theme')),
      content: ValueListenableBuilder(
        valueListenable: appTheme,
        builder: (context, t, _) {
          // No wallpaper colors (Android < 12): no switch, palettes always on.
          final wallpaper = wallpaperSeed != null && materialYou;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (wallpaperSeed != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      tr('wallpaperColors'),
                    ),
                    subtitle: Text(
                      tr('wallpaperColorsHint'),
                    ),
                    value: wallpaper,
                    // Off restores the saved palette.
                    onChanged: (on) => on
                        ? setTheme(wallpaper: true)
                        : setTheme(seed: seedColor),
                  ),
                label(tr('palettes')),
                // Dimmed but still checked while the switch is on, so it shows
                // which palette comes back.
                Opacity(
                  opacity: wallpaper ? 0.38 : 1,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final c in _seeds)
                        _swatch(
                          c,
                          selected: c.toARGB32() == seedColor.toARGB32(),
                          onTap: wallpaper ? null : () => setTheme(seed: c),
                        ),
                    ],
                  ),
                ),
                label(tr('mode')),
                SegmentedButton<ThemeMode>(
                  segments: [
                    for (final m in ThemeMode.values)
                      ButtonSegment(value: m, label: Text(_modeName(m))),
                  ],
                  selected: {t.$1},
                  onSelectionChanged: (s) => setTheme(mode: s.first),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('done')),
        ),
      ],
    );
  }

  Widget _swatch(
    Color c, {
    required bool selected,
    required VoidCallback? onTap,
  }) => Semantics(
    label: tr('palette'),
    selected: selected,
    enabled: onTap != null,
    button: true,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: CircleAvatar(
        radius: 20,
        backgroundColor: c,
        // White is lost on orange and green: pick by the swatch.
        foregroundColor:
            ThemeData.estimateBrightnessForColor(c) == Brightness.dark
            ? Colors.white
            : Colors.black,
        child: selected ? const Icon(Icons.check) : null,
      ),
    ),
  );
}
