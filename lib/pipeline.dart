// Interview processing in a separate isolate, so the UI is not blocked:
//
//   WAV → diarization (who speaks and when)
//       → regrouping with one embedding per turn (2+ speakers)
//       → VAD over the whole recording: phrases cut at pauses → ASR
//       → each word takes the speaker of the turns it overlaps most, and the
//         phrase splits where the speaker changes
//       → list of turns with text
//
// All FFI work (sherpa-onnx) happens inside the isolate.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'l10n.dart';
import 'models.dart' as models;
import 'transcript.dart';

/// Stages reported to the UI.
enum Stage { loading, diarization, transcription }

class PipelineProgress {
  const PipelineProgress(this.stage, this.fraction);
  final Stage stage;
  final double fraction; // 0..1 within the stage
}

class PipelineResult {
  const PipelineResult(this.turns, this.durationSeconds, this.timings);
  final List<Turn> turns;
  final double durationSeconds;
  final StageTimings timings;
}

/// Where the time goes and what each stage found, for the timing summary
/// that non-release builds show after a transcription.
class StageTimings {
  /// Reading and resampling the WAV (seconds).
  double loading = 0;

  /// Diarization, regrouping included (seconds).
  double diarization = 0;

  /// Part of [diarization] spent in regrouping (seconds).
  double regroup = 0;

  /// Distinct speakers after each stage: diarization clusters, buildTurns,
  /// regrouping, final text. Shows where a voice gets lost.
  final speakerStages = <int>[];

  /// Diarization segments that start before the previous one (another
  /// speaker) ends, and the seconds they overlap.
  int overlaps = 0;
  double overlapSeconds = 0;

  /// Diarization turns no VAD phrase touches (speech the VAD did not hear).
  int droppedTurns = 0;

  /// Creating the recognizer and the VAD (seconds).
  double asrSetup = 0;

  /// The VAD pass over the whole recording (seconds).
  double vad = 0;

  /// recognizer.decode (seconds).
  double decode = 0;

  /// Phrases sent to the recognizer, and their audio (seconds).
  int phrases = 0;
  double phraseAudio = 0;

  /// Phrases under 0.3 s (not decoded) and between 0.3 and 0.5 s.
  int skipped = 0;
  int short = 0;

  /// Longest phrase (seconds), and phrases within 0.5 s of the VAD cap. Past
  /// the cap sherpa-onnx ends the phrase at the first 0.1 s dip in speech
  /// probability, which can be mid-word.
  double longest = 0;
  int atCap = 0;

  /// Phrases decoded to no text, and their audio (seconds).
  int empty = 0;
  double emptyAudio = 0;

  /// Checks for per-word speakers: phrases with one timestamp per token,
  /// phrases that overlap 2+ speakers by 0.5 s or more each, and phrases
  /// splitPhrase cut into 2+ runs.
  int timestamped = 0;
  int crossing = 0;
  int split = 0;

  /// Transcription total (seconds): setup, VAD, decode and splitting.
  double transcription = 0;
}

/// Processes [wavPath] with exactly [numSpeakers] voices (>= 1).
/// Progress arrives through [onProgress]; the result, through the Future.
Future<PipelineResult> runPipeline({
  required String wavPath,
  required String modelDir,
  required int numSpeakers,
  void Function(PipelineProgress)? onProgress,
}) async {
  final port = ReceivePort();
  final completer = Completer<PipelineResult>();

  final isolate = await Isolate.spawn(
    _entry,
    _Request(port.sendPort, wavPath, modelDir, numSpeakers, uiSpanish),
    onError: port.sendPort,
    onExit: port.sendPort,
  );

  port.listen((msg) {
    if (msg is PipelineProgress) {
      onProgress?.call(msg);
    } else if (msg is PipelineResult) {
      completer.complete(msg);
    } else if (msg is _Failure) {
      // FormatException carries a message meant for the user.
      completer.completeError(
        msg.forUser ? FormatException(msg.message) : Exception(msg.message),
      );
    } else if (msg is List && !completer.isCompleted) {
      // Uncaught isolate error: [message, stacktrace].
      completer.completeError(Exception(msg.first));
    } else if (msg == null && !completer.isCompleted) {
      // The isolate exited without replying (e.g. out of memory).
      completer.completeError(
        FormatException(
          tr(
            'La transcripción se detuvo. Cierra otras apps y vuelve a intentarlo',
            'Transcription stopped. Close other apps and try again',
          ),
        ),
      );
    }
  });

  try {
    return await completer.future;
  } finally {
    port.close();
    isolate.kill();
  }
}

