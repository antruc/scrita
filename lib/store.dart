// Saves each transcript as .json (to reopen it and rename speakers) and as
// .txt (the final file that gets shared), next to the original audio. An
// audio with no .json pointing to it is still waiting to be transcribed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio.dart';
import 'l10n.dart';
import 'prefs.dart' show exportM4a;
import 'recorder.dart';
import 'transcript.dart';

class SavedTranscript {
  const SavedTranscript(this.jsonPath, this.transcript);
  final String jsonPath;
  final Transcript transcript;

  String get txtPath => p.setExtension(jsonPath, '.txt');
}

Future<SavedTranscript> saveTranscript(Transcript t, {String? jsonPath}) async {
  if (jsonPath == null) {
    final base = p.join(
      await recordingsDir(),
      p.basenameWithoutExtension(t.audioPath),
    );
    jsonPath = '$base.json';
    // Two imported WAVs with the same name must not overwrite each other.
    if (await File(jsonPath).exists()) {
      jsonPath = '${base}_${DateTime.now().millisecondsSinceEpoch}.json';
    }
  }
  await File(jsonPath).writeAsString(t.encode(), flush: true);
  await File(
    p.setExtension(jsonPath, '.txt'),
  ).writeAsString(t.toPlainText(), flush: true);
  return SavedTranscript(jsonPath, t);
}

Future<List<SavedTranscript>> listTranscripts() async {
  final dir = Directory(await recordingsDir());
  final out = <SavedTranscript>[];
  await for (final f in dir.list()) {
    if (f is! File || p.extension(f.path) != '.json') continue;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      out.add(SavedTranscript(f.path, Transcript.fromJson(j)));
    } catch (_) {
      // Corrupt file or from another version: skip it.
    }
  }
  out.sort((a, b) => b.transcript.createdAt.compareTo(a.transcript.createdAt));
  return out;
}

/// Audio files kept in the recordings folder: the app's WAVs and imports.
const audioExts = {'.wav', ...importedAudioExts};

/// A recording saved by the app that has no transcript yet.
typedef PendingAudio = ({
  String path,
  DateTime createdAt,
  double durationSeconds,
});

/// Durations of non-WAV audios already read from Android, by path and mtime,
/// so refreshing Home does not ask the platform again for each file.
// ponytail: in memory only, the first refresh after launch reads each file.
final _durations = <String, double>{};

