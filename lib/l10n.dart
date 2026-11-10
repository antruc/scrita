// App language. The UI comes in the 25 languages the ASR model (Parakeet v3)
// recognizes: one assets/l10n/<code>.json per language, rendered by key with
// tr(). To add a language: copy en.json, translate the values and add
// its code to [uiLanguages].

import 'dart:convert';

/// Languages with a JSON file. The device language picks one, English
/// otherwise.
const uiLanguages = [
  'bg', 'cs', 'da', 'de', 'el', 'en', 'es', 'et', 'fi', 'fr', 'hr', 'hu', 'it',
  'lt', 'lv', 'mt', 'nl', 'pl', 'pt', 'ro', 'ru', 'sk', 'sl', 'sv', 'uk', //
];

/// Key -> text. Set at launch with [loadStrings]. Plain Dart, so pure-logic
/// files and the pipeline isolate (which gets it in its request) can use it.
Map<String, String> uiStrings = {};

/// Merges the JSON files in order: English first, then the device language,
/// so a key missing in a translation still reads in English.
void loadStrings(Iterable<String> jsons) => uiStrings = {
  for (final j in jsons) ...(jsonDecode(j) as Map).cast<String, String>(),
};

final _placeholder = RegExp(r'\{(\w+)\}');

/// Text for [key], with each {name} replaced by its value in [args].
/// An unknown key shows as the key itself.
String tr(String key, [Map<String, Object?> args = const {}]) =>
    (uiStrings[key] ?? key).replaceAllMapped(
      _placeholder,
      (m) => '${args[m[1]] ?? m[0]}',
    );
