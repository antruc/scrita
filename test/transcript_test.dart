import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:scrita/l10n.dart';
import 'package:scrita/store.dart';
import 'package:scrita/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The expected texts below are the Spanish ones.
  uiSpanish = true;

  group('buildTurns', () {
    test('merges nearby segments of the same speaker', () {
      final turns = buildTurns([
        (start: 0.0, end: 2.0, speaker: 5),
        (start: 2.5, end: 4.0, speaker: 5),
        (start: 4.2, end: 6.0, speaker: 1),
      ]);
      expect(turns.length, 2);
      expect(turns[0].start, 0.0);
      expect(turns[0].end, 4.0);
      // Renumbered by order of appearance.
      expect(turns[0].speaker, 0);
      expect(turns[1].speaker, 1);
    });

    test('does not merge across a long pause', () {
      final turns = buildTurns([
        (start: 0.0, end: 2.0, speaker: 0),
        (start: 5.0, end: 6.0, speaker: 0),
      ]);
      expect(turns.length, 2);
    });

    test('splits overlaps and drops covered fragments', () {
      final turns = buildTurns([
        (start: 0.0, end: 5.0, speaker: 0),
        (start: 4.0, end: 8.0, speaker: 1), // overlaps by 1 s
        (start: 6.0, end: 7.0, speaker: 0), // falls inside the previous one
      ]);
      expect(turns.length, 2);
      // The 1 s overlap at the speaker change splits in half.
      expect(turns[0].end, 4.5);
      expect(turns[1].start, 4.5);
      expect(turns[1].end, 8.0);

      // Another speaker inside a longer turn does not cut its tail.
      final inside = buildTurns([
        (start: 0.0, end: 10.0, speaker: 0),
        (start: 4.0, end: 8.0, speaker: 1),
      ]);
      expect(inside.length, 1);
      expect(inside.single.end, 10.0);
    });

    test('sorts unordered segments', () {
      final turns = buildTurns([
        (start: 3.0, end: 4.0, speaker: 2),
        (start: 0.0, end: 1.0, speaker: 7),
      ]);
      expect(turns.first.start, 0.0);
      expect(turns.first.speaker, 0);
    });
  });

  test('cleanTurns removes empty turns and merges the same speaker', () {
    final out = cleanTurns([
      Turn(start: 0, end: 1, speaker: 0, text: 'Hola'),
      Turn(start: 1, end: 2, speaker: 1, text: '  '),
      Turn(start: 2, end: 3, speaker: 0, text: '¿cómo estás?'),
      Turn(start: 3, end: 4, speaker: 1, text: 'Bien'),
    ]);
    expect(out.length, 2);
    expect(out[0].text, 'Hola ¿cómo estás?');
    expect(out[0].end, 3);
    expect(out[1].text, 'Bien');
  });

  test('resampleLinear: length, interpolation and no out-of-bounds read', () {
    final input = Float32List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
    final up = resampleLinear(input, 8000, 16000);
    expect(up.length, 16);
    expect(up[1], closeTo(0.5, 1e-6));
    expect(up.last, 7); // the last point repeats the last sample
    final down = resampleLinear(Float32List(44100), 44100, 16000);
    expect(down.length, 16000);
    // 48 kHz -> 16 kHz averages each group of 3 samples.
    final avg = resampleLinear(
      Float32List.fromList([0, 3, 6, 9, 9, 9]),
      48000,
      16000,
    );
    expect(avg, [3, 9]);
    expect(identical(resampleLinear(input, 16000, 16000), input), isTrue);
  });

  test('formatTimestamp', () {
    expect(formatTimestamp(0), '00:00:00');
    expect(formatTimestamp(75.4), '00:01:15');
    expect(formatTimestamp(3725), '01:02:05');
  });

  test('etaSeconds blends the prior with the live pace', () {
    // Not started: the whole prior.
    expect(etaSeconds(0, 0, 150), 150);
    // Live pace says 100 s left, prior's remaining part says 75 s.
    expect(etaSeconds(100, 0.5, 150), closeTo(0.5 * 75 + 0.5 * 100, 1e-9));
    // Near the end the live pace leads.
    expect(etaSeconds(190, 0.95, 150), closeTo(0.05 * 7.5 + 0.95 * 10, 1e-9));
    // No prior: live only. Done: nothing left.
    expect(etaSeconds(30, 0.25, 0), closeTo(90, 1e-9));
    expect(etaSeconds(200, 1, 150), 0);
  });

  test('formatEta', () {
    expect(formatEta(59), '< 1 min');
    expect(formatEta(150), '≈ 3 min');
  });

  test('plain text and JSON round trip', () {
    final t = Transcript(
      title: 'Prueba',
      createdAt: DateTime(2026, 10, 9, 10, 30),
      audioPath: '/x.wav',
      durationSeconds: 65,
      turns: [
        Turn(start: 0, end: 3, speaker: 0, text: 'Buenos días.'),
        Turn(start: 3, end: 6, speaker: 1, text: 'Hola.'),
      ],
    );
    t.speakerNames[0] = 'Entrevistador';

    final txt = t.toPlainText();
    expect(txt, isNot(contains('Prueba')));
    expect(txt, contains('Participantes: Entrevistador, Persona 2'));
    expect(txt, contains('[00:00:00] Entrevistador:\nBuenos días.'));

    final back = Transcript.fromJson(
      jsonDecode(t.encode()) as Map<String, dynamic>,
    );
    expect(back.speakerNames, ['Entrevistador', 'Persona 2']);
    expect(back.turns[1].text, 'Hola.');
  });

  test('freeBase does not overwrite files and pairs .txt and .wav', () {
    final dir = Directory.systemTemp.createTempSync().path;
    expect(freeBase(dir, 'e', ['.txt', '.wav']), 'e');
    File('$dir/e.txt').writeAsStringSync('');
    expect(freeBase(dir, 'e', ['.txt', '.wav']), 'e (2)');
    File('$dir/e (2).wav').writeAsStringSync('');
    expect(freeBase(dir, 'e', ['.txt', '.wav']), 'e (3)');
    expect(freeBase(dir, 'e', ['.txt']), 'e (2)');
  });

  test('exportName uses the title the user set, sanitized', () {
    SavedTranscript saved(String title) => SavedTranscript(
      '/rec/scrita_2026-01-02T03-04-05.json',
      Transcript(
        title: title,
        createdAt: DateTime(2026),
        audioPath: '/rec/scrita_2026-01-02T03-04-05.wav',
        durationSeconds: 0,
        turns: [],
      ),
    );
    expect(exportName(saved('Entrevista: María')), 'Entrevista_ María');
    expect(exportName(saved(' ? ')), '_');
    expect(exportName(saved('  ')), 'scrita_2026-01-02T03-04-05');
  });

  test(
    'renameAudio sanitizes, never overwrites, and audioTitle reads it',
    () async {
      final dir = Directory.systemTemp.createTempSync().path;
      final date = DateTime(2026, 1, 2, 3, 4);
      final rec = '$dir/scrita_2026-01-02T03-04-05.wav';
      File(rec).writeAsStringSync('a');
      File('$dir/Interview.wav').writeAsStringSync('b');
      expect(audioTitle(rec, date), 'Scrita 2026-01-02 03:04');
      final to = await renameAudio(rec, ' Interview ');
      expect(p.basename(to), 'Interview (2).wav');
      expect(File(rec).existsSync(), isFalse);
      expect(audioTitle(to, date), 'Interview (2)');
      final abc = await renameAudio(to, 'a/b:c');
      expect(p.basename(abc), 'a_b_c.wav');
      expect(await renameAudio(abc, '  '), abc);
    },
  );

  test('listPendingAudios skips transcribed WAVs, reads durations', () async {
    final dir = Directory.systemTemp.createTempSync().path;
    File('$dir/a.wav').writeAsBytesSync(List.filled(44 + 96000, 0)); // 1 s
    File('$dir/b.wav').writeAsBytesSync(List.filled(44, 0));
    File('$dir/b.json').writeAsStringSync('');
    final done = SavedTranscript(
      '$dir/b.json',
      Transcript(
        title: 'b',
        createdAt: DateTime(2026),
        audioPath: '$dir/b.wav',
        durationSeconds: 0,
        turns: [],
      ),
    );
    final pending = await listPendingAudios([done], dir: dir);
    expect(pending.single.path, endsWith('a.wav'));
    expect(pending.single.durationSeconds, closeTo(1.0, 1e-9));

    // An imported WAV: the duration comes from the header's byte rate.
    final c = Uint8List(44 + 88200 * 2);
    ByteData.sublistView(c).setUint32(28, 88200, Endian.little); // 44.1k 16b
    File('$dir/c.wav').writeAsBytesSync(c);
    final withImport = await listPendingAudios([done], dir: dir);
    expect(
      withImport.firstWhere((a) => a.path.endsWith('c.wav')).durationSeconds,
      closeTo(2.0, 1e-9),
    );
  });

  test(
    'deleteTranscript never deletes a WAV outside the recordings folder',
    () async {
      final root = Directory.systemTemp.createTempSync('del');
      addTearDown(() => root.deleteSync(recursive: true));
      final rec = Directory('${root.path}/rec')..createSync();
      SavedTranscript saved(String audio) {
        File('${rec.path}/t.json').writeAsStringSync('{}');
        File('${rec.path}/t.txt').writeAsStringSync('');
        File(audio).writeAsStringSync('wav');
        return SavedTranscript(
          '${rec.path}/t.json',
          Transcript(
            title: 't',
            createdAt: DateTime(2026),
            audioPath: audio,
            durationSeconds: 0,
            turns: [],
          ),
        );
      }

      final outside = '${root.path}/outside.wav';
      await deleteTranscript(saved(outside), dir: rec.path);
      expect(File(outside).existsSync(), isTrue);
      expect(File('${rec.path}/t.json').existsSync(), isFalse);
      expect(File('${rec.path}/t.txt').existsSync(), isFalse);

      final inside = '${rec.path}/t.wav';
      await deleteTranscript(saved(inside), dir: rec.path);
      expect(File(inside).existsSync(), isFalse);
    },
  );

  group('readWavMono', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('wav'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('48 kHz PCM16 matches resampling the whole file', () {
      final ints = [
        for (var i = 0; i < 48000 * 3 + 777; i++) (i * 7919) % 65536 - 32768,
      ];
      final whole = Float32List.fromList([for (final v in ints) v / 32768]);
      expect(
        readWavMono(_wav(dir, _pcm16(ints), rate: 48000), 16000),
        resampleLinear(whole, 48000, 16000),
      );
    });

    test('44.1 kHz stays aligned across blocks', () {
      final ints = [
        for (var i = 0; i < 44100 * 2 + 500; i++)
          (math.sin(i * 2 * math.pi * 200 / 44100) * 20000).round(),
      ];
      final whole = Float32List.fromList([for (final v in ints) v / 32768]);
      final expected = resampleLinear(whole, 44100, 16000);
      final got = readWavMono(_wav(dir, _pcm16(ints), rate: 44100), 16000);
      expect(got.length, expected.length);
      var worst = 0.0;
      for (var i = 0; i < got.length; i++) {
        worst = math.max(worst, (got[i] - expected[i]).abs());
      }
      expect(worst, lessThan(0.02));
    });

    test('resample gets every block in order and only the last flushes', () {
      final ints = [for (var i = 0; i < 48000 * 2 + 300; i++) i % 100];
      final calls = <(int, int, bool)>[];
      // Fake streaming resampler: keeps every third sample, holds back the
      // last one until the flush.
      final got = readWavMono(
        _wav(dir, _pcm16(ints), rate: 48000),
        16000,
        resample: (block, from, last) {
          calls.add((block.length, from, last));
          return Float32List.fromList(
            [
              for (var i = 0; i < block.length; i += 3) block[i],
            ].sublist(0, last ? null : block.length ~/ 3 - 1),
          );
        },
      );
      expect(calls, [
        (48000, 48000, false),
        (48000, 48000, false),
        (300, 48000, true),
      ]);
      // 15999 + 15999 + 100: shorter than 32100, so the result is trimmed.
      expect(got.length, 32098);
    });

    test('stereo is averaged to mono', () {
      final path = _wav(dir, _pcm16([16384, 0, 16384, 0]), channels: 2);
      expect(readWavMono(path, 16000), [0.25, 0.25]);
    });

    test('broken data size falls back to the file length', () {
      // Three samples plus one stray byte of an unfinished sample.
      final data = Uint8List.fromList([
        ..._pcm16([16384, 16384, 16384]),
        7,
      ]);
      for (final declared in [0, 0xFFFFFFFF]) {
        expect(readWavMono(_wav(dir, data, declared: declared), 16000), [
          0.5,
          0.5,
          0.5,
        ]);
      }
    });

    test('8, 24 and 32 bit PCM, float and extensible', () {
      expect(
        readWavMono(_wav(dir, Uint8List.fromList([192, 64]), bits: 8), 16000),
        [0.5, -0.5],
      );
      final b24 = Uint8List.fromList([0, 0, 0x40, 0, 0, 0xC0]);
      expect(readWavMono(_wav(dir, b24, bits: 24), 16000), [0.5, -0.5]);
      final b32 = Int32List.fromList([1 << 30]).buffer.asUint8List();
      expect(readWavMono(_wav(dir, b32, bits: 32), 16000), [0.5]);
      final f32 = Float32List.fromList([0.25]).buffer.asUint8List();
      expect(readWavMono(_wav(dir, f32, format: 3, bits: 32), 16000), [0.25]);
      final ext = _wav(dir, _pcm16([16384]), extensible: true, listChunk: true);
      expect(readWavMono(ext, 16000), [0.5]);
    });

    test('unsupported or non-WAV files fail with a clear error', () {
      expect(
        () => readWavMono(_wav(dir, Uint8List(4), format: 2, bits: 4), 16000),
        throwsFormatException,
      );
      final junk = '${dir.path}/junk.wav';
      File(junk).writeAsStringSync('not a wav file at all');
      expect(() => readWavMono(junk, 16000), throwsFormatException);
    });

    test('8 kHz is upsampled', () {
      final path = _wav(dir, _pcm16(List.filled(100, 0)), rate: 8000);
      expect(readWavMono(path, 16000).length, 200);
    });
  });

  test('speakerFor: most overlap wins, nearest turn when none overlaps', () {
    final turns = [
      Turn(start: 0, end: 10, speaker: 0),
      Turn(start: 10, end: 13, speaker: 1),
      Turn(start: 13, end: 20, speaker: 0),
      Turn(start: 30, end: 40, speaker: 1),
    ];
    // Phrase crossing a boundary: 9 s with speaker 0, 1 s with speaker 1.
    expect(speakerFor(turns, 1, 11), 0);
    // Overlap adds up over turns of the same speaker: 1 + 1.5 s < 3 s,
    // 2 + 1.5 s > 3 s.
    expect(speakerFor(turns, 9, 14.5), 1);
    expect(speakerFor(turns, 8, 14.5), 0);
    // Inside the gap: nearest turn.
    expect(speakerFor(turns, 21, 22), 0);
    expect(speakerFor(turns, 28, 29), 1);
  });

  test('assignRange: whole words, proportional time, merges neighbours', () {
    const text = 'Bien. Claro, ¿y el dinero';
    final turns = [
      Turn(start: 0, end: 10, speaker: 0, text: 'Hola. ¿Cómo estás?'),
      Turn(start: 10, end: 20, speaker: 1, text: text),
      Turn(start: 20, end: 22, speaker: 0, text: 'ayudabas en casa?'),
    ];

    // Selection at the end, starting inside "Claro": split in two, the
    // second part merges with the following turn of speaker 0.
    var out = assignRange(turns, 1, 8, text.length, 0);
    expect([for (final t in out) t.speaker], [0, 1, 0]);
    expect(out[1].text, 'Bien.');
    expect(out[1].end, closeTo(10 + 10 * 6 / text.length, 1e-9));
    expect(out[2].start, out[1].end);
    expect(out[2].end, 22);
    expect(out[2].text, 'Claro, ¿y el dinero ayudabas en casa?');

    // Selection in the middle, cutting words at both ends: split in three.
    out = assignRange(turns, 1, 7, 14, 2);
    expect([for (final t in out) t.speaker], [0, 1, 2, 1, 0]);
    expect(
      [for (final t in out) t.text],
      [turns[0].text, 'Bien.', 'Claro, ¿y', 'el dinero', turns[2].text],
    );

    // Whole text: the turn is reassigned and merges with both neighbours.
    out = assignRange(turns, 1, 0, text.length, 0);
    expect(out.length, 1);
    expect(out[0].end, 22);
  });

  test('splitPhrase: cuts at the speaker change, absorbs short runs', () {
    // Phrase 2..9 s; words at 2, 2.4, 2.8, 3.2, 3.6 ("referías?" to 5.2),
    // 5.2, 6.0, 6.8 (last one up to 9).
    const text = '¿O a qué te referías? Pues sí claro';
    final tokens = [
      '¿O',
      ' a',
      ' qué',
      ' te',
      ' refer',
      'ías',
      '?',
      ' Pues',
      ' sí',
      ' claro',
    ];
    final ts = [0.0, 0.4, 0.8, 1.2, 1.6, 2.0, 2.4, 3.2, 4.0, 4.8];
    List<Turn> split(List<Turn> turns, [List<double>? t]) =>
        splitPhrase(turns, 2, 9, text, tokens, t ?? ts);

    // Change at 5 s: "referías?" (3.6-5.2) is mostly speaker 0.
    final two = split([
      Turn(start: 0, end: 5, speaker: 0),
      Turn(start: 5, end: 10, speaker: 1),
    ]);
    expect([for (final t in two) t.speaker], [0, 1]);
    expect(
      [for (final t in two) t.text],
      ['¿O a qué te referías?', 'Pues sí claro'],
    );
    expect(two.first.end, two.last.start);
    expect(two.last.end, 9);

    // A 0.4 s run in the middle joins the previous one; a short first run
    // joins the next one. Either way the phrase stays whole.
    for (final turns in [
      [
        Turn(start: 0, end: 3.2, speaker: 0),
        Turn(start: 3.2, end: 3.6, speaker: 1),
        Turn(start: 3.6, end: 10, speaker: 0),
      ],
      [
        Turn(start: 0, end: 2.4, speaker: 1),
        Turn(start: 2.4, end: 10, speaker: 0),
      ],
    ]) {
      final one = split(turns);
      expect(one.length, 1);
      expect(one.single.speaker, 0);
      expect(one.single.text, text);
    }

    // No timestamps: the whole phrase goes to speakerFor, as before.
    final fallback = split([
      Turn(start: 0, end: 4, speaker: 0),
      Turn(start: 4, end: 10, speaker: 1),
    ], const []);
    expect(fallback.length, 1);
    expect(fallback.single.speaker, 1);
    expect((fallback.single.start, fallback.single.end), (2.0, 9.0));
  });

  group('regroupSpeakers', () {
    Float32List v(List<double> x) => Float32List.fromList(x);
    final a = v([1, 0, 0]);
    final b = v([0, 1, 0]);

    test('merges a split voice and an odd cluster, fixes a flipped turn', () {
      final labels = regroupSpeakers(
        [0, 1, 2, 1, 3, 2, 1],
        [
          a,
          b,
          v([0.9, 0.1, 0]), // A again, split into its own cluster
          a, // A, but sherpa put it with B
          v([0.6, 0.1, 0.8]), // odd chunk (a laugh), nearer to A
          null, // short turn: follows its cluster (2, merged into A)
          b,
        ],
        [3, 3, 3, 2, 0.5, 0.5, 3],
        2,
      );
      expect(labels, [0, 1, 0, 0, 0, 0, 1]);
    });

    test('a voice heard only in short turns stays when k asks for it', () {
      // Cluster 1 has no turn long enough to embed. With k = 2 it must stay
      // a second speaker instead of joining cluster 0.
      expect(
        regroupSpeakers([0, 1, 0, 1], [a, null, a, null], [3, 1, 3, 1], 2),
        [0, 1, 0, 1],
      );
    });

    test('reassignment never empties a cluster (3 speakers)', () {
      // Without the guard both turns of cluster 1 leave it (one to 0, one
      // to 2) and only 2 speakers come out.
      final labels = regroupSpeakers(
        [0, 1, 1, 2],
        [
          v([2, 2, 0]),
          v([3, 1, 0]),
          v([1, 0, 2]),
          v([3, 1, 3]),
        ],
        [1, 1, 1, 1],
        3,
      );
      expect(labels.toSet().length, 3);
    });

    test('without embeddings keeps the initial grouping', () {
      expect(regroupSpeakers([4, 7, 4], [null, null, null], [1, 1, 1], 2), [
        4,
        7,
        4,
      ]);
    });
  });
}