/// Audios in the recordings folder that no transcript in [done] points to.
/// [dir] defaults to [recordingsDir]; tests pass a temp folder.
Future<List<PendingAudio>> listPendingAudios(
  List<SavedTranscript> done, {
  String? dir,
}) async {
  final used = {for (final s in done) p.normalize(s.transcript.audioPath)};
  final out = <PendingAudio>[];
  await for (final f in Directory(dir ?? await recordingsDir()).list()) {
    if (f is! File || !audioExts.contains(p.extension(f.path))) continue;
    if (used.contains(p.normalize(f.path))) continue;
    final stat = await f.stat();
    if (p.extension(f.path) != '.wav') {
      final key = '${f.path}|${stat.modified.millisecondsSinceEpoch}';
      var seconds = _durations[key];
      if (seconds == null) {
        try {
          seconds = await audioDurationSeconds(f.path);
        } catch (_) {
          seconds = 0; // unreadable: transcribing reports why
        }
        _durations[key] = seconds;
      }
      out.add((
        path: f.path,
        createdAt: stat.modified,
        durationSeconds: seconds,
      ));
      continue;
    }
    // Byte rate from the canonical 44-byte header; the recorder's 48 kHz
    // 16-bit mono if it is unreadable (e.g. the app died while recording).
    // ponytail: assumes fmt is the first chunk, as the recorder and most
    // imports write it; an estimate, only shown before transcribing.
    final h = await f.openRead(0, 32).expand((b) => b).toList();
    final byteRate = h.length == 32
        ? ByteData.sublistView(
            Uint8List.fromList(h),
          ).getUint32(28, Endian.little)
        : 0;
    final seconds =
        (stat.size > 44 ? stat.size - 44 : 0) /
        (byteRate > 0 ? byteRate : recordSampleRate * 2);
    out.add((path: f.path, createdAt: stat.modified, durationSeconds: seconds));
  }
  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

/// Copies the .txt if [text] and the audio if [audio] (see [exportAudioExt])
/// to Documents/Scrita, visible in the file manager. Never overwrites: if the
/// name exists it appends " (2)", " (3)"... Returns the destination folder.
// Direct write by path: needs no permissions since Android 11, which is why
// android/app/build.gradle.kts sets minSdk 30.
Future<String> exportToDocuments(
  SavedTranscript s, {
  required bool text,
  required bool audio,
}) async {
  final dir = await documentsDir();

  final wav = File(s.transcript.audioPath);
  final withAudio = audio && await wav.exists();
  final ext = exportAudioExt(wav.path);
  final name = freeBase(dir, exportName(s), [
    if (text) '.txt',
    if (withAudio) ext,
  ]);

  if (text) await File(s.txtPath).copy(p.join(dir, '$name.txt'));
  if (!withAudio) return dir;
  if (ext == p.extension(wav.path)) {
    await wav.copy(p.join(dir, '$name$ext'));
    return dir;
  }
  try {
    await encodeM4a(wav.path, p.join(dir, '$name$ext'));
  } on PlatformException {
    // A WAV the encoder does not take (24-bit, float): save it as it is.
    await wav.copy(p.join(dir, '${freeBase(dir, name, ['.wav'])}.wav'));
  }
  return dir;
}

/// Extension the audio at [path] is saved to Documents with: WAVs follow
/// the setting, other formats (imports) stay as they are.
String exportAudioExt(String path) {
  final ext = p.extension(path);
  return ext == '.wav' && exportM4a ? '.m4a' : ext;
}

/// File name for an exported or shared transcript: the title the user set,
/// not the name of the file on disk, which keeps the original one.
String exportName(SavedTranscript s) {
  final clean = safeName(s.transcript.title);
  return clean.isEmpty ? p.basenameWithoutExtension(s.jsonPath) : clean;
}

/// [name] without the characters Android and Windows reject in file names.
String safeName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

/// Documents/Scrita in shared storage, created if missing.
Future<String> documentsDir() async {
  final ext = await getExternalStorageDirectory();
  if (ext == null) {
    throw Exception(
      tr('No hay almacenamiento compartido', 'No shared storage'),
    );
  }
  // .../Android/data/<package>/files -> root of shared storage.
  final root = ext.path.split('/Android/').first;
  final dir = p.join(root, 'Documents', 'Scrita');
  await Directory(dir).create(recursive: true);
  return dir;
}

/// First free name in [dir]: "base", "base (2)", "base (3)"... such that
/// none of the [exts] overwrites an existing file. This way the .txt and the
/// .wav of one export share the same name.
String freeBase(String dir, String base, List<String> exts) {
  var name = base;
  for (
    var n = 2;
    exts.any((e) => File(p.join(dir, '$name$e')).existsSync());
    n++
  ) {
    name = '$base ($n)';
  }
  return name;
}

/// Display name of an audio with no transcript: the file name, or
/// `Scrita <date>` for the recorder's own timestamped files.
String audioTitle(String path, DateTime createdAt) {
  final base = p.basenameWithoutExtension(path);
  return base.startsWith('scrita_') ? 'Scrita ${formatDate(createdAt)}' : base;
}

/// Renames an audio with no transcript to [name] (sanitized, never
/// overwriting) and returns the new path. The mtime, used as its date, stays.
Future<String> renameAudio(String path, String name) async {
  final dir = p.dirname(path);
  final clean = safeName(name);
  if (clean.isEmpty || clean == p.basenameWithoutExtension(path)) return path;
  final ext = p.extension(path);
  final to = p.join(dir, '${freeBase(dir, clean, [ext])}$ext');
  await File(path).rename(to);
  return to;
}

/// [dir] defaults to [recordingsDir]; tests pass a temp folder.
Future<void> deleteTranscript(SavedTranscript s, {String? dir}) async {
  final audio = s.transcript.audioPath;
  for (final path in [
    s.jsonPath,
    s.txtPath,
    // Recorded and imported audios both live in the recordings folder;
    // never delete an audio outside it.
    if (p.isWithin(dir ?? await recordingsDir(), audio)) audio,
  ]) {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
