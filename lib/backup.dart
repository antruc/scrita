// Full backup in one .zip: every transcript (.json, .txt), every audio
// and the settings. Import merges: a file whose name already exists is kept
// as it is, so restoring the same backup twice changes nothing.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'l10n.dart';
import 'prefs.dart';
import 'recorder.dart';
import 'store.dart';

const _manifest = 'scrita_backup.json';

String get _notABackup => tr(
  'Este archivo no es una copia de seguridad de Scrita. Elige el archivo '
      'que creaste con "Hacer copia de seguridad"',
  'This file is not a Scrita backup. Pick the file you created with '
      '"Back up"',
);
const _exts = {'.json', '.txt', ...audioExts};

/// Writes a backup to Documents/Scrita and returns its path.
Future<String> exportBackup() async {
  final dir = await documentsDir();
  final name = freeBase(dir, 'scrita_backup_${fileStamp()}', ['.zip']);
  final path = p.join(dir, '$name.zip');
  await writeBackup(await recordingsDir(), path, exportPrefs());
  return path;
}

/// Restores the backup at [zipPath] (files and settings). Returns how many
/// files were added.
Future<int> importBackup(String zipPath) async {
  final r = await readBackup(zipPath, await recordingsDir());
  await importPrefs(r.prefs);
  return r.added;
}

/// Zips the files of [dir] plus a manifest with [prefs] and each file's
/// mtime: pending audios use it as their date, and zip times are coarse.
Future<void> writeBackup(
  String dir,
  String zipPath,
  Map<String, Object> prefs,
) async {
  final files = await Directory(dir)
      .list()
      .where((f) => f is File && _exts.contains(p.extension(f.path)))
      .cast<File>()
      .toList();
  final meta = File('$zipPath.manifest');
  await meta.writeAsString(
    jsonEncode({
      'version': 1,
      'prefs': prefs,
      'mtimes': {
        for (final f in files)
          p.basename(f.path): (await f.lastModified()).millisecondsSinceEpoch,
      },
    }),
  );
  // Audio barely compresses: store everything, it is much faster.
  final zip = ZipFileEncoder()..create(zipPath, level: ZipFileEncoder.store);
  try {
    for (final f in files) {
      await zip.addFile(f, p.basename(f.path), ZipFileEncoder.store);
    }
    await zip.addFile(meta, _manifest, ZipFileEncoder.store);
  } finally {
    await zip.close();
    await meta.delete();
  }
}

/// Extracts a [writeBackup] zip into [dir], never overwriting. Throws a
/// [FormatException] if [zipPath] is not a Scrita backup.
Future<({Map<String, dynamic> prefs, int added})> readBackup(
  String zipPath,
  String dir,
) async {
  // Next to [dir], so moving the files out is a rename on the same disk.
  final staging = Directory(p.join(p.dirname(dir), 'scrita_import'));
  if (await staging.exists()) await staging.delete(recursive: true);
  try {
    await _rejectEscapingEntries(zipPath);
    await extractFileToDisk(zipPath, staging.path);
    final meta = File(p.join(staging.path, _manifest));
    if (!await meta.exists()) {
      throw FormatException(_notABackup);
    }
    final m = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    final mtimes = (m['mtimes'] as Map?) ?? const {};
    var added = 0;
    // Only plain files at the top level with known extensions: anything else
    // in the zip, symlinks included, is ignored.
    await for (final f in staging.list(followLinks: false)) {
      final name = p.basename(f.path);
      if (f is! File || name == _manifest) continue;
      if (!_exts.contains(p.extension(name))) continue;
      final to = File(p.join(dir, name));
      if (await to.exists()) continue;
      if (p.extension(name) == '.json') {
        try {
          // audioPath is absolute: point it at this device's folder.
          final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          j['audioPath'] = p.join(dir, p.basename(j['audioPath'] as String));
          await to.writeAsString(
            const JsonEncoder.withIndent('  ').convert(j),
            flush: true,
          );
        } catch (_) {
          continue; // corrupt transcript: skip it, like listTranscripts does
        }
      } else {
        await f.rename(to.path);
      }
      final t = mtimes[name];
      if (t is int) {
        await to.setLastModified(DateTime.fromMillisecondsSinceEpoch(t));
      }
      added++;
    }
    final prefs = (m['prefs'] as Map?)?.cast<String, dynamic>() ?? {};
    return (prefs: prefs, added: added);
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

/// The zip comes from outside the app: refuse it whole if any entry name
/// ("../x", "/x", "C:\x") would land outside the extraction folder.
Future<void> _rejectEscapingEntries(String zipPath) async {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (_) {
      throw FormatException(_notABackup);
    }
    const root = '/staging';
    for (final f in archive) {
      final to = p.posix.normalize(
        p.posix.join(root, f.name.replaceAll('\\', '/')),
      );
      if (!p.posix.isWithin(root, to) || f.name.contains(':')) {
        throw FormatException(_notABackup);
      }
    }
  } finally {
    await input.close();
  }
}
