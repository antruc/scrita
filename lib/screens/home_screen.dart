import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio.dart';
import '../background.dart';
import '../l10n.dart';
import '../main.dart' show appFooter, rowCard;
import '../models.dart' as models;
import '../prefs.dart' as prefs;
import '../recorder.dart';
import '../store.dart';
import '../transcript.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart';
import 'transcript_screen.dart';

enum _Phase { preparing, idle, recording, error }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _recorder = InterviewRecorder();
  _Phase _phase = _Phase.preparing;
  String _status = tr('Preparando la app...', 'Getting the app ready...');
  String? _modelDir;

  double _level = -60;
  StreamSubscription<double>? _levelSub;
  Timer? _ticker;

  List<SavedTranscript> _history = [];
  List<PendingAudio> _pending = [];

  /// Audio paths hidden from the lists while their undo snackbar shows.
  final _deleting = <String>{};

  @override
  void initState() {
    super.initState();
    listenSharedAudio(_checkShared);
    _init();
  }

  Future<void> _init() async {
    try {
      final dir = await models.prepareModels(
        onStatus: (s) => setState(() => _status = s),
      );
      final firstRun = !prefs.tutorialSeen;
      final needsModel = models.missingDownloads(dir).isNotEmpty;
      if ((firstRun || needsModel) && mounted) {
        // It only closes once the model is in.
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OnboardingScreen(
              modelDir: needsModel ? dir : null,
              permissions: firstRun,
              tutorial: firstRun,
            ),
          ),
        );
        prefs.tutorialSeen = true;
      }
      await _refreshHistory();
      setState(() {
        _modelDir = dir;
        _phase = _Phase.idle;
        _status = '';
      });
      await _checkShared();
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _status = '$e';
      });
    }
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _ticker?.cancel();
    _recorder.dispose();
    BackgroundService.stop();
    super.dispose();
  }

  // ── Recording ─────────────────────────────────────────────────────────

  /// True while a start is in flight, so a double tap does not start twice.
  bool _starting = false;

  Future<void> _startRecording() async {
    if (_starting || _phase != _Phase.idle) return;
    _starting = true;
    try {
      await _startRecordingOnce();
    } finally {
      _starting = false;
    }
  }

  Future<void> _startRecordingOnce() async {
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      // Once denied, Android stops asking: only its settings can grant it.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Scrita necesita el micrófono para grabar. Actívalo en los ajustes',
              'Scrita needs the microphone to record. Turn it on in settings',
            ),
          ),
          action: SnackBarAction(
            label: tr('Abrir ajustes', 'Open settings'),
            onPressed: openAppSettings,
          ),
        ),
      );
      return;
    }
    await BackgroundService.requestNotificationPermission();
    // The service must start with the app visible and before the app goes to
    // the background; that way Android allows the microphone to keep working
    // with the screen off.
    try {
      await BackgroundService.start(
        BackgroundWork.recording,
        tr('Grabando...', 'Recording...'),
      );
    } catch (_) {
      _snack(
        tr('No se pudo iniciar la grabación', 'Could not start recording'),
      );
      return;
    }
    try {
      // Set in Settings, which is only reachable while idle.
      await _recorder.start(prefs.audioSource);
    } catch (_) {
      await BackgroundService.stop();
      _snack(
        tr(
          'No se pudo iniciar la grabación. Cierra otras apps que usen el micrófono',
          'Could not start recording. Close other apps using the microphone',
        ),
      );
      return;
    }
    _levelSub = _recorder.level.listen((l) => setState(() => _level = l));
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {});
      if (timer.tick % 5 == 0) {
        BackgroundService.update(
          '${tr('Grabando', 'Recording')} - '
          '${formatTimestamp(_recorder.elapsed.inSeconds.toDouble())}',
        );
      }
    });
    setState(() => _phase = _Phase.recording);
  }

  Future<void> _stopRecording() async {
    _ticker?.cancel();
    await _levelSub?.cancel();
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      // path stays null: the snack below reports it.
    } finally {
      await BackgroundService.stop();
      setState(() => _phase = _Phase.idle);
    }
    _snack(
      path == null
          ? tr(
              'No se pudo guardar la grabación',
              'Could not save the recording',
            )
          : tr(
              'Audio guardado en "Sin transcribir"',
              'Audio saved to "Not transcribed"',
            ),
    );
    await _refreshHistory();
  }

  // FileType.audio, not a list of extensions: Android filters by MIME type
  // and has none for some of them (.opus). _importAudio checks the format.
  Future<void> _pickAudio() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    final picked = file?.path;
    if (picked != null) await _importAudio(picked);
  }

  /// Imports an audio shared from another app (WhatsApp). It waits on the
  /// Android side until Home is idle and on top.
  Future<void> _checkShared() async {
    if (!mounted ||
        _phase != _Phase.idle ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    shareWaiting.value = false;
    final String? path;
    try {
      path = await takeSharedAudio();
    } catch (_) {
      _snack(tr('No se pudo recibir el audio', 'Could not receive the audio'));
      return;
    }
    if (path != null) await _importAudio(path);
  }

  String _formats() =>
      [for (final e in audioExts) e.substring(1).toUpperCase()].join(', ');

  /// Keeps [picked], in its own format, in the recordings folder and
  /// transcribes it. file_picker and shares leave a copy in the cache, which
  /// Android may clear at any time.
  Future<void> _importAudio(String picked) async {
    final ext = p.extension(picked).toLowerCase();
    final dir = await recordingsDir();
    final path = p.join(
      dir,
      '${freeBase(dir, p.basenameWithoutExtension(picked), [ext])}$ext',
    );
    final supported = audioExts.contains(ext);
    try {
      if (supported) await File(picked).copy(path);
    } catch (_) {
      // A half-copied file would show up as a broken pending audio.
      try {
        await File(path).delete();
      } catch (_) {}
      _snack(
        tr(
          'No se pudo importar el audio. Revisa el espacio libre',
          'Could not import the audio. Check free space',
        ),
      );
      return;
    } finally {
      if (p.isWithin((await getTemporaryDirectory()).path, picked)) {
        await File(picked).delete();
      }
    }
    if (!supported) {
      _snack(
        tr(
          'Formato no compatible. Usa ${_formats()}',
          'Unsupported format. Use ${_formats()}',
        ),
      );
      return;
    }
    await _openAudio(path, DateTime.now(), autoTranscribe: true);
  }

  Future<void> _refreshHistory() async {
    final h = await listTranscripts();
    // Unfiltered h: it tells which audios already have a transcript.
    final pending = await listPendingAudios(h);
    if (mounted) {
      setState(() {
        _history = [
          for (final s in h)
            if (!_deleting.contains(s.transcript.audioPath)) s,
        ];
        _pending = [
          for (final a in pending)
            if (!_deleting.contains(a.path)) a,
        ];
      });
      // Back from another screen or a dialog: a share may be waiting.
      await _checkShared();
    }
  }

  Future<void> _open(SavedTranscript s) =>
      _openAudio(s.transcript.audioPath, s.transcript.createdAt, saved: s);

  Future<void> _openAudio(
    String path,
    DateTime createdAt, {
    SavedTranscript? saved,
    bool autoTranscribe = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TranscriptScreen(
          audioPath: path,
          createdAt: createdAt,
          modelDir: _modelDir!,
          saved: saved,
          autoTranscribe: autoTranscribe,
        ),
      ),
    );
    await _refreshHistory();
  }

  Future<void> _delete(SavedTranscript s) => _deleteWithUndo(
    s.transcript.audioPath,
    tr('Transcripción eliminada', 'Transcript deleted'),
    () => deleteTranscript(s),
  );

  Future<void> _deletePending(PendingAudio a) => _deleteWithUndo(
    a.path,
    tr('Grabación eliminada', 'Recording deleted'),
    () => File(a.path).delete(),
  );

  /// Hides the row at once and deletes for real when the undo snackbar
  /// closes without "Undo". ponytail: if the app is killed in those seconds
  /// nothing is deleted, the row comes back on next launch.
  Future<void> _deleteWithUndo(
    String path,
    String msg,
    Future<void> Function() delete,
  ) async {
    _deleting.add(path);
    await _refreshHistory();
    if (!mounted) return;
    // Closing an earlier undo snackbar lets that deletion go ahead.
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final reason = await messenger
        .showSnackBar(
          SnackBar(
            content: Text(msg),
            // An action would keep it open until dismissed, and the file
            // must go once it times out.
            persist: false,
            action: SnackBarAction(
              label: tr('Deshacer', 'Undo'),
              onPressed: () {},
            ),
          ),
        )
        .closed;
    _deleting.remove(path);
    if (reason != SnackBarClosedReason.action) await _tryDelete(delete);
    await _refreshHistory();
  }

  Future<void> _tryDelete(Future<void> Function() delete) async {
    try {
      await delete();
    } catch (_) {
      _snack(
        tr('No se pudo eliminar', 'Could not delete'),
        retry: () async {
          await _tryDelete(delete);
          await _refreshHistory();
        },
      );
    }
  }

  /// Name dialog prefilled with [current]. Null if cancelled or empty.
  Future<String?> _askName(String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Cambiar nombre', 'Rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancelar', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('Guardar', 'Save')),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _rename(SavedTranscript s) async {
    final name = await _askName(s.transcript.title);
    if (name == null) return;
    s.transcript.title = name;
    try {
      await saveTranscript(s.transcript, jsonPath: s.jsonPath);
    } catch (_) {
      _snack(tr('No se pudo cambiar el nombre', 'Could not rename'));
    }
    await _refreshHistory();
  }

  Future<void> _renamePending(PendingAudio a) async {
    final name = await _askName(audioTitle(a.path, a.createdAt));
    if (name == null) return;
    try {
      await renameAudio(a.path, name);
    } catch (_) {
      _snack(tr('No se pudo cambiar el nombre', 'Could not rename'));
    }
    await _refreshHistory();
  }

  /// [retry] adds a "Retry" action that runs it.
  void _snack(String msg, {VoidCallback? retry}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(snackBar(msg, retry: retry));
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // WithForegroundTask: while the service runs, the "back" button minimizes
    // the app instead of closing it (closing it would cut the recording).
    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Scrita'),
          actions: [
            IconButton(
              icon: const Icon(Icons.audio_file_outlined),
              tooltip: tr(
                'Transcribir un archivo de audio',
                'Transcribe an audio file',
              ),
              onPressed: _phase == _Phase.idle ? _pickAudio : null,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: tr('Configuración', 'Settings'),
              // An import mid-recording would refresh the lists under the
              // recorder.
              onPressed:
                  _phase == _Phase.recording || _phase == _Phase.preparing
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                      // An import may have added transcripts and audios.
                      await _refreshHistory();
                    },
            ),
          ],
        ),
        // The body ends above the footer, so it never covers the last row.
        bottomNavigationBar: _buildFooter(context),
        body: _pending.isEmpty && _history.isEmpty
            ? (_phase == _Phase.preparing
                  ? const SizedBox.shrink()
                  : emptyState(
                      Theme.of(context),
                      Icons.mic_none,
                      tr('Aún no hay grabaciones', 'No recordings yet'),
                      tr(
                        'Toca el micrófono para grabar o el ícono de arriba '
                            'para importar y transcribir un audio guardado',
                        'Tap the mic to record or the icon at the top to '
                            'import and transcribe a saved audio file',
                      ),
                    ))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_pending.isNotEmpty) ...[
                    Text(
                      tr('Sin transcribir', 'Not transcribed'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final a in _pending) rowCard(_buildPendingTile(a)),
                    const SizedBox(height: 24),
                  ],
                  if (_history.isNotEmpty) ...[
                    Text(
                      tr('Transcripciones', 'Transcripts'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final s in _history) rowCard(_buildHistoryTile(s)),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    return appFooter(theme, switch (_phase) {
      _Phase.preparing => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(_status),
        ],
      ),
      _Phase.error => Text(
        _status,
        style: TextStyle(color: theme.colorScheme.error),
      ),
      _Phase.recording => _buildRecording(theme),
      // heightFactor: a plain Center fills the screen down here.
      _Phase.idle => Center(
        heightFactor: 1,
        // No shadow: it sits in the footer, it floats over nothing.
        child: FloatingActionButton.large(
          onPressed: _startRecording,
          tooltip: tr('Grabar', 'Record'),
          elevation: 0,
          // Primary for record, secondary for stop: both full tone, so
          // they stand out from the surface footer.
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          child: const Icon(Icons.mic),
        ),
      ),
    });
  }

  Widget _buildRecording(ThemeData theme) {
    final e = _recorder.elapsed;
    final t = formatTimestamp(e.inSeconds.toDouble());
    // -60 dB → 0, 0 dB → 1
    final level = ((_level + 60) / 60).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.fiber_manual_record, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Text(
              tr('Grabando', 'Recording'),
              style: theme.textTheme.titleMedium,
            ),
            const Spacer(),
            Text(t, style: theme.textTheme.headlineSmall),
          ],
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: level, minHeight: 8),
        const SizedBox(height: 20),
        Center(
          child: FloatingActionButton.large(
            onPressed: _stopRecording,
            tooltip: tr('Terminar grabación', 'Stop recording'),
            elevation: 0,
            backgroundColor: theme.colorScheme.secondary,
            foregroundColor: theme.colorScheme.onSecondary,
            child: const Icon(Icons.stop),
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryTile(SavedTranscript s) {
    final t = s.transcript;
    return ListTile(
      leading: _badge(Icons.description_outlined, transcribed: true),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatTimestamp(t.durationSeconds)} - '
        '${t.speakerNames.length} ${t.speakerNames.length == 1 ? tr('persona', 'speaker') : tr('personas', 'speakers')}',
      ),
      onTap: _phase == _Phase.idle ? () => _open(s) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr('Cambiar nombre', 'Rename'),
            onPressed: _phase == _Phase.idle ? () => _rename(s) : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            color: Theme.of(context).colorScheme.error,
            tooltip: tr('Eliminar', 'Delete'),
            onPressed: _phase == _Phase.idle ? () => _delete(s) : null,
          ),
        ],
      ),
    );
  }

  /// Leading icon that tells transcripts (primary) from audio-only (tertiary).
  Widget _badge(IconData icon, {required bool transcribed}) {
    final c = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: transcribed ? c.primaryContainer : c.tertiaryContainer,
      foregroundColor: transcribed
          ? c.onPrimaryContainer
          : c.onTertiaryContainer,
      child: Icon(icon),
    );
  }

  Widget _buildPendingTile(PendingAudio a) {
    final idle = _phase == _Phase.idle;
    return ListTile(
      leading: _badge(Icons.graphic_eq, transcribed: false),
      title: Text(
        audioTitle(a.path, a.createdAt),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(formatTimestamp(a.durationSeconds)),
      onTap: idle ? () => _openAudio(a.path, a.createdAt) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filledTonal(
            icon: const Icon(Icons.text_snippet_outlined),
            tooltip: tr('Transcribir', 'Transcribe'),
            onPressed: idle
                ? () => _openAudio(a.path, a.createdAt, autoTranscribe: true)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr('Cambiar nombre', 'Rename'),
            onPressed: idle ? () => _renamePending(a) : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            color: Theme.of(context).colorScheme.error,
            tooltip: tr('Eliminar', 'Delete'),
            onPressed: idle ? () => _deletePending(a) : null,
          ),
        ],
      ),
    );
  }
}
