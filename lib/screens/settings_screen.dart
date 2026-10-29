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
    tr('Voz limpia (recomendado)', 'Clean voice (recommended)'),
    tr(
      'Audio sin filtros, el que mejor transcribe',
      'Unfiltered audio, the best for transcription',
    ),
  ),
  (
    AndroidAudioSource.voiceCommunication,
    tr('Reducción de ruido', 'Noise reduction'),
    tr(
      'Quita ruido de fondo y eco, aunque la voz pierde nitidez',
      'Removes background noise and echo, but the voice loses clarity',
    ),
  ),
  (
    AndroidAudioSource.mic,
    tr('Predeterminado', 'Default'),
    tr(
      'Usa el ajuste del fabricante, el resultado cambia según el modelo',
      "Uses the maker's tuning, results vary by model",
    ),
  ),
  (
    AndroidAudioSource.camcorder,
    tr('Varias personas', 'Group'),
    tr(
      'Usa varios micrófonos, sirve para una mesa con mucha gente',
      'Uses several mics, good for a table with many people',
    ),
  ),
  (
    AndroidAudioSource.unprocessed,
    tr('Sin procesar', 'Unprocessed'),
    tr(
      'Sin ningún ajuste, el volumen queda bajo y no funciona en todos los teléfonos',
      'No processing at all, low volume and not every phone supports it',
    ),
  ),
];

String _modeName(ThemeMode m) => switch (m) {
  ThemeMode.system => tr('Sistema', 'System'),
  ThemeMode.light => tr('Claro', 'Light'),
  ThemeMode.dark => tr('Oscuro', 'Dark'),
};

