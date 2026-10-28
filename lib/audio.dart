// Audio from other apps, decoded with Android's own codecs. The native side is
// android/app/src/main/kotlin/dev/antruc/scrita/MainActivity.kt.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';

const _channel = MethodChannel('scrita/audio');

/// Formats of other apps (WhatsApp voice notes are .opus, call recorders
/// .amr or .3gp) that Scrita imports. They are kept as they are and only
/// decoded to a temporary WAV to transcribe. Android decodes all of them.
const importedAudioExts = {
  '.opus',
  '.ogg',
  '.m4a',
  '.mp3',
  '.aac',
  '.flac',
  '.amr',
  '.3gp',
};

/// Decodes [from] to a 16-bit mono WAV at [to]. Returns where the time
/// went (codec, rate, channels, seconds per part), for the timing summary.
Future<String?> decodeToWav(String from, String to) async {
  try {
    return await _channel.invokeMethod<String>('decode', {
      'from': from,
      'to': to,
    });
  } on PlatformException {
    throw FormatException(
      tr('No se pudo leer este audio', 'Could not read this audio'),
    );
  }
}

/// Sample rate of [path] in Hz, null if Android cannot read it.
Future<int?> audioSampleRate(String path) async {
  try {
    return await _channel.invokeMethod<int>('sampleRate', path);
  } on PlatformException {
    return null;
  }
}

/// Below this rate the audio sounds like a phone call (AMR, old call
/// recorders) and the ASR makes more mistakes.
const lowQualityRate = 16000;

/// Encodes the 16-bit PCM WAV [from] to an AAC .m4a at [to]. Throws a
/// [PlatformException] for any other WAV (24-bit, float).
Future<void> encodeM4a(String from, String to) =>
    _channel.invokeMethod('encodeM4a', {'from': from, 'to': to});

Future<double> audioDurationSeconds(String path) async =>
    (await _channel.invokeMethod<int>('duration', path) ?? 0) / 1000;

/// Path of the audio another app shared with Scrita, copied to the cache;
/// null if there is none. Each share is returned once.
Future<String?> takeSharedAudio() =>
    _channel.invokeMethod<String>('takeShared');

/// Opens Scrita's page in Android settings, where a denied permission is
/// granted again.
Future<void> openAppSettings() => _channel.invokeMethod('openSettings');

/// True from a share arriving while the app is open until Home takes it.
/// TranscriptScreen closes on it, once idle, so Home can import the audio.
final shareWaiting = ValueNotifier(false);

/// Calls [onShared] when a share arrives while the app is open.
void listenSharedAudio(void Function() onShared) =>
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'shared') return;
      shareWaiting.value = true;
      onShared();
    });

/// Free bytes on the storage that holds [path], null if unknown.
Future<int?> freeBytes(String path) async {
  try {
    return await _channel.invokeMethod<int>('freeBytes', path);
  } catch (_) {
    return null;
  }
}

/// 'none', 'metered' (mobile data, a phone hotspot) or 'unmetered' (Wi-Fi);
/// null if unknown.
Future<String?> network() async {
  try {
    return await _channel.invokeMethod<String>('network');
  } catch (_) {
    return null;
  }
}

/// Android API level, 0 if unknown. From 33 on, Android shows its own notice
/// when something is copied, so the app skips its own.
Future<int> sdkInt() async {
  try {
    return await _channel.invokeMethod<int>('sdkInt') ?? 0;
  } catch (_) {
    return 0;
  }
}