class _Request {
  const _Request(
    this.port,
    this.wavPath,
    this.modelDir,
    this.numSpeakers,
    this.spanish,
  );
  final SendPort port;
  final String wavPath;
  final String modelDir;
  final int numSpeakers;

  /// The isolate starts with fresh globals, so the language travels here.
  final bool spanish;
}

class _Failure {
  const _Failure(this.message, this.forUser);
  final String message;
  final bool forUser;
}

Future<void> _entry(_Request req) async {
  uiSpanish = req.spanish;
  try {
    final result = await _process(req, (p) => req.port.send(p));
    req.port.send(result);
  } catch (e) {
    req.port.send(
      e is FormatException
          ? _Failure(e.message, true)
          : _Failure(e.toString(), false),
    );
  }
}

Future<PipelineResult> _process(
  _Request req,
  void Function(PipelineProgress) report,
) async {
  final t = StageTimings();
  final clock = Stopwatch()..start();
  double lap() {
    final s = clock.elapsedMicroseconds / 1e6;
    clock.reset();
    return s;
  }

  // Times one piece without touching the stage clock.
  final part = Stopwatch();
  R timed<R>(R Function() f, void Function(double) add) {
    part
      ..reset()
      ..start();
    final r = f();
    add(part.elapsedMicroseconds / 1e6);
    return r;
  }

  int count(Iterable<int> ids) => ids.toSet().length;

  await sherpa_onnx.initBindingsAsync();

  report(const PipelineProgress(Stage.loading, 0));
  final samples = _readWav(req.wavPath);
  if (samples.isEmpty) {
    throw FormatException(tr('El audio está vacío', 'The audio is empty'));
  }
  final duration = samples.length / models.sampleRate;
  t.loading = lap();

  // 1) Diarization over the whole recording, also with one speaker. With
  // 2+ speakers it asks for extra clusters and regroups them down to the
  // real count (see regroupSpeakers).
  report(const PipelineProgress(Stage.diarization, 0));
  final multi = req.numSpeakers > 1;
  final extra = duration >= models.extraClustersMinAudio
      ? models.extraClusters
      : 0;
  final segments = _diarize(
    req,
    samples,
    multi ? req.numSpeakers + extra : 1,
    report,
  );
  t.speakerStages.add(count(segments.map((s) => s.speaker)));
  // Overlaps at speaker changes, which buildTurns splits in half.
  final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < sorted.length; i++) {
    final a = sorted[i - 1], b = sorted[i];
    if (a.speaker != b.speaker && b.start < a.end && b.end > a.end) {
      t.overlaps++;
      t.overlapSeconds += a.end - b.start;
    }
  }
  var turns = buildTurns(segments);
  t.speakerStages.add(count(turns.map((x) => x.speaker)));
  if (multi) {
    turns = timed(() => _regroup(req, samples, turns), (s) => t.regroup = s);
  }
  t.speakerStages.add(count(turns.map((x) => x.speaker)));
  t.diarization = lap();
  if (turns.isEmpty) return PipelineResult(const [], duration, t);

  // 2) Transcription. The VAD runs over the whole recording, so phrases end
  // at real pauses and not at turn boundaries, which cut questions and words
  // in two. Each phrase is decoded whole (context, punctuation) and then split
  // by word timestamps where the speaker changes (splitPhrase).
  part
    ..reset()
    ..start();
  final recognizer = sherpa_onnx.OfflineRecognizer(
    models.buildAsrConfig(req.modelDir),
  );
  final vadConfig = models.buildVadConfig(req.modelDir);
  final vad = sherpa_onnx.VoiceActivityDetector(
    config: vadConfig,
    bufferSizeInSeconds: 60,
  );
  final window = vadConfig.sileroVad.windowSize;
  t.asrSetup = part.elapsedMicroseconds / 1e6;

  final phrases = <Turn>[];
  try {
    void drain() {
      while (!vad.isEmpty()) {
        // start counts samples since the VAD was created (never reset here).
        final seg = vad.front();
        vad.pop();
        final start = seg.start / models.sampleRate;
        final seconds = seg.samples.length / models.sampleRate;
        final end = start + seconds;
        if (seconds < _minPhrase) {
          t.skipped++;
          continue;
        }
        t.phrases++;
        t.phraseAudio += seconds;
        if (seconds < 0.5) t.short++;
        if (seconds >= models.vadMaxSpeech - 0.5) t.atCap++;
        t.longest = math.max(t.longest, seconds);

        final r = timed(
          () => _decode(recognizer, seg.samples),
          (s) => t.decode += s,
        );
        if (r.tokens.isNotEmpty && r.timestamps.length == r.tokens.length) {
          t.timestamped++;
        }
        final heard = {
          for (final x in turns)
            if (math.min(x.end, end) - math.max(x.start, start) >= 0.5)
              x.speaker,
        };
        if (heard.length > 1) t.crossing++;
        final text = r.text.trim();
        if (text.isNotEmpty) {
          final parts = splitPhrase(
            turns,
            start,
            end,
            text,
            r.tokens,
            r.timestamps,
          );
          if (parts.length > 1) t.split++;
          phrases.addAll(parts);
        } else {
          t.empty++;
          t.emptyAudio += seconds;
        }
        report(
          PipelineProgress(Stage.transcription, math.min(end / duration, 1)),
        );
      }
    }

    for (var i = 0; i + window <= samples.length; i += window) {
      timed(
        () =>
            vad.acceptWaveform(Float32List.sublistView(samples, i, i + window)),
        (s) => t.vad += s,
      );
      drain();
    }
    timed(vad.flush, (s) => t.vad += s);
    drain();
  } finally {
    vad.free();
    recognizer.free();
  }

  t.droppedTurns = turns
      .where((x) => !phrases.any((p) => p.start < x.end && p.end > x.start))
      .length;
  final result = cleanTurns(phrases);
  t.speakerStages.add(count(result.map((x) => x.speaker)));
  t.transcription = lap();
  return PipelineResult(result, duration, t);
}