Uint8List _pcm16(List<int> v) => Int16List.fromList(v).buffer.asUint8List();

var _wavCount = 0;

/// Writes [data] (already encoded) as a WAV. [declared] overrides the data
/// size in the header; [listChunk] adds an odd-sized chunk before `fmt `.
String _wav(
  Directory dir,
  Uint8List data, {
  int format = 1,
  int channels = 1,
  int rate = 16000,
  int bits = 16,
  int? declared,
  bool extensible = false,
  bool listChunk = false,
}) {
  final b = BytesBuilder();
  void u16(int v) =>
      b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  void u32(int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  b.add('RIFF'.codeUnits);
  u32(0);
  b.add('WAVE'.codeUnits);
  if (listChunk) {
    b.add('LIST'.codeUnits);
    u32(3);
    b.add([1, 2, 3, 0]); // 3 bytes plus the pad byte
  }
  b.add('fmt '.codeUnits);
  u32(extensible ? 40 : 16);
  u16(extensible ? 0xFFFE : format);
  u16(channels);
  u32(rate);
  u32(rate * channels * bits ~/ 8);
  u16(channels * bits ~/ 8);
  u16(bits);
  if (extensible) {
    u16(22); // extension size
    u16(bits);
    u32(0); // channel mask
    u16(format); // subformat GUID starts with the format code
    b.add(List.filled(14, 0));
  }
  b.add('data'.codeUnits);
  u32(declared ?? data.length);
  b.add(data);
  final path = '${dir.path}/t${_wavCount++}.wav';
  File(path).writeAsBytesSync(b.toBytes());
  return path;
}
