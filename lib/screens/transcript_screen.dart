import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../audio.dart';
import '../background.dart';
import '../l10n.dart';
import '../main.dart' show appFooter;
import '../models.dart' as models;
import '../pipeline.dart';
import '../prefs.dart' as prefs;
import '../store.dart';
import '../transcript.dart';

/// Confirmation for an action that cannot be undone, with a red [action]
/// button. True only if the user confirms.
Future<bool> confirmIrreversible(
  BuildContext context,
  String title,
  String content,
  String action,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(
        '$content. ${tr('No se puede deshacer', 'This cannot be undone')}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('Cancelar', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Snackbar with [msg] and, if [retry] is set, a "Retry" action that runs it.
/// It times out like any other: the error stays in the app, not on screen.
SnackBar snackBar(String msg, {VoidCallback? retry}) => SnackBar(
  content: Text(msg),
  persist: false,
  action: retry == null
      ? null
      : SnackBarAction(label: tr('Reintentar', 'Retry'), onPressed: retry),
);

/// Centered icon, [title] and [hint] for a screen with nothing to list yet,
/// and the [action] that fills it, if any.
Widget emptyState(
  ThemeData theme,
  IconData icon,
  String title,
  String hint, {
  Widget? action,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: theme.colorScheme.tertiary),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            hint,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 16), action],
        ],
      ),
    ),
  );
}

/// One recording: audio player on top, then its transcript or a placeholder.
/// Transcribing happens here, so it works the same for new and old audios.
class TranscriptScreen extends StatefulWidget {
  const TranscriptScreen({
    super.key,
    required this.audioPath,
    required this.createdAt,
    required this.modelDir,
    this.saved,
    this.autoTranscribe = false,
  });

  final String audioPath;
  final DateTime createdAt;
  final String modelDir;
  final SavedTranscript? saved;

  /// Opens the speaker-count dialog right away (used by imports and shares).
  final bool autoTranscribe;

