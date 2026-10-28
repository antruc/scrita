// User settings, persisted with shared_preferences. Loaded once in main(),
// so reads are synchronous everywhere else.

import 'package:flutter/material.dart' show Color, Colors, ThemeMode;
import 'package:record/record.dart' show AndroidAudioSource;
import 'package:shared_preferences/shared_preferences.dart';

late final SharedPreferences _prefs;

Future<void> initPrefs() async =>
    _prefs = await SharedPreferences.getInstance();

/// Android mic path for new recordings, voiceRecognition if none yet.
AndroidAudioSource get audioSource => AndroidAudioSource.values.firstWhere(
  (s) => s.name == _prefs.getString('audioSource'),
  orElse: () => AndroidAudioSource.voiceRecognition,
);
set audioSource(AndroidAudioSource s) =>
    _prefs.setString('audioSource', s.name);

/// Last speaker count chosen in the transcribe dialog, 2 if none yet.
int get lastSpeakers => (_prefs.getInt('lastSpeakers') ?? 2).clamp(1, 6);
set lastSpeakers(int n) => _prefs.setInt('lastSpeakers', n);

/// Light, dark or follow the device, system if none yet.
ThemeMode get themeMode => ThemeMode.values.firstWhere(
  (m) => m.name == _prefs.getString('themeMode'),
  orElse: () => ThemeMode.system,
);
set themeMode(ThemeMode m) => _prefs.setString('themeMode', m.name);

/// Material 3 seed the whole color scheme grows from, indigo if none yet.
Color get seedColor =>
    Color(_prefs.getInt('seedColor') ?? Colors.indigo.toARGB32());
set seedColor(Color c) => _prefs.setInt('seedColor', c.toARGB32());

/// Take the seed from the wallpaper (Material You, Android 12+) instead of
/// [seedColor]. On if none yet; below Android 12 [seedColor] is used anyway.
bool get materialYou => _prefs.getBool('materialYou') ?? true;
set materialYou(bool on) => _prefs.setBool('materialYou', on);

/// Save the app's WAVs to Documents as .m4a (about 12 times smaller, nearly
/// the same voice quality) instead of .wav. On if none yet.
bool get exportM4a => _prefs.getBool('exportM4a') ?? true;
set exportM4a(bool on) => _prefs.setBool('exportM4a', on);

/// The first-launch tutorial was shown (finished or skipped). Off if none yet.
bool get tutorialSeen => _prefs.getBool('tutorialSeen') ?? false;
set tutorialSeen(bool on) => _prefs.setBool('tutorialSeen', on);

/// Last choices in the "Save to Documents" dialog, both on if none yet.
bool get saveText => _prefs.getBool('saveText') ?? true;
set saveText(bool on) => _prefs.setBool('saveText', on);
bool get saveAudio => _prefs.getBool('saveAudio') ?? true;
set saveAudio(bool on) => _prefs.setBool('saveAudio', on);

/// Processing seconds per audio second for [key] (a model set, or the
/// .m4a/.opus to WAV conversion), learned from past runs; [fallback] if none
/// yet.
double rtf(String key, double fallback) =>
    _prefs.getDouble('rtf_$key') ?? fallback;

/// Folds a measured RTF into the saved one. A moving average: runs on the
/// same phone vary up to 60 %.
Future<void> recordRtf(String key, double measured, double fallback) {
  final old = rtf(key, fallback);
  return _prefs.setDouble('rtf_$key', old + 0.3 * (measured - old));
}

/// Every setting, for the backup.
Map<String, Object> exportPrefs() => {
  for (final k in _prefs.getKeys()) k: _prefs.get(k)!,
};

/// Restores settings from a backup. Values of unknown type are skipped.
Future<void> importPrefs(Map<String, dynamic> m) async {
  for (final MapEntry(:key, :value) in m.entries) {
    switch (value) {
      case String v:
        await _prefs.setString(key, v);
      case int v:
        await _prefs.setInt(key, v);
      case double v:
        await _prefs.setDouble(key, v);
      case bool v:
        await _prefs.setBool(key, v);
    }
  }
}
