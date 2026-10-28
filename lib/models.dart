// Model paths and construction of the sherpa-onnx configurations.
//
// The small models live in assets/models/ (downloaded by
// tool/fetch_models.dart) and are copied to internal storage the first time
// the app opens, because onnxruntime needs real paths on disk. Parakeet is
// too big for the APK: the app downloads it once from a GitHub release
// straight into that same folder.

import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'l10n.dart';

/// Threads for onnxruntime: the phone's big cores.
final int numThreads = _detectThreads();

int _detectThreads() {
  try {
    // Lists every cpuN folder, not Platform.numberOfProcessors: that one only
    // counts online cores, and idle phones switch their big cores off.
    final cpu = RegExp(r'^cpu\d+$');
    return threadsFor([
      for (final d in Directory('/sys/devices/system/cpu').listSync())
        if (cpu.hasMatch(p.basename(d.path)))
          int.parse(
            File(
              '${d.path}/cpufreq/cpuinfo_max_freq',
            ).readAsStringSync().trim(),
          ),
    ]);
  } catch (_) {
    return 2; // sysfs unreadable: safe on mid-range phones
  }
}

/// Cores faster than the slowest cluster (big + prime), capped at 4.
/// Little cores are never counted: ORT waits for its slowest thread on every
/// op, so one thread on a little core slows all of them down.
/// [maxFreqs] is the max frequency of each core.
int threadsFor(List<int> maxFreqs) {
  final slowest = maxFreqs.reduce(math.min);
  final big = maxFreqs.where((f) => f > slowest).length;
  return (big == 0 ? maxFreqs.length : big).clamp(1, 4);
}

const int sampleRate = 16000;

// Flat names inside assets/models/ (set by tool/fetch_models.dart).
const vadModel = 'silero_vad.onnx';
const segmentationModel = 'pyannote-segmentation-3-0.int8.onnx';
const embeddingModel = 'speaker-embedding.onnx';
// Parakeet TDT 0.6B v3 int8: one multilingual model for Spanish and English,
// it detects the language on its own.
const asrEncoder = 'asr-encoder.int8.onnx';
const asrDecoder = 'asr-decoder.int8.onnx';
const asrJoiner = 'asr-joiner.int8.onnx';
const asrTokens = 'asr-tokens.txt';

/// Hash of the bundled model files, set by tool/fetch_models.dart. When it
/// changes, phones copy the models again. Do not edit by hand.
const String modelsVersion = 'd9110a8418d7';

/// GitHub release that hosts the Parakeet files. A new model goes to a new
/// tag, never over an old one: phones check what they have by size.
const modelsUrl =
    'https://github.com/antruc/scrita/releases/download/models-v1';

/// Downloaded files: name -> (bytes, SHA-256). Set by
/// tool/fetch_models.dart. Do not edit by hand.
const asrDownloads = <String, (int, String)>{
  'asr-encoder.int8.onnx': (652184281, 'acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247'),
  'asr-decoder.int8.onnx': (11845275, '179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e'),
  'asr-joiner.int8.onnx': (6355277, '3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3'),
  'asr-tokens.txt': (93939, 'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d'),
};

/// Total download size in bytes.
final int downloadBytes = asrDownloads.values.fold(0, (s, f) => s + f.$1);

/// [bytes] as "670 MB".
String formatMb(int bytes) => '${(bytes / 1e6).round()} MB';

/// Downloaded files that [dir] lacks. By size only: hashing 650 MB on every
/// launch takes seconds, and a file only gets its name once its hash matched.
List<String> missingDownloads(String dir) => [
  for (final MapEntry(key: name, value: (size, _)) in asrDownloads.entries)
    if (!_hasSize(p.join(dir, name), size)) name,
];

/// Bytes still to download into [dir], minus what .part files already hold.
int bytesLeft(String dir) {
  var left = 0;
  for (final name in missingDownloads(dir)) {
    final size = asrDownloads[name]!.$1;
    final part = File(p.join(dir, '$name.part'));
    final have = part.existsSync() ? part.lengthSync() : 0;
    left += have > size ? size : size - have;
  }
  return left;
}