typedef _Segment = ({double start, double end, int speaker});

List<_Segment> _diarize(
  _Request req,
  Float32List samples,
  int clusters,
  void Function(PipelineProgress) report,
) {
  final sd = sherpa_onnx.OfflineSpeakerDiarization(
    models.buildDiarizationConfig(req.modelDir, numSpeakers: clusters),
  );
  try {
    return [
      for (final s in sd.processWithCallback(
        samples: samples,
        callback: (done, total) {
          report(
            PipelineProgress(Stage.diarization, total == 0 ? 0 : done / total),
          );
          return 0; // 0 = continue
        },
      ))
        (start: s.start, end: s.end, speaker: s.speaker),
    ];
  } finally {
    sd.free();
  }
}

/// Merges the diarization clusters down to [_Request.numSpeakers] with one
/// embedding per turn, then rebuilds the turns so neighbours that now share a
/// speaker merge and speakers are renumbered by order of appearance.
List<Turn> _regroup(_Request req, Float32List samples, List<Turn> turns) {
  final ex = sherpa_onnx.SpeakerEmbeddingExtractor(
    config: models.buildEmbeddingConfig(req.modelDir),
  );
  final embeddings = <Float32List?>[];
  try {
    for (final t in turns) {
      if (t.duration < models.regroupMinTurn) {
        embeddings.add(null);
        continue;
      }
      final from = (t.start * models.sampleRate).round();
      final to = math.min((t.end * models.sampleRate).round(), samples.length);
      final stream = ex.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.sublistView(samples, from, to),
          sampleRate: models.sampleRate,
        );
        stream.inputFinished();
        embeddings.add(ex.isReady(stream) ? ex.compute(stream) : null);
      } finally {
        stream.free();
      }
    }
  } finally {
    ex.free();
  }

  final labels = regroupSpeakers(
    [for (final t in turns) t.speaker],
    embeddings,
    [for (final t in turns) t.duration],
    req.numSpeakers,
  );
  return buildTurns([
    for (var i = 0; i < turns.length; i++)
      (start: turns[i].start, end: turns[i].end, speaker: labels[i]),
  ]);
}

