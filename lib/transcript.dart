// Transcript model and pure logic (no Flutter or FFI), so it can be tested
// with `flutter test`.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'l10n.dart';

/// Reads a WAV as mono float samples at [toRate], one second at a time, so a
/// long recording never sits in memory at its original rate. Accepts PCM
/// 8/16/24/32 bit and float 32, plain or WAVE_FORMAT_EXTENSIBLE; channels are
/// averaged to mono. A data size of 0 or past the end of the file (the app was
/// killed while recording) falls back to the real file length.
/// [resample] converts the blocks to [toRate] as one stream (it keeps filter
/// state across blocks, [last] flushes it); without it, resampleLinear.
Float32List readWavMono(String path, int toRate, {BlockResampler? resample}) {
  final f = File(path).openSync();
  try {
    Never invalid() => throw FormatException(
      tr(
        'No se puede abrir este audio. Prueba con otro archivo',
        "This audio can't be opened. Try another file",
      ),
    );
    ByteData read(int n) {
      final b = f.readSync(n);
      if (b.length < n) invalid();
      return ByteData.sublistView(b);
    }

    String tag(ByteData d, int at) =>
        String.fromCharCodes(d.buffer.asUint8List(d.offsetInBytes + at, 4));
    void skip(int n) => f.setPositionSync(f.positionSync() + n);

    final riff = read(12);
    if (tag(riff, 0) != 'RIFF' || tag(riff, 8) != 'WAVE') invalid();

    int? format, channels, rate, bits;
    late int declared;
    while (true) {
      final h = read(8);
      final size = h.getUint32(4, Endian.little);
      final id = tag(h, 0);
      if (id == 'data') {
        declared = size;
        break;
      }
      if (id == 'fmt ' && size >= 16 && size <= 64) {
        final fmt = read(size);
        format = fmt.getUint16(0, Endian.little);
        channels = fmt.getUint16(2, Endian.little);
        rate = fmt.getUint32(4, Endian.little);
        bits = fmt.getUint16(14, Endian.little);
        // Extensible: the real format is the first 2 bytes of the subformat.
        if (format == 0xFFFE && size >= 26) {
          format = fmt.getUint16(24, Endian.little);
        }
        skip(size & 1);
      } else {
        skip(size + (size & 1)); // chunks are padded to even sizes
      }
    }

    final double Function(ByteData, int)? sample = switch ((format, bits)) {
      (1, 8) => (d, o) => (d.getUint8(o) - 128) / 128,
      (1, 16) => (d, o) => d.getInt16(o, Endian.little) / 32768,
      (1, 24) =>
        (d, o) =>
            (d.getUint8(o) | d.getUint8(o + 1) << 8 | d.getInt8(o + 2) << 16) /
            8388608,
      (1, 32) => (d, o) => d.getInt32(o, Endian.little) / 2147483648,
      (3, 32) => (d, o) => d.getFloat32(o, Endian.little),
      _ => null,
    };
    if (sample == null ||
        channels == null ||
        rate == null ||
        channels == 0 ||
        rate == 0) {
      invalid();
    }
    final ch = channels;
    final width = bits! ~/ 8;
    final frame = ch * width;

    final start = f.positionSync();
    final available = f.lengthSync() - start;
    final frames =
        (declared == 0 || declared > available ? available : declared) ~/ frame;

    Float32List decode(int n) {
      final d = read(n * frame);
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        var sum = 0.0;
        for (var c = 0; c < ch; c++) {
          sum += sample(d, i * frame + c * width);
        }
        out[i] = sum / ch;
      }
      return out;
    }

    // Upsampling interpolates across block edges, and such files are small.
    if (rate < toRate) {
      final all = decode(frames);
      return resample?.call(all, rate, true) ??
          resampleLinear(all, rate, toRate);
    }

    // Blocks of exactly one second keep every averaging window inside a
    // block, so the result matches resampling the whole file at once.
    final out = Float32List((frames * toRate / rate).floor());
    var written = 0;
    for (var done = 0; done < frames; done += rate) {
      final input = decode(math.min(rate, frames - done));
      final block = rate == toRate
          ? input
          : resample?.call(input, rate, done + rate >= frames) ??
                resampleLinear(input, rate, toRate);
      final take = math.min(block.length, out.length - written);
      out.setRange(written, written + take, block);
      written += take;
    }
    // A streaming resampler may hand back a few samples less in total.
    return written == out.length
        ? out
        : Float32List.sublistView(out, 0, written);
  } finally {
    f.closeSync();
  }
}

/// Resamples one block of a stream from [fromRate]; [last] flushes it.
typedef BlockResampler =
    Float32List Function(Float32List block, int fromRate, bool last);

