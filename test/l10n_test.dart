import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrita/l10n.dart';

Map<String, String> _read(String language) =>
    (jsonDecode(File('assets/l10n/$language.json').readAsStringSync()) as Map)
        .cast<String, String>();

Set<String> _placeholders(String text) =>
    RegExp(r'\{\w+\}').allMatches(text).map((m) => m[0]!).toSet();

void main() {
  final en = _read('en');

  test('every language has the keys and placeholders of en.json', () {
    for (final language in uiLanguages) {
      final strings = _read(language);
      expect(strings.keys.toSet(), en.keys.toSet(), reason: language);
      for (final key in en.keys) {
        expect(
          _placeholders(strings[key]!),
          _placeholders(en[key]!),
          reason: '$language: $key',
        );
      }
    }
  });

  test('every tr() key in lib/ exists in en.json', () {
    final call = RegExp(r"\btr\(\s*'(\w+)'");
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final m in call.allMatches(file.readAsStringSync())) {
        expect(en, contains(m[1]), reason: file.path);
      }
    }
  });

  test('tr fills placeholders and falls back to English, then to the key', () {
    loadStrings([
      '{"assignTo": "Assign to {name}", "save": "Save"}',
      '{"assignTo": "Asignar a {name}"}',
    ]);
    expect(tr('assignTo', {'name': 'Ana {n}'}), 'Asignar a Ana {n}');
    expect(tr('save'), 'Save');
    expect(tr('missing'), 'missing');
  });
}