  @override
  State<TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends State<TranscriptScreen> {
  late SavedTranscript? _saved = widget.saved;
  Transcript? get _t => _saved?.transcript;
  String get _title =>
      _t?.title ?? audioTitle(widget.audioPath, widget.createdAt);

  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  bool _hasAudio = false;
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  bool _busy = false;
  double _progress = 0;
  String _status = '';
  String _eta = '';

  /// Clears the "transcription finished" notification once the user is back.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!_busy) BackgroundService.stop();
      },
    );
    shareWaiting.addListener(_closeForShare);
    _initPlayer();
    if (widget.autoTranscribe) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _transcribe());
    }
  }

  /// A share arrived: back to Home, which imports it. A running
  /// transcription finishes first (its turn), then this runs from _transcribe.
  /// An open dialog is never cut: this runs again once it closes, see
  /// didChangeDependencies.
  void _closeForShare() {
    if (shareWaiting.value &&
        !_busy &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).pop();
    }
  }

  // ModalRoute.of makes this run when a dialog on top opens or closes. After
  // the frame: the code that awaited the dialog may open another one first.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _closeForShare());
  }

  @override
  void dispose() {
    shareWaiting.removeListener(_closeForShare);
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  // ── Player ────────────────────────────────────────────────────────────

  Future<void> _initPlayer() async {
    if (!await File(widget.audioPath).exists() || !mounted) return;
    // The file exists, so it can be transcribed even if the player rejects
    // it (a WAV with a broken header, which readWavMono still reads).
    setState(() => _hasAudio = true);
    _subs.addAll([
      _player.onPlayerStateChanged.listen(
        (s) => setState(() => _playing = s == PlayerState.playing),
      ),
      _player.onPositionChanged.listen((d) => setState(() => _pos = d)),
      _player.onDurationChanged.listen((d) => setState(() => _dur = d)),
    ]);
    // Keep the source loaded after it ends, so play works again.
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(DeviceFileSource(widget.audioPath));
    } catch (_) {
      // Unplayable: the slider stays disabled (duration 0).
    }
  }

  Future<void> _togglePlay() async {
    try {
      await (_playing ? _player.pause() : _player.resume());
    } catch (_) {
      _snack(
        tr('No se puede reproducir este audio', 'This audio cannot be played'),
      );
    }
  }

  // ── Transcription ─────────────────────────────────────────────────────

  /// Returns the speaker count (1..6), or null if cancelled. [rate] is the
  /// audio's sample rate, to warn when it is phone-call quality. [estimate]
  /// is the expected run time in seconds (0 if unknown).
  Future<int?> _askSpeakers(int? rate, double estimate) async {
    var n = prefs.lastSpeakers;
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
            tr(
              '¿Cuántas personas participan?',
              'How many people are speaking?',
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var v = 1; v <= 6; v++)
                    ChoiceChip(
                      label: Text('$v'),
                      selected: n == v,
                      onSelected: (_) => setLocal(() => n = v),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                n == 1
                    ? tr(
                        'Una sola voz: todo el texto va a una persona. '
                            'Para dictados o monólogos',
                        'One voice: all text goes to one speaker. '
                            'For dictation or monologues',
                      )
                    : tr(
                        'Elige el número exacto. Si pones de más, aparece una '
                            'persona que no existe. Si pones de menos, se '
                            'mezclan voces',
                        'Pick the exact number. Too many and a person who '
                            "isn't there appears. Too few and voices get "
                            'mixed up',
                      ),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              if (estimate > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${tr('Tiempo estimado', 'Estimated time')}: '
                  '${formatEta(estimate)}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              if (rate != null && rate < lowQualityRate) ...[
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Audio de baja calidad. La transcripción podría tener más '
                        'errores',
                    'Low quality audio. The transcript may have more mistakes',
                  ),
                  // A warning: error, since tertiary is soft for some seeds.
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ],
              if (_t != null) ...[
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Se reemplazará el texto actual y sus ediciones. '
                        'Los nombres de las personas se conservan',
                    'The current text and its edits will be replaced. '
                        'Participant names are kept',
                  ),
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Cancelar', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, n),
              child: Text(tr('Transcribir', 'Transcribe')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _transcribe() async {
    var audioSeconds = 0.0;
    try {
      audioSeconds = await audioDurationSeconds(widget.audioPath);
    } catch (_) {
      // Unknown length: no estimate, the live one still appears.
    }
    final needsDecode = p.extension(widget.audioPath) != '.wav';
    final pipelinePrior =
        audioSeconds * prefs.rtf(models.rtfKey, models.defaultRtf);
    final decodePrior = needsDecode
        ? audioSeconds * prefs.rtf('decode', models.defaultDecodeRtf)
        : 0.0;
    final numSpeakers = await _askSpeakers(
      await audioSampleRate(widget.audioPath),
      pipelinePrior + decodePrior,
    );
    if (numSpeakers == null || !mounted) return;
    prefs.lastSpeakers = numSpeakers;
    await BackgroundService.requestNotificationPermission();
    try {
      await BackgroundService.start(
        BackgroundWork.processing,
        tr('Transcribiendo...', 'Transcribing...'),
      );
    } catch (_) {
      _snack(
        tr(
          'No se pudo iniciar la transcripción',
          'Could not start transcription',
        ),
        retry: _transcribe,
      );
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = tr('Preparando audio...', 'Preparing audio...');
      _eta = '';
    });
    var notifiedPercent = -1;
    // Imported .opus/.ogg/.m4a: transcribed from a temporary WAV, the
    // original stays as it is.
    String? decoded;
    // Seconds spent turning .m4a/.opus into WAV, outside the pipeline.
    var decodeSeconds = 0.0;
    String? decodeDetail;

    // Times the pipeline alone, the part _progress measures.
    // ponytail: no ETA during the .m4a/.opus conversion (no progress there);
    // the dialog already showed its share.
    final clock = Stopwatch();

    try {
      var wav = widget.audioPath;
      if (needsDecode) {
        decoded = p.join((await getTemporaryDirectory()).path, 'decoded.wav');
        final decodeClock = Stopwatch()..start();
        decodeDetail = await decodeToWav(wav, decoded);
        decodeSeconds = decodeClock.elapsedMilliseconds / 1000;
        wav = decoded;
      }
      clock.start();
      final result = await runPipeline(
        wavPath: wav,
        modelDir: widget.modelDir,
        numSpeakers: numSpeakers,
        onProgress: (pr) {
          if (!mounted) return;
          setState(() {
            // Approximate weight of each stage in the total time, measured with
            // Parakeet on a 697.6 s interview (2026-10-24): diarization ~39 %,
            // ASR ~61 %.
            switch (pr.stage) {
              case Stage.loading:
                _progress = 0;
                _status = tr('Preparando audio...', 'Preparing audio...');
              case Stage.diarization:
                _progress = 0.02 + 0.37 * pr.fraction;
                _status = numSpeakers == 1
                    ? tr('Escuchando el audio...', 'Listening to the audio...')
                    : tr(
                        'Reconociendo las voces...',
                        'Recognizing the voices...',
                      );
              case Stage.transcription:
                _progress = 0.39 + 0.61 * pr.fraction;
                _status = tr('Transcribiendo...', 'Transcribing...');
            }
            // Without a prior the live pace is noise for the first 5 %.
            _eta = pipelinePrior > 0 || _progress >= 0.05
                ? formatEta(
                    etaSeconds(
                      clock.elapsedMilliseconds / 1000,
                      _progress,
                      pipelinePrior,
                    ),
                  )
                : '';
          });
          final percent = (_progress * 100).floor();
          if (percent != notifiedPercent) {
            notifiedPercent = percent;
            BackgroundService.update(
              '${tr('Transcribiendo', 'Transcribing')} - $percent %'
              '${_eta.isEmpty ? '' : ' - $_eta'}',
            );
          }
        },
      );

      clock.stop();
      if (result.turns.isEmpty) {
        _snack(
          tr(
            'No se detectó voz en la grabación',
            'No speech was detected in the recording',
          ),
        );
        return;
      }
      final transcript = Transcript(
        title: _title,
        createdAt: widget.createdAt,
        audioPath: widget.audioPath,
        durationSeconds: result.durationSeconds,
        turns: result.turns,
      );
      // Keep the names already set. Speakers are numbered by order of
      // appearance, so index 0 is still whoever spoke first.
      // ponytail: if the new run splits voices differently, a name can land
      // on the wrong person; the user renames with the people button.
      final oldNames = _t?.speakerNames ?? const <String>[];
      for (
        var i = 0;
        i < oldNames.length && i < transcript.speakerNames.length;
        i++
      ) {
        transcript.speakerNames[i] = oldNames[i];
      }
      _saved = await saveTranscript(transcript, jsonPath: _saved?.jsonPath);
      final audio = result.durationSeconds;
      await prefs.recordRtf(
        models.rtfKey,
        clock.elapsedMilliseconds / 1000 / audio,
        models.defaultRtf,
      );
      if (decodeSeconds > 0) {
        await prefs.recordRtf(
          'decode',
          decodeSeconds / audio,
          models.defaultDecodeRtf,
        );
      }
      _showTimings(result, numSpeakers, decodeSeconds, decodeDetail);
    } catch (e) {
      // FormatException carries a message meant for the user, and the
      // same audio would fail again: no retry.
      if (e is FormatException) {
        _snack(e.message);
      } else {
        _snack(
          tr(
            'No se pudo transcribir el audio',
            'Could not transcribe the audio',
          ),
          retry: _transcribe,
        );
      }
    } finally {
      if (decoded != null) {
        try {
          await File(decoded).delete();
        } catch (_) {}
      }
      // Away from the app: keep the notification (without the wake lock) so
      // it says the work is done. Tapping it reopens the app on this screen
      // and onResume stops the service.
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        await BackgroundService.stop();
      } else {
        await BackgroundService.finish(
          tr(
            'Transcripción terminada. Toca para abrirla',
            'Transcription finished. Tap to open it',
          ),
        );
      }
      if (mounted) setState(() => _busy = false);
      _closeForShare();
    }
  }

  /// What each stage took and found, to tune models and settings. Only in
  /// debug and profile builds: users never see it. Written so it can be
  /// pasted as is, with every number labeled.
  void _showTimings(
    PipelineResult r,
    int requested,
    double decodeSeconds,
    String? decodeDetail,
  ) {
    if (kReleaseMode) return;
    final t = r.timings;
    String s(double v) => '${v.toStringAsFixed(1)} s';
    // Distinct speakers after stage [i]; the last is missing with no speech.
    String speakers(int i) =>
        i < t.speakerStages.length ? '${t.speakerStages[i]}' : '-';
    final total = t.loading + t.diarization + t.transcription;
    final text = [
      'Scrita timing summary (${kDebugMode ? 'debug build: times are '
                'several times slower than release' : 'profile build: '
                'times match release'})',
      'models: parakeet-v3 (ASR) + titanet-small (speaker embedding), '
          '${models.numThreads} threads',
      'audio ${s(r.durationSeconds)}, pipeline ${s(total)} '
          '(${(total / r.durationSeconds).toStringAsFixed(2)} s per audio second)',
      if (decodeSeconds > 0)
        'convert to WAV ${s(decodeSeconds)}: ${decodeDetail ?? '-'}',
      'stages: load WAV ${s(t.loading)}, diarization ${s(t.diarization)} '
          '(of which regrouping ${s(t.regroup)}), transcription '
          '${s(t.transcription)}',
      'transcription: recognizer setup ${s(t.asrSetup)}, voice detection '
          '${s(t.vad)}, decoding ${s(t.decode)} (${t.phraseAudio > 0 ? (t.decode / t.phraseAudio).toStringAsFixed(2) : '-'} s per phrase second)',
      'speakers: $requested requested; distinct after diarization '
          '${speakers(0)}, after building turns ${speakers(1)}, after '
          'regrouping ${speakers(2)}, in final text ${speakers(3)}',
      'diarization: ${t.overlaps} overlaps at speaker changes '
          '(${s(t.overlapSeconds)}), ${t.droppedTurns} speaker turns with '
          'no detected speech',
      'voice detection (threshold ${models.vadThreshold}, pause '
          '${models.vadMinSilence} s ends a phrase, cap '
          '${models.vadMaxSpeech} s): ${t.phrases} phrases decoded '
          '(${s(t.phraseAudio)}), ${t.skipped} under 0.3 s skipped, '
          '${t.short} between 0.3 and 0.5 s, longest ${s(t.longest)}, '
          '${t.atCap} within 0.5 s of the cap, ${t.empty} decoded to no '
          'text (${s(t.emptyAudio)})',
      'per-word speakers: ${t.timestamped}/${t.phrases} phrases with word '
          'timestamps, ${t.crossing} phrases overlapping 2+ speakers by '
          '0.5 s or more, ${t.split} phrases split between speakers',
    ].join('\n');
    debugPrint(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 20),
        showCloseIcon: true,
        action: SnackBarAction(
          label: 'Copy',
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
        ),
      ),
    );
  }

  /// [retry] adds a "Retry" action that runs it.
  void _snack(String msg, {VoidCallback? retry}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(snackBar(msg, retry: retry));
  }

  // ── Transcript editing (only when _t != null) ─────────────────────────

  Future<void> _persist() async {
    _saved = await saveTranscript(_t!, jsonPath: _saved!.jsonPath);
    if (mounted) setState(() {});
  }

  Future<void> _renameSpeakers() async {
    final t = _t!;
    final controllers = [
      for (final n in t.speakerNames) TextEditingController(text: n),
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Nombres de las personas', 'Participant names')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < controllers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: controllers[i],
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: defaultSpeakerName(i),
                      prefixIcon: Icon(Icons.person, color: _color(i)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancelar', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Guardar', 'Save')),
          ),
        ],
      ),
    );
    if (ok == true) {
      for (var i = 0; i < controllers.length; i++) {
        final name = controllers[i].text.trim();
        t.speakerNames[i] = name.isEmpty ? defaultSpeakerName(i) : name;
      }
      await _persist();
    }
    for (final c in controllers) {
      c.dispose();
    }
  }

  /// Gives the selected text of turns[index] to [speaker], splitting the
  /// turn where needed. No confirmation: the snackbar offers undo instead.
  Future<void> _assignRange(int index, int from, int to, int speaker) async {
    final t = _t!;
    final before = [...t.turns];
    final out = assignRange(t.turns, index, from, to, speaker);
    t.turns
      ..clear()
      ..addAll(out);
    await _persist();
    _showUndo(
      tr(
        'Texto asignado a ${t.speakerName(speaker)}',
        'Text assigned to ${t.speakerName(speaker)}',
      ),
      before,
    );
  }

  /// Lets the user fix a turn's text or reassign it to another speaker.
  /// [selection] comes from "Edit" in the selection menu and is kept.
  Future<void> _editTurn(int index, {TextSelection? selection}) async {
    final t = _t!;
    final turn = t.turns[index];
    final controller = TextEditingController(text: turn.text);
    if (selection != null) controller.selection = selection;
    var speaker = turn.speaker;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
            '${tr('Párrafo', 'Paragraph')} ${formatTimestamp(turn.start)}',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: speaker,
                  decoration: InputDecoration(
                    labelText: tr('Persona', 'Speaker'),
                  ),
                  items: [
                    for (var i = 0; i < t.speakerNames.length; i++)
                      DropdownMenuItem(value: i, child: Text(t.speakerName(i))),
                  ],
                  onChanged: (v) => setLocal(() => speaker = v ?? speaker),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: selection != null,
                  maxLines: null,
                  minLines: 3,
                  decoration: InputDecoration(
                    labelText: tr('Texto', 'Text'),
                    border: OutlineInputBorder(),
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
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Guardar', 'Save')),
            ),
          ],
        ),
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (ok != true || !mounted) return;

    final before = [...t.turns];
    final speakerChanged = text.isNotEmpty && speaker != turn.speaker;
    final edited = [...t.turns]
      ..[index] = Turn(
        start: turn.start,
        end: turn.end,
        speaker: speaker,
        text: text,
      );
    // Same cleanup as a fresh transcript: an empty turn is dropped and
    // adjacent turns of one speaker merge. A speaker change gets undo
    // instead of a confirmation; otherwise ask, cancelling discards the edit.
    final cleaned = cleanTurns(edited);
    if (!speakerChanged && cleaned.length < t.turns.length) {
      final name = t.speakerName(speaker);
      final confirmed = await (text.isEmpty
          ? confirmIrreversible(
              context,
              tr('¿Eliminar párrafo?', 'Delete paragraph?'),
              // The turns around it share a speaker: they merge once this
              // one is gone.
              index > 0 &&
                      index < t.turns.length - 1 &&
                      t.turns[index - 1].speaker == t.turns[index + 1].speaker
                  ? tr(
                      'Dejaste el texto vacío, así que se borrará este '
                          'párrafo. Los párrafos de '
                          '${t.speakerName(t.turns[index - 1].speaker)} '
                          'de antes y después se juntarán',
                      'You left the text empty, so this paragraph will be '
                          'deleted. The paragraphs of '
                          '${t.speakerName(t.turns[index - 1].speaker)} '
                          'before and after it will be joined',
                    )
                  : tr(
                      'Dejaste el texto vacío, así que se borrará este párrafo',
                      'You left the text empty, so this paragraph will be deleted',
                    ),
              tr('Eliminar', 'Delete'),
            )
          : confirmIrreversible(
              context,
              tr('¿Juntar párrafos?', 'Join paragraphs?'),
              tr(
                'Se juntará con el párrafo de $name que tiene al lado',
                'It will be joined with the paragraph of $name next to it',
              ),
              tr('Juntar', 'Join'),
            ));
      if (!confirmed) return;
    }
    t.turns
      ..clear()
      ..addAll(cleaned);
    await _persist();
    if (speakerChanged) {
      _showUndo(
        tr(
          'Párrafo asignado a ${t.speakerName(speaker)}',
          'Paragraph assigned to ${t.speakerName(speaker)}',
        ),
        before,
      );
    }
  }

  /// Snackbar with an undo that restores [before] as the turn list.
  void _showUndo(String msg, List<Turn> before) {
    if (!mounted) return;
    final t = _t!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          action: SnackBarAction(
            label: tr('Deshacer', 'Undo'),
            onPressed: () {
              t.turns
                ..clear()
                ..addAll(before);
              _persist();
            },
          ),
        ),
      );
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(_saved!.txtPath, mimeType: 'text/plain')],
          fileNameOverrides: ['${exportName(_saved!)}.txt'],
          subject: _t!.title,
        ),
      );
    } catch (_) {
      _snack(tr('No se pudo compartir', 'Could not share'), retry: _share);
    }
  }

  Future<void> _saveToDocuments() async {
    var text = prefs.saveText;
    var audio = prefs.saveAudio;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('Guardar en Documentos', 'Save to Documents')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(
                  'Se guarda en Documentos/Scrita',
                  'It is saved to Documents/Scrita',
                ),
              ),
              CheckboxListTile(
                value: text,
                onChanged: (v) => setLocal(() => text = v ?? text),
                title: Text(tr('Texto', 'Text')),
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: audio,
                onChanged: (v) => setLocal(() => audio = v ?? audio),
                title: Text(tr('Audio', 'Audio')),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Cancelar', 'Cancel')),
            ),
            FilledButton(
              onPressed: text || audio ? () => Navigator.pop(ctx, true) : null,
              child: Text(tr('Guardar', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    prefs.saveText = text;
    prefs.saveAudio = audio;
    final ext = p.extension(widget.audioPath);
    if (audio && exportAudioExt(widget.audioPath) != ext) {
      _snack(tr('Guardando el audio...', 'Saving the audio...'));
    }
    var ok = true;
    try {
      await exportToDocuments(_saved!, text: text, audio: audio);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    // Replaces "Saving the audio..." instead of queueing behind it.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ok
        ? _snack(
            tr(
              'Guardado en Documentos › Scrita',
              'Saved to Documents › Scrita',
            ),
          )
        : _snack(
            tr(
              'No se pudo guardar en Documentos',
              'Could not save to Documents',
            ),
            retry: _saveToDocuments,
          );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _t!.toPlainText()));
    // Android 13+ shows its own notice.
    if (await sdkInt() < 33) _snack(tr('Texto copiado', 'Text copied'));
  }

  /// Speaker name and dot. The 500 shades fail 4.5:1 text contrast in light
  /// or dark mode, so each mode takes a shade that passes on its surface.
  /// Light mode uses 700, not 900: the 900s are near black and look alike.
  /// deepOrange 700 is 3.7:1, so it keeps 900.
  /// Harmonized toward the theme's primary: rotates the hue, keeps the tone,
  /// so the contrast holds.
  Color _color(int speaker) {
    const palette = <MaterialColor>[
      Colors.indigo,
      Colors.teal,
      Colors.deepOrange,
      Colors.purple,
      Colors.brown,
      Colors.pink,
    ];
    final c = palette[speaker % palette.length];
    final theme = Theme.of(context);
    final light = c == Colors.deepOrange ? c.shade900 : c.shade700;
    return (theme.brightness == Brightness.dark ? c.shade200 : light)
        .harmonizeWith(theme.colorScheme.primary);
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _t != null && !_busy;
    // While transcribing, navigation is locked: a disabled back arrow, and the
    // system back button minimizes the app (the work keeps going in the
    // foreground service) instead of leaving this screen.
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) FlutterForegroundTask.minimizeApp();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _busy
              ? const IconButton(icon: BackButtonIcon(), onPressed: null)
              : null,
          title: Text(_title, overflow: TextOverflow.ellipsis),
          // Material 3 caps the bar at three actions: the rest go in the menu.
          actions: [
            if (ready) ...[
              IconButton(
                icon: const Icon(Icons.people_outline),
                tooltip: tr('Nombrar personas', 'Name participants'),
                onPressed: _renameSpeakers,
              ),
              IconButton(
                icon: const Icon(Icons.share),
                tooltip: tr('Compartir texto', 'Share text'),
                onPressed: _share,
              ),
              // onSelected runs once the menu is closed, so a dialog it opens
              // is not popped along with it.
              PopupMenuButton<VoidCallback>(
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  _menuItem(Icons.copy, tr('Copiar texto', 'Copy text'), _copy),
                  _menuItem(
                    Icons.save_alt,
                    tr('Guardar en Documentos', 'Save to Documents'),
                    _saveToDocuments,
                  ),
                  if (_hasAudio)
                    _menuItem(
                      Icons.refresh,
                      tr('Volver a transcribir', 'Transcribe again'),
                      _transcribe,
                    ),
                ],
              ),
            ],
          ],
        ),
        // Controls in the footer, as on Home. The body ends above it.
        bottomNavigationBar: appFooter(
          theme,
          _busy ? _buildProgress() : _buildPlayer(theme),
        ),
        body: _t == null
            ? emptyState(
                theme,
                Icons.description_outlined,
                tr('Aún no hay transcripción', 'No transcript yet'),
                tr(
                  'Convierte la grabación en texto con el nombre de cada '
                      'persona',
                  'Turn the recording into text with each speaker named',
                ),
                action: FilledButton.icon(
                  onPressed: _hasAudio && !_busy ? _transcribe : null,
                  icon: const Icon(Icons.text_snippet_outlined),
                  label: Text(tr('Transcribir', 'Transcribe')),
                ),
              )
            : _buildTurns(theme),
      ),
    );
  }

  PopupMenuItem<VoidCallback> _menuItem(
    IconData icon,
    String label,
    VoidCallback action,
  ) => PopupMenuItem(
    value: action,
    child: ListTile(
      leading: Icon(icon),
      title: Text(label),
      contentPadding: EdgeInsets.zero,
    ),
  );

  Widget _buildPlayer(ThemeData theme) {
    if (!_hasAudio) {
      return Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(tr('Audio no disponible', 'Audio not available')),
        ],
      );
    }
    final max = _dur.inMilliseconds;
    return Row(
      children: [
        IconButton.filled(
          iconSize: 32,
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          tooltip: _playing ? tr('Pausar', 'Pause') : tr('Reproducir', 'Play'),
          onPressed: _togglePlay,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Slider(
                value: _pos.inMilliseconds.clamp(0, max).toDouble(),
                max: max > 0 ? max.toDouble() : 1,
                // M3's secondaryContainer vanishes on the footer's
                // surfaceContainerHigh; outline keeps 3:1 on every seed.
                inactiveColor: theme.colorScheme.outline,
                onChanged: max > 0
                    ? (v) => _player.seek(Duration(milliseconds: v.round()))
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Text(
                  '${formatTimestamp(_pos.inSeconds.toDouble())} / '
                  '${formatTimestamp(_dur.inSeconds.toDouble())}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(value: _progress),
        const SizedBox(height: 8),
        Text(
          '$_status - ${(_progress * 100).toStringAsFixed(0)} %'
          '${_eta.isEmpty ? '' : ' - $_eta'}',
        ),
      ],
    );
  }

  Widget _buildTurns(ThemeData theme) {
    final t = _t!;
    return ListView.separated(
      // The footer takes the navigation bar inset.
      padding: const EdgeInsets.fromLTRB(16, 36, 16, 36),
      itemCount: t.turns.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, i) {
        final turn = t.turns[i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _busy ? null : () => _editTurn(i),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 5,
                      backgroundColor: _color(turn.speaker),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t.speakerName(turn.speaker),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: _color(turn.speaker),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatTimestamp(turn.start),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Selecting text gives "Assign to <speaker>" and "Edit", to
                // fix a turn where diarization mixed two voices.
                SelectableText(
                  turn.text,
                  style: theme.textTheme.bodyLarge,
                  onTap: _busy ? null : () => _editTurn(i),
                  contextMenuBuilder: (ctx, state) {
                    final sel = state.textEditingValue.selection;
                    void run(VoidCallback f) {
                      state.hideToolbar();
                      f();
                    }

                    return AdaptiveTextSelectionToolbar.buttonItems(
                      anchors: state.contextMenuAnchors,
                      buttonItems: [
                        if (!_busy && !sel.isCollapsed) ...[
                          for (var s = 0; s < t.speakerNames.length; s++)
                            if (s != turn.speaker)
                              ContextMenuButtonItem(
                                label: tr(
                                  'Asignar a ${t.speakerName(s)}',
                                  'Assign to ${t.speakerName(s)}',
                                ),
                                onPressed: () => run(
                                  () => _assignRange(i, sel.start, sel.end, s),
                                ),
                              ),
                          ContextMenuButtonItem(
                            label: tr('Editar', 'Edit'),
                            onPressed: () =>
                                run(() => _editTurn(i, selection: sel)),
                          ),
                        ],
                        ...state.contextMenuButtonItems,
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
