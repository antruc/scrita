// Records the microphone to 48 kHz mono WAV, so the saved audio sounds like
// any other recorder app. The pipeline downsamples to 16 kHz (what
// sherpa-onnx expects) when transcribing. Since it goes to disk, a long
// interview takes no RAM while recording and the audio stays saved even if
// the app closes.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Native rate of most phone mics, so no resampling happens at record time.
const int recordSampleRate = 48000;

class InterviewRecorder {
  final _recorder = AudioRecorder();
  String? _path;
  DateTime? _startedAt;

  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Input level in dBFS (approx. -60 silence to 0 maximum).
  Stream<double> get level => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 150))
      .map((a) => a.current);

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// [source] picks the Android mic path and its processing. voiceRecognition
  /// (the Settings default) is tuned for speech recognition: flat response,
  /// no OEM effects.
  Future<void> start(AndroidAudioSource source) async {
    final dir = await recordingsDir();
    _path = p.join(dir, 'scrita_${fileStamp()}.wav');

    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: recordSampleRate,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(
          audioSource: source,
          // Bluetooth SCO drops the mic to 8/16 kHz call quality.
          manageBluetooth: false,
        ),
      ),
      path: _path!,
    );
    _startedAt = DateTime.now();
  }

  /// Stops recording and returns the WAV path.
  Future<String?> stop() async {
    final path = await _recorder.stop() ?? _path;
    _startedAt = null;
    return path;
  }

  Future<void> dispose() => _recorder.dispose();
}

/// Current local time as 2026-10-15T09-30-00, safe in file names.
String fileStamp() =>
    DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;

Future<String> recordingsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'scrita'));
  await dir.create(recursive: true);
  return dir.path;
}