Future<String> _sha256(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

bool _hasSize(String path, int size) {
  final f = File(path);
  return f.existsSync() && f.lengthSync() == size;
}

/// Downloads the missing Parakeet files into [dir]. [onProgress] gets the
/// bytes done out of [downloadBytes]. A cut download resumes from its .part
/// file, on the next try or the next launch. Throws [ModelDownloadError].
Future<void> downloadModels(
  String dir,
  void Function(int done) onProgress,
) async {
  final missing = missingDownloads(dir);
  var done =
      downloadBytes -
      missing.fold<int>(0, (s, name) => s + asrDownloads[name]!.$1);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    for (final name in missing) {
      final (size, sha) = asrDownloads[name]!;
      final part = File(p.join(dir, '$name.part'));
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (have > size) have = 0; // left over by another model version
      if (have < size) {
        final req = await client.getUrl(Uri.parse('$modelsUrl/$name'));
        if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final res = await req.close();
        // 200 to a Range request: the server sends it all again.
        if (res.statusCode == 200) {
          have = 0;
        } else if (res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode} for $name');
        }
        final sink = part.openWrite(
          mode: have == 0 ? FileMode.write : FileMode.append,
        );
        try {
          // A stalled connection sends nothing and never closes.
          await for (final chunk in res.timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            have += chunk.length;
            onProgress(done + have);
          }
        } finally {
          await sink.close();
        }
      }
      // Hashing 650 MB takes seconds: off the UI isolate. compute with a
      // top-level function, a closure here would drag the HttpClient along.
      final got = await compute(_sha256, part.path);
      if (got != sha) {
        await part.delete();
        throw HttpException('Checksum mismatch for $name');
      }
      await part.rename(p.join(dir, name));
      done += size;
      onProgress(done);
    }
  } on FileSystemException catch (e) {
    debugPrint('Model download: $e');
    throw ModelDownloadError(
      tr(
        'No hay espacio suficiente. Libera ${formatMb(downloadBytes)} y '
            'vuelve a intentarlo',
        'Not enough space. Free up ${formatMb(downloadBytes)} and try again',
      ),
    );
  } on Exception catch (e) {
    // SocketException, HttpException, TimeoutException, HandshakeException.
    debugPrint('Model download: $e');
    throw ModelDownloadError(
      tr(
        'No se pudo descargar. Revisa tu conexión y vuelve a intentarlo',
        "Couldn't download. Check your connection and try again",
      ),
    );
  } finally {
    client.close(force: true);
  }
}

/// A download failure, with a message for the user.
class ModelDownloadError implements Exception {
  ModelDownloadError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Key of the saved RTF: a model or thread change starts a new estimate.
String get rtfKey => 'parakeet-v3|titanet-small|$numThreads';

/// RTF before any run: whole pipeline, and the .m4a/.opus conversion.
/// Measured on the 697.6 s reference interview.
const double defaultRtf = 0.22;
const double defaultDecodeRtf = 0.015;

/// Copies the bundled models from assets to the app support directory and
/// returns that directory. A .stamp file avoids reloading them on every
/// launch. The Parakeet files are not checked here: see [missingDownloads].
Future<String> prepareModels({void Function(String)? onStatus}) async {
  final dir = (await getApplicationSupportDirectory()).path;
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assets =
      manifest
          .listAssets()
          .where((a) => a.startsWith('assets/models/'))
          .toList()
        ..sort();

  final stamp = File(p.join(dir, 'models.stamp'));
  final expectedStamp = '$modelsVersion\n${assets.join('\n')}';
  final upToDate =
      await stamp.exists() && await stamp.readAsString() == expectedStamp;

  if (!upToDate) {
    onStatus?.call(
      tr(
        'Preparando la app por primera vez. Puede tardar un minuto...',
        'Setting up the app for the first time. It may take a minute...',
      ),
    );
    for (final src in assets) {
      final data = await rootBundle.load(src);
      await File(p.join(dir, p.basename(src))).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    await stamp.writeAsString(expectedStamp, flush: true);
  }

  final needed = [vadModel, segmentationModel, embeddingModel];
  final missing = needed
      .where((f) => !File(p.join(dir, f)).existsSync())
      .toList();
  if (missing.isNotEmpty || downloadBytes == 0) {
    // Only a build without tool/fetch_models.dart gets here.
    debugPrint(
      'Missing models: ${missing.join(', ')}. '
      'Run dart run tool/fetch_models.dart before building',
    );
    throw StateError(
      tr(
        'Scrita no se instaló bien. Actualiza la app',
        "Scrita wasn't installed correctly. Update the app",
      ),
    );
  }
  return dir;
}

sherpa_onnx.OfflineRecognizerConfig buildAsrConfig(String dir) {
  String m(String f) => p.join(dir, f);
  return sherpa_onnx.OfflineRecognizerConfig(
    model: sherpa_onnx.OfflineModelConfig(
      // sherpa-onnx reads the NeMo TDT type from the model metadata.
      transducer: sherpa_onnx.OfflineTransducerModelConfig(
        encoder: m(asrEncoder),
        decoder: m(asrDecoder),
        joiner: m(asrJoiner),
      ),
      tokens: m(asrTokens),
      numThreads: numThreads,
      debug: false,
    ),
  );
}

/// [numSpeakers] is the exact count (>= 1). Pyannote sees at most 3 voices
/// per 10 s window, but the global count has no cap: clustering cuts the
/// tree into exactly [numSpeakers] groups (1 = one group, no splitting).
sherpa_onnx.OfflineSpeakerDiarizationConfig buildDiarizationConfig(
  String dir, {
  required int numSpeakers,
}) {
  return sherpa_onnx.OfflineSpeakerDiarizationConfig(
    segmentation: sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
      pyannote: sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
        model: p.join(dir, segmentationModel),
        // The 10 s window moves 2.5 s per step (default 0.1 = 1 s). Speakers
        // only, the text no longer depends on diarization.
        // ponytail: fixed knob. Short "yes" or "uh-huh" lost: back to 0.1.
        windowShiftRatio: 0.25,
      ),
      numThreads: numThreads,
      debug: false,
    ),
    embedding: buildEmbeddingConfig(dir),
    clustering: sherpa_onnx.FastClusteringConfig(numClusters: numSpeakers),
    minDurationOn: 0.3,
    minDurationOff: 0.5,
  );
}