/// Matches the code: INTERNET is used only by downloadModels
/// (lib/models.dart). Update it if that ever changes.
String get _privacy => tr(
  'Scrita no recopila, envía ni comparte ningún dato. No tiene cuentas, '
      'anuncios ni analíticas.\n\n'
      'Internet: se usa una sola vez, para descargar el modelo de voz desde '
      'GitHub. Como en cualquier descarga, GitHub ve tu dirección IP. Nada '
      'de lo que grabas se envía: la transcripción se hace en tu '
      'teléfono.\n\n'
      'Micrófono: se usa solo mientras grabas. Las grabaciones, '
      'transcripciones y ajustes se guardan en el almacenamiento privado de '
      'la app, en tu teléfono.\n\n'
      'Notificaciones: muestran el progreso de una grabación o '
      'transcripción en curso.\n\n'
      'Los archivos solo salen de la app cuando tú lo decides: al guardar en '
      'Documentos, compartir o exportar una copia. Desde ahí, su privacidad '
      'depende de dónde los guardes o con quién los compartas.\n\n'
      'Desinstalar la app borra todos sus datos, salvo lo que hayas guardado '
      'en Documentos o exportado.',
  'Scrita does not collect, send or share any data. It has no accounts, ads '
      'or analytics.\n\n'
      'Internet: used only once, to download the voice model from GitHub. '
      'As with any download, GitHub sees your IP address. Nothing you record '
      'is sent: transcription happens on your phone.\n\n'
      'Microphone: used only while you record. Recordings, transcripts and '
      "settings are stored in the app's private storage, on your phone.\n\n"
      'Notifications: show the progress of a recording or transcription in '
      'progress.\n\n'
      'Files leave the app only when you choose to: saving to Documents, '
      'sharing or exporting a backup. From there, their privacy depends on '
      'where you keep them or who you share them with.\n\n'
      "Uninstalling the app deletes all its data, except what you saved to "
      'Documents or exported.',
);

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Configuración', 'Settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _RecordingModeTile(),
          const _AudioFormatTile(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr('Tema', 'Theme')),
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
            title: Text(tr('Hacer copia', 'Back up')),
            subtitle: Text(
              tr('Grabaciones y ajustes', 'Recordings and settings'),
            ),
            onTap: () async {
              if (!await _confirmExport(context) || !context.mounted) return;
              await _run(
                context,
                tr(
                  'No se pudo hacer la copia. Revisa el espacio libre',
                  'Could not back up. Check free space',
                ),
                () async {
                  await exportBackup();
                  return tr(
                    'Copia guardada en Documentos › Scrita',
                    'Backup saved to Documents › Scrita',
                  );
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: Text(tr('Recuperar copia', 'Restore backup')),
            subtitle: Text(tr('Desde un archivo', 'From a file')),
            onTap: () async {
              final picked = (await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['zip'],
              ))?.path;
              if (picked == null || !context.mounted) return;
              await _run(
                context,
                tr(
                  'No se pudo recuperar la copia',
                  'Could not restore the backup',
                ),
                () async {
                  try {
                    await importBackup(picked);
                    return tr('Copia recuperada', 'Backup restored');
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
            title: Text(tr('Ver tutorial', 'View tutorial')),
            subtitle: Text(tr('Cómo usar Scrita', 'How to use Scrita')),
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
            title: Text(tr('Acerca de', 'About')),
            subtitle: Text('${tr('Versión', 'Version')} $_appVersion'),
            // Own dialog, not showAboutDialog: that one indents the text for an
            // icon slot and leaves an empty legalese line at the bottom.
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) {
                final l = MaterialLocalizations.of(ctx);
                return AlertDialog(
                  title: const Text('Scrita'),
                  content: Text(
                    '${tr('Versión', 'Version')} $_appVersion\n'
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
            title: Text(tr('Privacidad', 'Privacy')),
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('Política de privacidad', 'Privacy policy')),
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
          title: Text(tr('¿Hacer copia de seguridad?', 'Back up?')),
          content: Text(
            tr(
              'Se guardarán grabaciones, transcripciones y ajustes en un archivo. '
                  'Puede tardar y ocupar bastante espacio',
              'Recordings, transcripts and settings will be saved to a file. '
                  'It can take a while and use a lot of space',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Cancelar', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Hacer copia', 'Back up')),
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
      title: Text(tr('Formato del audio', 'Audio format')),
      subtitle: Text(exportM4a ? 'M4A' : 'WAV'),
      onTap: () async {
        final m4a = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              tr('Formato del audio al guardar', 'Audio format when saving'),
            ),
            content: RadioGroup<bool>(
              groupValue: exportM4a,
              onChanged: (v) => Navigator.pop(ctx, v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(
                      'Formato de tus grabaciones al guardarlas en Documentos. Los '
                          'audios importados en otro formato se guardan tal cual',
                      'Format of your recordings when saved to Documents. Audios '
                          'imported in another format are saved as they are',
                    ),
                  ),
                  const SizedBox(height: 8),
                  RadioListTile(
                    value: true,
                    title: Text(tr('M4A (recomendado)', 'M4A (recommended)')),
                    subtitle: Text(
                      tr(
                        'Ocupa mucho menos espacio y suena casi igual. Se abre '
                            'en cualquier teléfono o computadora',
                        'Takes much less space and sounds almost the same. Opens '
                            'on any phone or computer',
                      ),
                    ),
                  ),
                  RadioListTile(
                    value: false,
                    title: const Text('WAV'),
                    subtitle: Text(
                      tr(
                        'Calidad original, pero ocupa mucho espacio',
                        'Original quality, but takes a lot of space',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Cancelar', 'Cancel')),
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
      title: Text(tr('Modo de grabación', 'Recording mode')),
      subtitle: Text(name),
      onTap: () async {
        final source = await showDialog<AndroidAudioSource>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Modo de grabación', 'Recording mode')),
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
                child: Text(tr('Cancelar', 'Cancel')),
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
      title: Text(tr('Tema', 'Theme')),
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
                      tr('Colores del fondo de pantalla', 'Wallpaper colors'),
                    ),
                    subtitle: Text(
                      tr(
                        'La app toma los colores de tu fondo',
                        'The app takes the colors of your wallpaper',
                      ),
                    ),
                    value: wallpaper,
                    // Off restores the saved palette.
                    onChanged: (on) => on
                        ? setTheme(wallpaper: true)
                        : setTheme(seed: seedColor),
                  ),
                label(tr('Paletas', 'Palettes')),
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
                label(tr('Modo', 'Mode')),
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
          child: Text(tr('Listo', 'Done')),
        ),
      ],
    );
  }

  Widget _swatch(
    Color c, {
    required bool selected,
    required VoidCallback? onTap,
  }) => Semantics(
    label: tr('Paleta', 'Palette'),
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