/// Simple resampling for WAVs that are not at 16 kHz, readWavMono's default
/// when no [BlockResampler] is given. Only tests rely on it: its box filter
/// lets aliasing through and Parakeet mishears words with it, so the app
/// passes sherpa-onnx's resampler.
/// Downsampling averages each output window so high frequencies do not alias.
Float32List resampleLinear(Float32List input, int fromRate, int toRate) {
  if (fromRate == toRate || input.isEmpty) return input;
  final outLen = (input.length * toRate / fromRate).floor();
  final out = Float32List(outLen);
  final ratio = fromRate / toRate;
  if (ratio > 1) {
    for (var i = 0; i < outLen; i++) {
      final from = (i * ratio).floor();
      final to = ((i + 1) * ratio).floor().clamp(from + 1, input.length);
      var sum = 0.0;
      for (var j = from; j < to; j++) {
        sum += input[j];
      }
      out[i] = sum / (to - from);
    }
    return out;
  }
  for (var i = 0; i < outLen; i++) {
    final pos = i * ratio;
    final j = pos.floor();
    final frac = pos - j;
    final a = input[j];
    final b = j + 1 < input.length ? input[j + 1] : a;
    out[i] = a + (b - a) * frac;
  }
  return out;
}

/// A speech interval attributed to one speaker.
class Turn {
  Turn({
    required this.start,
    required this.end,
    required this.speaker,
    this.text = '',
  });

  final double start; // seconds
  final double end; // seconds
  final int speaker; // 0, 1, 2... in order of appearance
  String text;

  double get duration => end - start;

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'speaker': speaker,
    'text': text,
  };

  factory Turn.fromJson(Map<String, dynamic> j) => Turn(
    start: (j['start'] as num).toDouble(),
    end: (j['end'] as num).toDouble(),
    speaker: j['speaker'] as int,
    text: j['text'] as String? ?? '',
  );
}

/// Turns diarization segments into sorted, non-overlapping turns:
/// - splits the overlap with the previous turn in half at a speaker change
///   (pyannote overlaps a few tenths there; giving it all to the first
///   speaker put the newcomer's first word on the previous one), and trims
///   it otherwise, so no audio belongs to two turns;
/// - merges consecutive segments of the same speaker separated by less than
///   [mergeGap] seconds;
/// - drops fragments shorter than [minDuration] seconds;
/// - renumbers speakers by order of appearance (the first to speak is 0).
List<Turn> buildTurns(
  List<({double start, double end, int speaker})> segments, {
  double mergeGap = 1.0,
  double minDuration = 0.3,
}) {
  final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));
  final turns = <Turn>[];

  for (final s in sorted) {
    var start = s.start;
    if (turns.isNotEmpty && start < turns.last.end) {
      final prev = turns.last;
      final mid = (start + prev.end) / 2;
      // Only a real hand-over: a segment inside prev must not cut its tail.
      if (prev.speaker != s.speaker &&
          s.end > prev.end &&
          s.end - mid >= minDuration) {
        turns[turns.length - 1] = Turn(
          start: prev.start,
          end: mid,
          speaker: prev.speaker,
        );
        start = mid;
      } else {
        start = prev.end;
      }
    }
    if (s.end - start < minDuration) continue;

    final last = turns.isEmpty ? null : turns.last;
    if (last != null &&
        last.speaker == s.speaker &&
        start - last.end <= mergeGap) {
      turns[turns.length - 1] = Turn(
        start: last.start,
        end: s.end,
        speaker: last.speaker,
      );
    } else {
      turns.add(Turn(start: start, end: s.end, speaker: s.speaker));
    }
  }

  final order = <int, int>{};
  return [
    for (final t in turns)
      Turn(
        start: t.start,
        end: t.end,
        speaker: order.putIfAbsent(t.speaker, () => order.length),
      ),
  ];
}

/// After ASR: removes turns with no text and merges consecutive turns of the
/// same speaker that became adjacent once the empty ones were removed.
List<Turn> cleanTurns(List<Turn> turns) {
  final out = <Turn>[];
  for (final t in turns) {
    final text = t.text.trim();
    if (text.isEmpty) continue;
    if (out.isNotEmpty && out.last.speaker == t.speaker) {
      final last = out.removeLast();
      out.add(
        Turn(
          start: last.start,
          end: t.end,
          speaker: last.speaker,
          text: '${last.text} $text',
        ),
      );
    } else {
      out.add(Turn(start: t.start, end: t.end, speaker: t.speaker, text: text));
    }
  }
  return out;
}

