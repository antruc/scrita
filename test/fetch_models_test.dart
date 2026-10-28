import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/fetch_models.dart' show patchModelsDart;

void main() {
  test('patchModelsDart rewrites modelsVersion and asrDownloads', () {
    final out = patchModelsDart(
      File('lib/models.dart').readAsStringSync(),
      version: '0123456789ab',
      downloads: {'asr-tokens.txt': (94, 'abc')},
    );
    expect(out, contains("const String modelsVersion = '0123456789ab';"));
    expect(
      out,
      contains(
        "const asrDownloads = <String, (int, String)>{\n"
        "  'asr-tokens.txt': (94, 'abc'),\n"
        '};',
      ),
    );
    // The old entries are gone, not appended to.
    expect(out, isNot(contains("'asr-encoder.int8.onnx': (0, '')")));
    expect(
      () => patchModelsDart('', version: 'y', downloads: {}),
      throwsStateError,
    );
  });
}
