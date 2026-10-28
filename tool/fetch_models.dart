// Downloads the sherpa-onnx models. The small ones go into assets/models/
// (bundled in the APK); Parakeet goes into build/release-models/, to upload
// to the GitHub release the app downloads from (modelsUrl in
// lib/models.dart). Stamps hashes and sizes in lib/models.dart. Works on
// Linux, macOS and Windows.
//
// Usage: dart run tool/fetch_models.dart

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const rel = 'https://github.com/k2-fsa/sherpa-onnx/releases/download';
const assets = 'assets/models';
const release = 'build/release-models';

/// TitaNet small, the speaker embedding for diarization.
const titanet = 'nemo_en_titanet_small.onnx';

/// Parakeet TDT 0.6B v3 (25 European languages, Spanish and English
/// included), one model for both app languages.
const parakeet = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';

/// Parakeet archive file -> release file name (see lib/models.dart).
const parakeetFiles = {
  'encoder.int8.onnx': 'asr-encoder.int8.onnx',
  'decoder.int8.onnx': 'asr-decoder.int8.onnx',
  'joiner.int8.onnx': 'asr-joiner.int8.onnx',
  'tokens.txt': 'asr-tokens.txt',
};

/// SHA-256 of every download, keyed by URL. The first download of a URL
/// records it and later ones must match, so commit this file.
const lockPath = 'tool/models.lock.json';
final lock = <String, String>{};

/// Rewrites modelsVersion and asrDownloads in lib/models.dart; a new
/// version makes phones copy the bundled models again. [downloads] is
/// release file -> (bytes, SHA-256). Throws if either is missing, so a
/// renamed constant fails loudly instead of being skipped.
String patchModelsDart(
  String src, {
  required String version,
  required Map<String, (int, String)> downloads,
}) {
  String patch(String src, RegExp re, String to) {
    if (!re.hasMatch(src)) throw StateError('Not found: ${re.pattern}');
    return src.replaceFirst(re, to);
  }

  final entries = [
    for (final MapEntry(key: name, value: (size, sha)) in downloads.entries)
      "  '$name': ($size, '$sha'),\n",
  ].join();
  return patch(
    patch(
      src,
      RegExp(r"const String modelsVersion = '[^']*';"),
      "const String modelsVersion = '$version';",
    ),
    RegExp(r'const asrDownloads = <String, \(int, String\)>\{[^}]*\};'),
    'const asrDownloads = <String, (int, String)>{\n$entries};',
  );
}

Never fail(String msg) {
  stderr.writeln(msg);
  exit(1);
}