/// Speaker of the phrase [start]..[end] (seconds): the one whose turns cover
/// most of it. A phrase no turn touches takes the nearest turn's speaker.
/// [turns] must be sorted by start and not empty.
// ponytail: linear scan per phrase, O(phrases x turns), a few ms for an hour
// of audio; walk both lists together if it ever shows up in a profile.
int speakerFor(List<Turn> turns, double start, double end) {
  final overlap = <int, double>{};
  var nearest = turns.first;
  var gap = double.infinity;
  for (final t in turns) {
    final o = math.min(end, t.end) - math.max(start, t.start);
    if (o > 0) overlap[t.speaker] = (overlap[t.speaker] ?? 0) + o;
    final d = math.max(t.start - end, start - t.end);
    if (d < gap) {
      gap = d;
      nearest = t;
    }
  }
  if (overlap.isEmpty) return nearest.speaker;
  return overlap.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// Gives characters [from]..[to] of turns[index] to [speaker], widened to
/// whole words: a selection at the end splits the turn in two, one in the
/// middle in three, the whole text reassigns it. Times are proportional to
/// the character offsets (the transcript keeps no word times, so a cut can be
/// off by a second or two). Returns the cleaned list: a part next to a turn
/// of its speaker merges with it.
List<Turn> assignRange(
  List<Turn> turns,
  int index,
  int from,
  int to,
  int speaker,
) {
  final t = turns[index];
  final text = t.text;
  final space = RegExp(r'\s');
  while (from > 0 && !space.hasMatch(text[from - 1])) {
    from--;
  }
  while (to < text.length && !space.hasMatch(text[to])) {
    to++;
  }
  double at(int i) => t.start + t.duration * i / text.length;
  return cleanTurns([
    ...turns.sublist(0, index),
    Turn(
      start: t.start,
      end: at(from),
      speaker: t.speaker,
      text: text.substring(0, from),
    ),
    Turn(
      start: at(from),
      end: at(to),
      speaker: speaker,
      text: text.substring(from, to),
    ),
    Turn(
      start: at(to),
      end: t.end,
      speaker: t.speaker,
      text: text.substring(to),
    ),
    ...turns.sublist(index + 1),
  ]);
}

/// Shortest run of words (seconds) splitPhrase keeps on its own speaker;
/// shorter runs join a neighbour, so imprecise diarization borders do not
/// split a phrase word by word.
// ponytail: fixed knob, calibrate by ear. Stray words on the wrong speaker:
// raise to 1.5 or 2 s. A real "yes" or "uh-huh" of the other speaker lost: lower.
const double speakerMinRun = 1.0;

/// Splits the decoded phrase [start]..[end] (seconds) where the speaker
/// changes, word by word. [timestamps] are token starts in seconds from
/// [start]; a word starts at token 0 and at each token that starts with a
/// space. Each word takes speakerFor over its span (up to the next word, the
/// last one up to [end]); runs shorter than [speakerMinRun] join the previous
/// run (the next one if first). Without one timestamp per token, the whole
/// phrase goes to speakerFor with [text].
List<Turn> splitPhrase(
  List<Turn> turns,
  double start,
  double end,
  String text,
  List<String> tokens,
  List<double> timestamps,
) {
  if (tokens.isEmpty || timestamps.length != tokens.length) {
    return [
      Turn(
        start: start,
        end: end,
        speaker: speakerFor(turns, start, end),
        text: text,
      ),
    ];
  }

  final words = [
    for (var i = 0; i < tokens.length; i++)
      if (i == 0 || tokens[i].startsWith(' ')) i,
  ];
  // Runs of words with the same speaker; from..to are token indexes.
  var runs = <({double start, double end, int speaker, int from, int to})>[];
  void add(({double start, double end, int speaker, int from, int to}) r) {
    if (runs.isNotEmpty && runs.last.speaker == r.speaker) {
      final l = runs.removeLast();
      runs.add((
        start: l.start,
        end: r.end,
        speaker: l.speaker,
        from: l.from,
        to: r.to,
      ));
    } else {
      runs.add(r);
    }
  }

  for (var w = 0; w < words.length; w++) {
    final from = words[w];
    final to = w + 1 < words.length ? words[w + 1] : tokens.length;
    final s = start + timestamps[from];
    final e = to < tokens.length ? start + timestamps[to] : end;
    add((
      start: s,
      end: e,
      speaker: speakerFor(turns, s, e),
      from: from,
      to: to,
    ));
  }

  // ponytail: rescans after every merge, O(runs^2), runs are a handful.
  while (runs.length > 1) {
    final i = runs.indexWhere((r) => r.end - r.start < speakerMinRun);
    if (i < 0) break;
    final j = i == 0 ? 1 : i - 1;
    final a = math.min(i, j), b = math.max(i, j);
    final merged = (
      start: runs[a].start,
      end: runs[b].end,
      speaker: runs[j].speaker,
      from: runs[a].from,
      to: runs[b].to,
    );
    final rest = [...runs.sublist(0, a), merged, ...runs.sublist(b + 1)];
    runs = [];
    rest.forEach(add);
  }

  if (runs.length == 1) {
    return [
      Turn(start: start, end: end, speaker: runs.first.speaker, text: text),
    ];
  }
  return [
    for (final r in runs)
      Turn(
        start: r.start,
        end: r.end,
        speaker: r.speaker,
        text: tokens.sublist(r.from, r.to).join().trim(),
      ),
  ];
}

/// Regroups turns into at most [k] speakers with one embedding per turn.
/// sherpa-onnx clusters 10 s chunks with complete linkage and a fixed count,
/// so one odd chunk (a laugh, a noise) can take a whole cluster and two real
/// voices end up merged, or one voice flips label between chunks. Here:
/// 1. each initial cluster gets a centroid, the duration-weighted sum of its
///    turns' embeddings;
/// 2. the two closest centroids (cosine) merge until [k] are left;
/// 3. every embedded turn moves to its closest centroid, a few rounds.
/// [labels] are the initial clusters (any ints), [embeddings] null for turns
/// too short to embed (they follow their initial cluster), [weights] the
/// turn durations. Returns the new label of each turn, in 0..k-1.
// ponytail: O(c^2) centroid merge per step, fine for the few clusters
// diarization returns; per-phrase regrouping (stage 2) if turns mix voices.
List<int> regroupSpeakers(
  List<int> labels,
  List<Float32List?> embeddings,
  List<double> weights,
  int k, {
  int rounds = 3,
}) {
  final n = labels.length;
  if (n == 0) return const [];
  final dim = embeddings
      .firstWhere((e) => e != null, orElse: () => null)
      ?.length;
  // Nothing to compare: keep the initial grouping as it is.
  if (dim == null) return [...labels];

  Float32List unit(Float32List e) {
    var norm = 0.0;
    for (final x in e) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    return norm == 0 ? e : Float32List.fromList([for (final x in e) x / norm]);
  }

  double cosine(Float64List a, Float64List b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return na == 0 || nb == 0 ? -2 : dot / math.sqrt(na * nb);
  }

  final units = [for (final e in embeddings) e == null ? null : unit(e)];

  // 1) Centroid of each initial cluster that has at least one embedded turn.
  final sums = <int, Float64List>{};
  final mass = <int, double>{};
  for (var i = 0; i < n; i++) {
    mass[labels[i]] = (mass[labels[i]] ?? 0) + weights[i];
    final e = units[i];
    if (e == null) continue;
    final s = sums.putIfAbsent(labels[i], () => Float64List(dim));
    for (var d = 0; d < dim; d++) {
      s[d] += weights[i] * e[d];
    }
  }

  // 2) Merge the closest pair until k clusters are left. owner[c] is the
  // cluster that initial cluster c ended up in.
  final owner = {for (final c in sums.keys) c: c};
  while (sums.length > k) {
    final ids = sums.keys.toList();
    var best = -3.0;
    var a = ids[0], b = ids[1];
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final c = cosine(sums[ids[i]]!, sums[ids[j]]!);
        if (c > best) (best, a, b) = (c, ids[i], ids[j]);
      }
    }
    final into = sums[a]!, from = sums.remove(b)!;
    for (var d = 0; d < dim; d++) {
      into[d] += from[d];
    }
    owner.updateAll((_, o) => o == b ? a : o);
  }

  // Clusters with no embedded turn (only short fragments) join the cluster
  // with the most speech, the most likely owner of a stray "yes". While fewer
  // than k clusters have embeddings, the ones with most speech stay on their
  // own instead: k is the count the user asked for, and a voice heard only in
  // short turns is still a voice.
  final speech = <int, double>{};
  for (final e in mass.entries) {
    final o = owner[e.key];
    if (o != null) speech[o] = (speech[o] ?? 0) + e.value;
  }
  final unembedded = mass.keys.where((c) => !owner.containsKey(c)).toList()
    ..sort((x, y) => mass[y]!.compareTo(mass[x]!));
  for (final c in unembedded.take(math.max(0, k - sums.length))) {
    owner[c] = c;
  }
  final biggest = speech.keys.reduce(
    (x, y) => speech[x]! >= speech[y]! ? x : y,
  );
  final out = [for (final l in labels) owner[l] ?? biggest];

  // 3) Reassign embedded turns to the closest centroid, then recompute.
  // A turn never leaves a cluster it is the last embedded member of: with
  // 3+ clusters its members can split between two others and empty it, and
  // an empty centroid (all zeros) never wins a turn back.
  for (var r = 0; r < rounds; r++) {
    final ids = sums.keys.toList();
    final members = <int, int>{};
    for (var i = 0; i < n; i++) {
      if (units[i] != null) members[out[i]] = (members[out[i]] ?? 0) + 1;
    }
    var changed = false;
    for (var i = 0; i < n; i++) {
      final e = units[i];
      if (e == null) continue;
      final v = Float64List.fromList(e);
      var best = out[i];
      var bestSim = cosine(v, sums[best]!);
      for (final c in ids) {
        final s = cosine(v, sums[c]!);
        if (s > bestSim) (bestSim, best) = (s, c);
      }
      if (best != out[i] && members[out[i]]! > 1) {
        members[out[i]] = members[out[i]]! - 1;
        members[best] = (members[best] ?? 0) + 1;
        out[i] = best;
        changed = true;
      }
    }
    if (!changed) break;
    for (final c in ids) {
      sums[c] = Float64List(dim);
    }
    for (var i = 0; i < n; i++) {
      final e = units[i];
      if (e == null) continue;
      final s = sums[out[i]]!;
      for (var d = 0; d < dim; d++) {
        s[d] += weights[i] * e[d];
      }
    }
  }

  // Compact to 0..k-1.
  final index = <int, int>{};
  return [for (final c in out) index.putIfAbsent(c, () => index.length)];
}