// Calibration knobs for regroupSpeakers (lib/transcript.dart).

/// Diarization asks for this many clusters above the real count, so odd
/// chunks land in clusters of their own before the merge down to the count.
const int extraClusters = 2;

/// Below this audio length (seconds) no extra clusters are asked for:
/// fastcluster's cutree_k puts everything in one cluster when asked for more
/// clusters than there are chunk embeddings, which short audios can hit.
const double extraClustersMinAudio = 60;

/// Turns shorter than this (seconds) get no embedding: too little voice to
/// trust. They follow the cluster sherpa-onnx gave them.
const double regroupMinTurn = 1.5;

/// Embedding extractor for regroupSpeakers, the same model diarization uses.
sherpa_onnx.SpeakerEmbeddingExtractorConfig buildEmbeddingConfig(String dir) =>
    sherpa_onnx.SpeakerEmbeddingExtractorConfig(
      model: p.join(dir, embeddingModel),
      numThreads: numThreads,
      debug: false,
    );

// VAD values of the official sherpa-onnx Parakeet v3 demo app, whose
// transcripts punctuate better than per-turn cuts did. Tune with real
// interviews.

/// Speech probability threshold. Low on purpose: it keeps quiet and far
/// voices without the per-turn gain the app used before. 0.3 was measured
/// and did not cut a long interview at pauses either.
const double vadThreshold = 0.1;

/// Pause (seconds) that ends a phrase.
const double vadMinSilence = 0.5;

/// Phrase length (seconds) past which the VAD looks for any cut. sherpa-onnx
/// does not cut at it: from there it ends the phrase at the first 0.1 s dip
/// in speech probability, which can be mid-word. Long on purpose:
/// splitPhrase gives each word its speaker, so phrases no longer need to be
/// short.
const double vadMaxSpeech = 20.0;

/// VAD that splits the whole recording into phrases before ASR.
sherpa_onnx.VadModelConfig buildVadConfig(String dir) {
  return sherpa_onnx.VadModelConfig(
    sileroVad: sherpa_onnx.SileroVadModelConfig(
      model: p.join(dir, vadModel),
      threshold: vadThreshold,
      minSilenceDuration: vadMinSilence,
      minSpeechDuration: 0.25,
      maxSpeechDuration: vadMaxSpeech,
    ),
    sampleRate: sampleRate,
    numThreads: 1,
    debug: false,
  );
}