Future<String> sha256Of(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

/// Downloads [url] to [dest] unless it is already there, then checks it
/// against the lock, or records it the first time.
Future<void> fetch(String url, String dest) async {
  final file = File(dest);
  if (!file.existsSync() || file.lengthSync() == 0) await download(url, dest);
  final got = await sha256Of(dest);
  final want = lock[url];
  if (want == null) {
    lock[url] = got;
  } else if (want != got) {
    file.deleteSync();
    fail(
      'Checksum mismatch for $url\n  expected $want\n  got      $got\n'
      'The file was deleted. If upstream changed it on purpose, remove its '
      'entry from $lockPath and run again.',
    );
  }
}

Future<void> download(String url, String dest) async {
  stdout.writeln('    downloading ${p.basename(url)}');
  final part = File('$dest.part');
  final client = HttpClient();
  try {
    for (var attempt = 1; ; attempt++) {
      try {
        final res = await (await client.getUrl(Uri.parse(url))).close();
        if (res.statusCode != 200) {
          throw HttpException('HTTP ${res.statusCode}');
        }
        await res.pipe(part.openWrite());
        break;
      } on IOException catch (e) {
        if (attempt == 3) fail('Download failed for $url: $e');
        stdout.writeln('    retrying ($e)');
      }
    }
  } finally {
    client.close();
  }
  part.renameSync(dest);
}

/// Downloads and extracts a .tar.bz2 into the cache, returns its folder.
Future<String> fetchArchive(String url, String cache) async {
  final name = p.basename(url);
  final dir = p.join(cache, name.substring(0, name.length - '.tar.bz2'.length));
  await fetch(url, p.join(cache, name));
  if (!Directory(dir).existsSync()) {
    // System32 tar on Windows: a Git Bash GNU tar reads "C:" as a remote host.
    final tar = Platform.isWindows
        ? p.join(Platform.environment['SystemRoot']!, 'System32', 'tar.exe')
        : 'tar';
    final r = await Process.run(tar, [
      '-xjf',
      p.join(cache, name),
      '-C',
      cache,
    ]);
    if (r.exitCode != 0) fail('Could not extract $name:\n${r.stderr}');
  }
  return dir;
}

void install(String src, String name, {String to = assets}) {
  if (!File(src).existsSync()) {
    fail('$src not found inside the downloaded archive.');
  }
  File(src).copySync(p.join(to, name));
}

/// Hash of every installed model file, so phones copy the models again
/// whenever any of them changes, not only when a name does.
Future<String> assetsVersion() async {
  final lines = [
    for (final f in Directory(assets).listSync().whereType<File>())
      if (!p.basename(f.path).startsWith('.'))
        '${p.basename(f.path)} ${await sha256Of(f.path)}',
  ]..sort();
  return sha256
      .convert(utf8.encode(lines.join('\n')))
      .toString()
      .substring(0, 12);
}

Future<void> main() async {
  // Runs from the project root wherever it is called from.
  Directory.current = p.dirname(p.dirname(Platform.script.toFilePath()));
  final env = Platform.environment;
  final cache = p.join(
    env['XDG_CACHE_HOME'] ??
        env['LOCALAPPDATA'] ??
        p.join(env['HOME'] ?? '.', '.cache'),
    'sherpa-models',
  );
  Directory(assets).createSync(recursive: true);
  Directory(release).createSync(recursive: true);
  Directory(cache).createSync(recursive: true);
  final lockFile = File(lockPath);
  if (lockFile.existsSync()) {
    lock.addAll((jsonDecode(lockFile.readAsStringSync()) as Map).cast());
  }

  stdout.writeln('==> Models');
  await fetch(
    '$rel/asr-models/silero_vad.onnx',
    p.join(assets, 'silero_vad.onnx'),
  );
  // MIT asks to ship the license with the model; main.dart shows it.
  await fetch(
    'https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.3/LICENSE',
    p.join(assets, 'silero-vad-LICENSE.txt'),
  );
  await fetch(
    '$rel/speaker-recongition-models/$titanet',
    p.join(assets, 'speaker-embedding.onnx'),
  );

  final seg = await fetchArchive(
    '$rel/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
    cache,
  );
  install(
    p.join(seg, 'model.int8.onnx'),
    'pyannote-segmentation-3-0.int8.onnx',
  );
  install(p.join(seg, 'LICENSE'), 'pyannote-LICENSE.txt');

  final asr = await fetchArchive('$rel/asr-models/$parakeet.tar.bz2', cache);
  final downloads = <String, (int, String)>{};
  for (final MapEntry(key: src, value: name) in parakeetFiles.entries) {
    install(p.join(asr, src), name, to: release);
    // Left by a run from before the download: it would bloat the APK again.
    final old = File(p.join(assets, name));
    if (old.existsSync()) old.deleteSync();
    final file = p.join(release, name);
    downloads[name] = (File(file).lengthSync(), await sha256Of(file));
  }
  // CC-BY-4.0: the attribution lives in NOTICE, which main.dart shows.

  final sorted = lock.keys.toList()..sort();
  lockFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({for (final k in sorted) k: lock[k]})}\n',
  );

  final dart = File('lib/models.dart');
  dart.writeAsStringSync(
    patchModelsDart(
      dart.readAsStringSync(),
      version: await assetsVersion(),
      downloads: downloads,
    ),
  );

  stdout.writeln('\n==> Done. Models in $assets:');
  for (final f in Directory(assets).listSync().whereType<File>()) {
    if (p.basename(f.path).startsWith('.')) continue;
    final mb = (f.lengthSync() / (1 << 20)).toStringAsFixed(1);
    stdout.writeln('    $mb MB\t${p.basename(f.path)}');
  }
  final files = [for (final n in parakeetFiles.values) p.join(release, n)];
  stdout.writeln(
    '\n==> Parakeet in $release. Upload it once to the tag in modelsUrl '
    '(lib/models.dart); a changed model goes to a new tag:\n'
    '    gh release create <tag> --latest=false ${files.join(' ')}',
  );
}