String formatTimestamp(double seconds) {
  final s = seconds.round();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two((s % 3600) ~/ 60)}:${two(s % 60)}';
}

/// Seconds left in a run [progress] (0..1) done after [elapsed] seconds.
/// Blends the remaining part of [prior] (the whole run, estimated from the
/// saved RTF) with the live estimate from the pace so far: the prior leads
/// at the start, when the live one jumps, and the live one by the end.
/// Without a prior (0) it is the live estimate alone.
double etaSeconds(double elapsed, double progress, double prior) {
  final p = progress.clamp(0.0, 1.0);
  final fromPrior = prior * (1 - p);
  if (p == 0) return fromPrior;
  final live = elapsed * (1 - p) / p;
  return prior > 0 ? (1 - p) * fromPrior + p * live : live;
}

/// "< 1 min" or "≈ N min", coarse so the number does not jump.
String formatEta(double seconds) =>
    seconds < 60 ? '< 1 min' : '≈ ${(seconds / 60).round()} min';

/// Name shown for a speaker the user has not named yet.
String defaultSpeakerName(int i) => tr('Persona ${i + 1}', 'Speaker ${i + 1}');

String formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

class Transcript {
  Transcript({
    required this.title,
    required this.createdAt,
    required this.audioPath,
    required this.durationSeconds,
    required this.turns,
    List<String>? speakerNames,
  }) : speakerNames =
           speakerNames ??
           List.generate(
             turns.isEmpty
                 ? 0
                 : turns.map((t) => t.speaker).reduce((a, b) => a > b ? a : b) +
                       1,
             defaultSpeakerName,
           );

