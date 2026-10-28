import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scrita/backup.dart';

void main() {
  test(
    'backup round trip: files, audioPath, mtime, prefs, no overwrite',
    () async {
      final root = await Directory.systemTemp.createTemp('scrita_backup_test');
      addTearDown(() => root.delete(recursive: true));
      final src = await Directory(p.join(root.path, 'src')).create();
      final dst = await Directory(
        p.join(root.path, 'dst', 'scrita'),
      ).create(recursive: true);

      await File(
        p.join(src.path, 'a.json'),
      ).writeAsString(jsonEncode({'audioPath': '/old/device/a.wav'}));
      await File(p.join(src.path, 'a.txt')).writeAsString('hola');
      await File(p.join(src.path, 'a.wav')).writeAsBytes([1, 2, 3]);
      final pending = File(p.join(src.path, 'b.wav'));
      await pending.writeAsBytes([4, 5]);
      final date = DateTime(2025, 3, 4, 5, 6, 7);
      await pending.setLastModified(date);
      await File(p.join(src.path, 'ignored.tmp')).writeAsString('x');

      final zip = p.join(root.path, 'backup.zip');
      await writeBackup(src.path, zip, {
        'audioSource': 'mic',
        'lastSpeakers': 3,
      });

      final r = await readBackup(zip, dst.path);
      expect(r.added, 4);
      expect(r.prefs, {'audioSource': 'mic', 'lastSpeakers': 3});
      final j =
          jsonDecode(await File(p.join(dst.path, 'a.json')).readAsString())
              as Map;
      expect(j['audioPath'], p.join(dst.path, 'a.wav'));
      expect(await File(p.join(dst.path, 'a.wav')).readAsBytes(), [1, 2, 3]);
      expect(await File(p.join(dst.path, 'b.wav')).lastModified(), date);
      expect(File(p.join(dst.path, 'ignored.tmp')).existsSync(), isFalse);

      // Restoring again adds nothing and keeps local edits.
      await File(p.join(dst.path, 'a.txt')).writeAsString('editado');
      expect((await readBackup(zip, dst.path)).added, 0);
      expect(await File(p.join(dst.path, 'a.txt')).readAsString(), 'editado');

      // Anything that is not a Scrita backup is rejected.
      await expectLater(
        () => readBackup(p.join(src.path, 'a.txt'), dst.path),
        throwsA(anything),
      );
    },
  );

  test(
    'a zip entry that escapes the folder rejects the whole backup',
    () async {
      final root = await Directory.systemTemp.createTemp('scrita_slip_test');
      addTearDown(() => root.delete(recursive: true));
      final dst = await Directory(
        p.join(root.path, 'dst', 'scrita'),
      ).create(recursive: true);
      final file = File(p.join(root.path, 'x.json'))..writeAsStringSync('{}');
      final zip = p.join(root.path, 'evil.zip');
      final enc = ZipFileEncoder()..create(zip);
      await enc.addFile(file, 'scrita_backup.json');
      await enc.addFile(file, '../../evil.json');
      await enc.close();

      await expectLater(readBackup(zip, dst.path), throwsFormatException);
      expect(File(p.join(root.path, 'evil.json')).existsSync(), isFalse);
    },
  );
}