/// Phrases shorter than this (seconds) are not decoded.
const double _minPhrase = 0.3;

sherpa_onnx.OfflineRecognizerResult _decode(
  sherpa_onnx.OfflineRecognizer recognizer,
  Float32List audio,
) {
  final stream = recognizer.createStream();
  try {
    stream.acceptWaveform(samples: audio, sampleRate: models.sampleRate);
    recognizer.decode(stream);
    return recognizer.getResult(stream);
  } finally {
    stream.free();
  }
}

/// readWavMono with sherpa-onnx's resampler, created once the WAV's rate is
/// known (none for a 16 kHz WAV).
Float32List _readWav(String path) {
  _Resampler? resampler;
  try {
    return readWavMono(
      path,
      models.sampleRate,
      resample: (block, from, last) =>
          (resampler ??= _Resampler(from, models.sampleRate))(block, last),
    );
  } finally {
    resampler?.free();
  }
}

/// sherpa-onnx's resampler (Kaldi windowed-sinc low-pass, cutoff 0.99 x
/// Nyquist), through its C API: the Dart package does not wrap it. It keeps
/// filter state between blocks, so readWavMono can still read one second at
/// a time.
class _Resampler {
  _Resampler(int from, int to) : _p = _create(from, to, 0, 0) {
    if (_p == nullptr) throw StateError('No resampler for $from -> $to Hz');
  }

  // Same library the sherpa_onnx package loads on Android.
  static final _lib = DynamicLibrary.open('libsherpa-onnx-c-api.so');
  static final _create = _lib
      .lookupFunction<
        Pointer<Void> Function(Int32, Int32, Float, Int32),
        Pointer<Void> Function(int, int, double, int)
      >('SherpaOnnxCreateLinearResampler');
  static final _destroy = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('SherpaOnnxDestroyLinearResampler');
  static final _resample = _lib
      .lookupFunction<
        Pointer<_ResampleOut> Function(
          Pointer<Void>,
          Pointer<Float>,
          Int32,
          Int32,
        ),
        Pointer<_ResampleOut> Function(Pointer<Void>, Pointer<Float>, int, int)
      >('SherpaOnnxLinearResamplerResample');
  static final _freeOut = _lib
      .lookupFunction<
        Void Function(Pointer<_ResampleOut>),
        void Function(Pointer<_ResampleOut>)
      >('SherpaOnnxLinearResamplerResampleFree');

  final Pointer<Void> _p;

  Float32List call(Float32List block, bool last) {
    final input = calloc<Float>(math.max(block.length, 1));
    try {
      input.asTypedList(block.length).setAll(0, block);
      final r = _resample(_p, input, block.length, last ? 1 : 0);
      if (r == nullptr) throw StateError('Resampling failed');
      try {
        final n = r.ref.n;
        return n == 0
            ? Float32List(0)
            : Float32List.fromList(r.ref.samples.asTypedList(n));
      } finally {
        _freeOut(r);
      }
    } finally {
      calloc.free(input);
    }
  }

  void free() => _destroy(_p);
}

/// SherpaOnnxResampleOut in c-api.h.
final class _ResampleOut extends Struct {
  external Pointer<Float> samples;

  @Int32()
  external int n;
}