  String title;
  final DateTime createdAt;
  final String audioPath;
  final double durationSeconds;
  final List<Turn> turns;
  final List<String> speakerNames;

  String speakerName(int i) =>
      i < speakerNames.length ? speakerNames[i] : defaultSpeakerName(i);

  String toPlainText() {
    final b = StringBuffer()
      ..writeln('${tr('Fecha', 'Date')}: ${formatDate(createdAt)}')
      ..writeln(
        '${tr('Duración', 'Duration')}: ${formatTimestamp(durationSeconds)}',
      )
      ..writeln(
        '${tr('Participantes', 'Participants')}: ${speakerNames.join(', ')}',
      )
      ..writeln();
    for (final t in turns) {
      b
        ..writeln('[${formatTimestamp(t.start)}] ${speakerName(t.speaker)}:')
        ..writeln(t.text)
        ..writeln();
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'audioPath': audioPath,
    'durationSeconds': durationSeconds,
    'speakerNames': speakerNames,
    'turns': turns.map((t) => t.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory Transcript.fromJson(Map<String, dynamic> j) => Transcript(
    title: j['title'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    audioPath: j['audioPath'] as String,
    durationSeconds: (j['durationSeconds'] as num).toDouble(),
    speakerNames: (j['speakerNames'] as List).cast<String>(),
    turns: (j['turns'] as List)
        .map((e) => Turn.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
